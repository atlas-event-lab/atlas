// Experiment 01 — High Booking Concurrency
// ----------------------------------------------------------------------------
// Drives POST /api/v1/bookings at a rising request rate to (1) establish a baseline for
// booking throughput and latency, (2) watch the HPA scale booking/inventory, and (3)
// confirm the PgBouncer pooler keeps Postgres connections off the max_connections wall.
//
// Each iteration walks the real client journey: create a cart, add item(s) (the cart
// re-prices and returns totalInUSD), then POST the booking with that total. So the arrival
// rate is "checkout journeys started per second", exercising travel-cart + booking +
// inventory together.
//
// What gets booked is set by SCENARIO (one per run — set it and compare runs):
//   flight  -> a flight only          (default)
//   hotel   -> a hotel room only
//   both    -> a flight + a hotel in the same cart/booking
// Discovery fans out over the ROUTES table (origin/destiny for flights, city for hotels)
// hardcoded in lib/k6/config.js.
//
// Profile: ramping-arrival-rate. We fix the ARRIVAL RATE (journeys started per second) and
// let k6 add VUs as needed, so latency doesn't throttle the offered load — that's what makes
// it a clean throughput/scalability baseline rather than a closed-loop test.
//
// Run (see README.md for the full walkthrough):
//   set -a; source ../.env; set +a
//   k6 run load.js
//   k6 run -e SCENARIO=both -e TARGET_RPS=40 -e HOLD=8m load.js

import { Trend, Counter, Rate } from 'k6/metrics';
import { searchFlights, searchHotels, createBooking } from '../lib/k6/booking.js';
import { createCart, addOffer, totalInUSD, convertCart } from '../lib/k6/cart.js';
import { getToken } from '../lib/k6/auth.js';
import { CONFIG } from '../lib/k6/config.js';

const SCENARIO = CONFIG.scenario; // 'flight' | 'hotel' | 'both'
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

const TARGET_RPS = parseInt(__ENV.TARGET_RPS || '30', 10); // peak journeys/sec
const PRE_VUS = parseInt(__ENV.PRE_ALLOCATED_VUS || '20', 10);
// Concurrency is capped by the user pool: one VU per user avoids cart collisions. MAX_VUS
// defaults to the pool size and must not exceed it (each VU maps to loadtest-${__VU}).
const MAX_VUS = parseInt(__ENV.MAX_VUS || String(CONFIG.loadtest.userCount), 10);
if (MAX_VUS > CONFIG.loadtest.userCount) {
  throw new Error(
    `MAX_VUS (${MAX_VUS}) exceeds LOADTEST_USER_COUNT (${CONFIG.loadtest.userCount}). ` +
    `Seed more users (scripts/seed-loadtest-users.sh) or lower MAX_VUS to avoid cart collisions.`,
  );
}

// Smoke mode: set ITERATIONS=N to run EXACTLY N journeys (= N bookings) instead of the
// ramping load. VUS controls how many run in parallel (default 1 = sequential). Great for a
// quick "does the whole flow work end-to-end?" check before any real load.
//   k6 run -e ITERATIONS=5 load.js
const SMOKE_ITERATIONS = parseInt(__ENV.ITERATIONS || '0', 10);
const SMOKE_VUS = parseInt(__ENV.VUS || '1', 10);

// Custom metrics surfaced in the end-of-run summary.
const cartLatency = new Trend('cart_create_duration', true);
const addItemLatency = new Trend('cart_add_item_duration', true); // per flight/hotel add
const bookingLatency = new Trend('booking_create_duration', true);
const journeyLatency = new Trend('journey_duration', true); // cart -> add -> booking
const convertLatency = new Trend('cart_convert_duration', true); // trailing conversion
// POST /bookings returns 201 on creation and 200 on idempotent replay (BookingController:
// status = result.isReplay() ? OK : CREATED). Every iteration here uses a fresh
// Idempotency-Key, so we expect all 201s; any 200 means an unexpected replay (retry / key
// collision) and is worth surfacing separately. Both are successful outcomes.
const bookingsCreated = new Counter('bookings_created'); // 201
const bookingsReplayed = new Counter('bookings_replayed'); // 200
const bookingErrors = new Counter('bookings_failed');
const bookingSuccess = new Rate('booking_success_rate');

// Smoke: a fixed, exact number of journeys. Load: the ramping arrival-rate baseline.
const scenarios = SMOKE_ITERATIONS > 0
  ? {
      smoke: {
        executor: 'shared-iterations',
        vus: SMOKE_VUS,
        iterations: SMOKE_ITERATIONS, // total journeys across all VUs = total bookings
        maxDuration: __ENV.MAX_DURATION || '2m',
      },
    }
  : {
      booking_load: {
        executor: 'ramping-arrival-rate',
        startRate: 1,
        timeUnit: '1s',
        preAllocatedVUs: PRE_VUS,
        maxVUs: MAX_VUS,
        // Warm up, hold at target so the HPA has time to react, then ease down.
        stages: [
          { target: Math.ceil(TARGET_RPS / 3), duration: __ENV.RAMP || '2m' },
          { target: TARGET_RPS, duration: __ENV.RAMP || '2m' },
          { target: TARGET_RPS, duration: __ENV.HOLD || '4m' },
          { target: 0, duration: '1m' },
        ],
      },
    };

// setup() authenticates then fans out over every route in CONFIG.search.routes (166 today),
// one sequential search per route — that easily exceeds k6's 60s default. Give it headroom.
// IMPORTANT: the value MUST carry a time unit; k6 reads a bare number like "180" as
// nanoseconds → effectively 0 ("timed out after 0 seconds"). Normalize unit-less input to
// seconds so `-e SETUP_TIMEOUT=180`, `=5m`, or an exported shell var all behave sanely.
const SETUP_TIMEOUT = /[a-z]$/i.test(__ENV.SETUP_TIMEOUT || '')
  ? __ENV.SETUP_TIMEOUT
  : `${__ENV.SETUP_TIMEOUT || '180'}s`;

export const options = {
  scenarios,
  setupTimeout: SETUP_TIMEOUT,
  thresholds: {
    // Baseline expectations — tune from your first run, don't treat as gospel yet.
    booking_success_rate: ['rate>0.98'],
    'booking_create_duration': ['p(95)<2000'], // ms; POST /bookings is a sync saga kickoff
    'journey_duration': ['p(95)<4000'], // cart + add flight + booking end-to-end
    http_req_failed: ['rate<0.02'],
  },
};

const needFlights = SCENARIO === 'flight' || SCENARIO === 'both';
const needHotels = SCENARIO === 'hotel' || SCENARIO === 'both';

// setup() runs once: prove auth works, then build one "bundle" PER ROUTE holding that route's
// flights and hotels. A journey later draws from a single bundle, so its flight and hotel are
// always coherent (same origin/destiny/city/date). Only bundles that satisfy the scenario are
// kept (e.g. 'both' needs a route with both a flight AND a hotel in stock).
export function setup() {
  getToken(); // fail fast if Keycloak / test client / user is misconfigured

  const bundles = [];
  for (const route of CONFIG.search.routes) {
    if (needFlights && !(route.origin && route.destiny)) continue;
    if (needHotels && !route.city) continue;

    const bundle = {
      label: `${route.origin || '—'}-${route.destiny || '—'}/${route.city || '—'}`,
      flights: needFlights ? searchFlights(route) : [],
      hotels: needHotels ? searchHotels(route) : [],
    };
    const usable = (!needFlights || bundle.flights.length) && (!needHotels || bundle.hotels.length);
    if (usable) bundles.push(bundle);
  }

  if (bundles.length === 0) {
    throw new Error(
      `No routes with in-stock inventory for SCENARIO=${SCENARIO}. ` +
      `Fill/adjust the ROUTES table in lib/k6/config.js and check dates & seeded inventory.`,
    );
  }
  console.log(
    `SCENARIO=${SCENARIO} — ${bundles.length} usable route bundle(s): ` +
    bundles.map((b) => `${b.label} [${b.flights.length}F/${b.hotels.length}H]`).join(', '),
  );
  return { bundles };
}

// Build one journey's offers from a SINGLE route bundle, keeping flight+hotel coherent.
function offersFor(data) {
  const bundle = pick(data.bundles);
  switch (SCENARIO) {
    case 'hotel':
      return [pick(bundle.hotels)];
    case 'both':
      return [pick(bundle.flights), pick(bundle.hotels)]; // same bundle => coherent flight + hotel
    case 'flight':
    default:
      return [pick(bundle.flights)];
  }
}

export default function (data) {
  const offers = offersFor(data);
  const t0 = Date.now();

  // 1. Create a cart.
  const { res: cartRes, cartId } = createCart();
  cartLatency.add(cartRes.timings.duration);
  if (cartRes.status !== 200 || !cartId) {
    bookingSuccess.add(false);
    bookingErrors.add(1);
    return; // no cart -> can't continue this journey
  }

  // 2. Add every item; the cart re-prices on each add. Keep the last response for the total.
  let cartAfter = cartRes;
  for (const offer of offers) {
    cartAfter = addOffer(cartId, offer);
    addItemLatency.add(cartAfter.timings.duration);
    if (cartAfter.status !== 200) {
      bookingSuccess.add(false);
      bookingErrors.add(1);
      return;
    }
  }
  const total = totalInUSD(cartAfter); // MoneyDto (all items) -> booking.total

  // 3. Create the booking with the cart's USD total.
  const res = createBooking(offers, total); // fresh Idempotency-Key per call
  bookingLatency.add(res.timings.duration);

  const ok = res.status === 200 || res.status === 201;
  bookingSuccess.add(ok);
  if (res.status === 201) bookingsCreated.add(1);
  else if (res.status === 200) bookingsReplayed.add(1);
  else bookingErrors.add(1);

  // journey_duration measures time-to-book (up to POST /bookings), so record it before the
  // trailing conversion step.
  journeyLatency.add(Date.now() - t0);

  // 4. On success, convert the cart (as the real frontend does) so this VU's next iteration
  // starts from a fresh ACTIVE cart. Best-effort: a convert hiccup shouldn't fail the journey.
  if (ok) {
    const conv = convertCart(cartId);
    convertLatency.add(conv.timings.duration);
  }
}
