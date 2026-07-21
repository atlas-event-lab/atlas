// Experiment 02 — Inventory Contention
// ----------------------------------------------------------------------------
// Proves the no-oversell invariant: when many bookings race for ONE scarce resource, the
// pessimistic row lock in inventory-service (FlightInventoryRepository.findForUpdate, a
// SELECT … FOR UPDATE) serializes them so `reservedCount` never exceeds `totalCapacity`.
//
// Unlike Experiment 01 — which SPREADS load across the ROUTES table so inventory is never the
// bottleneck — this concentrates every VU onto a single flight/room-type (CONFIG.contention),
// fires a burst of N bookings, then verifies the settled inventory:
//
//   1. No oversell — reservedCount <= totalCapacity, available >= 0.  (the hard invariant)
//   2. Winners — (reservedCount rise / q) == floor(capacity / q), the exact reservable subset.
//   3. The rest were cleanly rejected (bookings created but not reserved), never oversold.
//
// Because POST /bookings is a synchronous kickoff of an asynchronous Saga, the outcome is read
// AFTER the burst drains, straight from the inventory API (ground truth, no ownership check).
// Payment MUST be stubbed always-approve so winners stay RESERVED/CONFIRMED and the settled
// count is stable to read (a failing/timing-out payment would release stock and mask the
// invariant). See README.md.
//
// Run (see README.md for the full walkthrough):
//   set -a; source ../.env; set +a
//   # point it at the scarce resource:
//   export CONTENTION_ORIGIN=LIM CONTENTION_DESTINY=CUZ CONTENTION_DATE=2026-09-01
//   k6 run -e N=100 load.js                 # q=1 by default
//   k6 run -e N=50 -e Q=3 load.js           # partial: 3 rooms/seats per booking

import { Counter, Trend } from 'k6/metrics';
import { sleep } from 'k6';
import { resolveContentionOffer, createBooking } from '../lib/k6/booking.js';
import { createCart, addOffer, totalInUSD, convertCart } from '../lib/k6/cart.js';
import { getToken } from '../lib/k6/auth.js';
import { getAvailability } from '../lib/k6/inventory.js';
import { CONFIG } from '../lib/k6/config.js';

const SCENARIO = CONFIG.scenario; // 'flight' | 'hotel'
const Q = CONFIG.contention.quantity || 1;

// N = number of bookings fired at the one resource. Make it comfortably larger than the
// resource's capacity so the losers genuinely lose (N >> C).
const N = parseInt(__ENV.N || '100', 10);
// Concurrency: how many of the N fire at once. Capped by the user pool (one user per VU
// avoids cart collisions — see repo README). Default = min(N, pool), for maximum collision.
const MAX_VUS = Math.min(
  N,
  parseInt(__ENV.MAX_VUS || String(CONFIG.loadtest.userCount), 10),
);
if (MAX_VUS > CONFIG.loadtest.userCount) {
  throw new Error(
    `MAX_VUS (${MAX_VUS}) exceeds LOADTEST_USER_COUNT (${CONFIG.loadtest.userCount}). ` +
    `Seed more users (scripts/seed-loadtest-users.sh) or lower MAX_VUS.`,
  );
}

// Seconds to wait after the burst before reading the settled inventory — the Saga is async
// (BookingCreated → inventory reserve → payment). Give it room to drain under contention.
const SETTLE = parseInt(__ENV.SETTLE || '45', 10);

// Metrics surfaced in the summary. `oversell` is the one that matters: its threshold below
// fails the whole run if the invariant is ever violated.
const oversell = new Counter('oversell');                 // must stay 0
const bookingsCreated = new Counter('bookings_created');  // 201 accepted (kicked off)
const bookingErrors = new Counter('bookings_failed');     // POST /bookings itself failed
const bookingLatency = new Trend('booking_create_duration', true);

export const options = {
  scenarios: {
    // A burst: fire N bookings across up-to-MAX_VUS VUs as fast as they can go, so they pile
    // onto the single locked row simultaneously. shared-iterations = exactly N total.
    contention_burst: {
      executor: 'shared-iterations',
      vus: MAX_VUS,
      iterations: N,
      maxDuration: __ENV.MAX_DURATION || '3m',
    },
  },
  setupTimeout: /[a-z]$/i.test(__ENV.SETUP_TIMEOUT || '')
    ? __ENV.SETUP_TIMEOUT
    : `${__ENV.SETUP_TIMEOUT || '180'}s`,
  // teardownTimeout must outlast SETTLE + the verification reads.
  teardownTimeout: `${SETTLE + 30}s`,
  thresholds: {
    oversell: ['count==0'],          // THE invariant: reservedCount never exceeds capacity
    bookings_failed: ['count==0'],   // every booking should be accepted (then reserved OR rejected)
  },
};

// setup(): resolve the ONE scarce resource and snapshot its stock BEFORE the burst, so
// teardown() can attribute exactly what this run reserved. Reads capacity C live — the maths
// (expected winners) is derived from truth, never assumed.
export function setup() {
  getToken(); // fail fast if auth is misconfigured

  if (SCENARIO !== 'flight' && SCENARIO !== 'hotel') {
    throw new Error(`SCENARIO must be 'flight' or 'hotel' for contention (got '${SCENARIO}').`);
  }

  const offer = resolveContentionOffer(SCENARIO);
  const before = getAvailability(offer);
  const capacityForRun = before.available; // seats/rooms actually reservable right now
  const expectedWinners = Math.floor(capacityForRun / Q);

  if (before.reservedCount > before.totalCapacity) {
    throw new Error(
      `Target is ALREADY oversold before the run (reserved=${before.reservedCount} > ` +
      `capacity=${before.totalCapacity}). Reset state (scripts/reset-state.sh) and re-check.`,
    );
  }
  if (expectedWinners === 0) {
    throw new Error(
      `Target has no reservable stock for q=${Q} (available=${capacityForRun}). ` +
      `Reset state or pick a resource with capacity.`,
    );
  }
  if (N <= expectedWinners) {
    console.warn(
      `N (${N}) <= expected winners (${expectedWinners}); every booking may win and the ` +
      `contention/rejection path won't be exercised. Raise N well above capacity/q.`,
    );
  }

  console.log(
    `CONTENTION target ${offer.type} ${offer.resourceId} (${offer.label}) — ` +
    `capacity=${before.totalCapacity}, reserved=${before.reservedCount}, available=${capacityForRun}; ` +
    `q=${Q}, N=${N}, expected winners=${expectedWinners}, expected rejects=${N - expectedWinners}.`,
  );

  return { offer, before, expectedWinners };
}

// Each iteration = one full journey (cart → add the scarce item at qty q → POST booking)
// against the SAME resource. We only count the POST /bookings outcome; the reserve/reject is
// resolved by the Saga and read in teardown().
export default function (data) {
  const offer = data.offer;

  const { res: cartRes, cartId } = createCart();
  if (cartRes.status !== 200 || !cartId) {
    bookingErrors.add(1);
    return;
  }

  const cartAfter = addOffer(cartId, offer);
  if (cartAfter.status !== 200) {
    bookingErrors.add(1);
    return;
  }
  const total = totalInUSD(cartAfter);

  const res = createBooking(offer, total); // fresh Idempotency-Key per call
  bookingLatency.add(res.timings.duration);
  if (res.status === 201 || res.status === 200) {
    bookingsCreated.add(1);
    convertCart(cartId); // leave this VU a fresh cart, as the real frontend does
  } else {
    bookingErrors.add(1);
  }
}

// teardown(): the verification. Wait for the Saga to settle, read the inventory ground truth,
// and assert the invariant + the exact winner count. Throwing here fails the run loudly (k6
// exits non-zero) — the strongest signal that correctness broke.
export function teardown(data) {
  console.log(`Waiting ${SETTLE}s for the Saga to settle before verifying…`);
  sleep(SETTLE);

  const after = getAvailability(data.offer);
  const reservedRise = after.reservedCount - data.before.reservedCount;
  const winners = Math.floor(reservedRise / Q);

  const oversoldNow = after.reservedCount > after.totalCapacity || after.available < 0;
  if (oversoldNow) oversell.add(1);

  console.log(
    '── Experiment 02 verification ──\n' +
    `  capacity            : ${after.totalCapacity}\n` +
    `  reserved (before)   : ${data.before.reservedCount}\n` +
    `  reserved (after)    : ${after.reservedCount}\n` +
    `  available (after)   : ${after.available}\n` +
    `  reserved rise       : ${reservedRise} (q=${Q})\n` +
    `  winners             : ${winners}  (expected ${data.expectedWinners})\n` +
    `  OVERSOLD            : ${oversoldNow ? 'YES ✗' : 'no ✓'}`,
  );

  if (oversoldNow) {
    throw new Error(
      `OVERSELL DETECTED: reservedCount=${after.reservedCount} exceeds ` +
      `totalCapacity=${after.totalCapacity} (available=${after.available}). Invariant violated.`,
    );
  }
  if (winners !== data.expectedWinners) {
    throw new Error(
      `Winner count mismatch: reserved rise implies ${winners} winners, expected ` +
      `${data.expectedWinners} (floor(capacity/q)). Investigate lost/duplicate reservations ` +
      `or a payment stub that isn't always-approve (releasing stock).`,
    );
  }
  console.log('Experiment 02 PASSED: no oversell, winners == floor(capacity/q).');
}
