// Booking-flow helpers shared across experiments: discover real, in-stock bookable flights
// and hotels from the Search API, and create a booking through the Booking API. Both are
// grounded in the OpenAPI contracts (docs/contracts/openapi/{search,booking}.yaml).
//
// Offer shape (uniform across flight/hotel so cart.js and createBooking treat them alike):
//   flight -> { type:'FLIGHT', resourceId:<flightId>,   unitPrice, quantity, available, label }
//   hotel  -> { type:'HOTEL',  resourceId:<roomTypeId>, hotelId:<groupId>, unitPrice, quantity, available, label }

import http from 'k6/http';
import { check } from 'k6';
import { API, CONFIG } from './config.js';
import { authHeaders } from './auth.js';

// A tiny UUID v4 (crypto.randomUUID isn't available in all k6 builds).
export function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function plusDays(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

// Add N days to a 'YYYY-MM-DD' date, returning 'YYYY-MM-DD'.
function addDays(isoDate, n) {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// The date a route departs on: its own departureDate, else today + 30 days.
function routeDepartureDate(route) {
  return route.departureDate || plusDays(30);
}

// Build a URL-encoded query string. Essential for values with spaces or non-ASCII, e.g.
// city="San Francisco" / "São Paulo" / "Medellín" — without encoding the URL is malformed
// and the search endpoint rejects it (non-200).
function qs(params) {
  return Object.entries(params)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');
}

// ── Flights ──────────────────────────────────────────────────────────────────
// GET /search/flights (anonymous) for ONE route, on that route's departureDate. Returns the
// in-stock flight offers for it. Params are flat query params (Spring @ModelAttribute of
// FlightSearchRequest). Discovery is per-route so a journey's flight stays coherent with its
// hotel (same ROUTES entry) — see load.js setup().
export function searchFlights(route) {
  const departureDate = routeDepartureDate(route);
  const q = qs({
    origin: route.origin,
    destination: route.destiny,
    departureDate,
    adults: CONFIG.search.adults,
    size: CONFIG.search.pageSize,
  });
  const res = http.get(`${API}/search/flights?${q}`, { tags: { name: 'search_flights' } });
  if (res.status !== 200) {
    throw new Error(`Flight search failed for ${route.origin}-${route.destiny} on ${departureDate}: ${res.status} ${res.body}`);
  }
  const offers = [];
  for (const o of res.json('content') || []) {
    if (o.available > 0 && o.basePrice) {
      offers.push({
        type: 'FLIGHT',
        resourceId: o.flightId,
        unitPrice: o.basePrice,
        quantity: 1,
        available: o.available,
        label: `${route.origin}-${route.destiny}`,
      });
    }
  }
  return offers;
}

// ── Hotels ───────────────────────────────────────────────────────────────────
// GET /search/hotels (anonymous) for ONE route's city, checking in on the route's
// departureDate (so flight and hotel are also coherent in time) for CONFIG.search.nights.
// HotelGroup[] each has rooms[] (RoomDto); we flatten to one offer per available room type.
export function searchHotels(route) {
  const checkIn = routeDepartureDate(route);
  const checkOut = addDays(checkIn, CONFIG.search.nights);
  const q = qs({
    city: route.city,
    checkIn,
    checkOut,
    rooms: CONFIG.search.rooms,
    guests: CONFIG.search.guests,
    size: CONFIG.search.pageSize,
  });
  const res = http.get(`${API}/search/hotels?${q}`, { tags: { name: 'search_hotels' } });
  if (res.status !== 200) {
    throw new Error(`Hotel search failed for ${route.city} on ${checkIn}..${checkOut}: ${res.status} ${res.body}`);
  }
  const offers = [];
  for (const group of res.json('content') || []) {
    for (const room of group.rooms || []) {
      if (room.roomsAvailable > 0 && room.pricePerNight) {
        offers.push({
          type: 'HOTEL',
          resourceId: room.roomTypeId,
          hotelId: group.id, // booking's HOTEL item needs the containing hotel id
          unitPrice: room.pricePerNight,
          quantity: CONFIG.search.rooms,
          available: room.roomsAvailable,
          checkIn,  // stay range — required by cart & booking for HOTEL items (ADR-0010/0011)
          checkOut,
          label: `${route.city}`,
        });
      }
    }
  }
  return offers;
}

// ── Contention (Experiment 02) ────────────────────────────────────────────────
// Resolve EXACTLY ONE offer — the single scarce resource every VU will contend on. Unlike the
// per-route fan-out used for spread load, this pins the journey to one flight/room-type so
// concurrent bookings collide on one pessimistically-locked inventory row (state_machine.md
// §Concurrency). Discovery reuses searchFlights/searchHotels against the CONFIG.contention
// target; filters by resourceId when given, otherwise expects the target to expose exactly one
// in-stock resource. Throws (fails setup) if it can't resolve a single unambiguous offer.
export function resolveContentionOffer(scenario) {
  const c = CONFIG.contention;
  if (scenario === 'both') {
    throw new Error("SCENARIO='both' is not meaningful for contention — pin ONE resource (flight|hotel).");
  }
  const wantHotel = scenario === 'hotel';

  if (wantHotel && !c.city) throw new Error('CONTENTION_CITY is required for SCENARIO=hotel.');
  if (!wantHotel && !(c.origin && c.destiny)) {
    throw new Error('CONTENTION_ORIGIN and CONTENTION_DESTINY are required for SCENARIO=flight.');
  }

  const route = {
    origin: c.origin,
    destiny: c.destiny,
    city: c.city,
    departureDate: c.departureDate, // '' → searchers default to today + 30 days
  };
  let offers = wantHotel ? searchHotels(route) : searchFlights(route);

  if (c.resourceId) {
    offers = offers.filter((o) => o.resourceId === c.resourceId);
  }

  if (offers.length === 0) {
    throw new Error(
      `No in-stock ${wantHotel ? 'hotel' : 'flight'} resolved for the contention target ` +
      `(${wantHotel ? c.city : `${c.origin}-${c.destiny}`}${c.departureDate ? ` on ${c.departureDate}` : ''}` +
      `${c.resourceId ? `, resourceId=${c.resourceId}` : ''}). Seed it, fix the date, or check CONTENTION_RESOURCE_ID.`,
    );
  }
  if (offers.length > 1) {
    throw new Error(
      `Contention target is ambiguous — ${offers.length} in-stock resources match ` +
      `(${offers.map((o) => o.resourceId).join(', ')}). Set CONTENTION_RESOURCE_ID to pick exactly one.`,
    );
  }
  const offer = offers[0];
  // Override the per-booking quantity q (seats/rooms) from config.
  offer.quantity = CONFIG.contention.quantity || 1;
  return offer;
}

// ── Booking ──────────────────────────────────────────────────────────────────
// One synthetic traveler. Static data is fine — the experiment measures the pipeline, not
// traveler validation. documentNumber is randomized to avoid unintended dedup.
function traveler() {
  return {
    firstName: 'Load',
    lastName: 'Tester',
    dateOfBirth: '1990-01-01',
    nationality: 'PE',
    documentType: 'PASSPORT',
    documentNumber: `LT${Math.floor(Math.random() * 1e9)}`,
    email: 'loadtest@atlas.example',
    phoneNumber: '+51999999999',
  };
}

// Map a discovered offer to a BookingItemSelectionRequest. HOTEL items also carry the
// containing hotelId and the stay range checkIn/checkOut (required for HOTEL — ADR-0010).
function toBookingItem(offer) {
  const item = {
    type: offer.type,
    resourceId: offer.resourceId,
    quantity: offer.quantity || 1,
    unitPrice: offer.unitPrice, // MoneyDto { amount, currency }
  };
  if (offer.hotelId) item.hotelId = offer.hotelId;
  if (offer.checkIn) item.checkIn = offer.checkIn;
  if (offer.checkOut) item.checkOut = offer.checkOut;
  return item;
}

// POST /bookings for one or more offers. `total` is a MoneyDto (the cart's totalInUSD),
// required by the contract. Returns 201 (created) or 200 (idempotent replay). Each call
// uses a fresh Idempotency-Key unless one is supplied.
export function createBooking(offers, total, idempotencyKey) {
  const list = Array.isArray(offers) ? offers : [offers];
  const payload = JSON.stringify({
    travelers: [traveler()],
    items: list.map(toBookingItem),
    total, // MoneyDto — comes from cart.totalInUSD (see cart.js)
  });

  const res = http.post(`${API}/bookings`, payload, {
    headers: authHeaders(idempotencyKey || uuid()),
    tags: { name: 'create_booking' }, // isolates POST /bookings latency in the summary
  });

  check(res, {
    'booking accepted (200/201)': (r) => r.status === 200 || r.status === 201,
  });
  return res;
}
