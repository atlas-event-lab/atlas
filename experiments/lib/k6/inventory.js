// Inventory read helpers — the ground truth for the no-oversell invariant (Experiment 02).
// Grounded in docs/contracts/openapi/inventory.yaml. Both endpoints are authenticated (only
// swagger/api-docs are public), but they enforce NO ownership — any valid pool token reads
// any resource — so setup()/teardown() (running as loadtest-1) can read the shared target.
//
//   GET /api/v1/inventory/flight/{flightId} -> FlightAvailabilityResponse
//         { flightId, totalCapacity, reservedCount, available }
//   GET /api/v1/inventory/hotel/{roomTypeId} -> HotelAvailabilityResponse (per-night)

import http from 'k6/http';
import { API } from './config.js';
import { authHeaders } from './auth.js';

// Live stock of a flight: { flightId, totalCapacity, reservedCount, available }. Throws on a
// non-200 so a misconfigured target fails loudly rather than silently skipping verification.
export function getFlightAvailability(flightId) {
  const res = http.get(`${API}/inventory/flight/${flightId}`, {
    headers: authHeaders(),
    tags: { name: 'inventory_flight' },
  });
  if (res.status !== 200) {
    throw new Error(`Inventory read failed for flight ${flightId}: ${res.status} ${res.body}`);
  }
  return res.json();
}

// Live per-night stock of a room-type over [from, to). The endpoint requires the range as
// query params (inventory.yaml). Returns the raw HotelAvailabilityResponse
// { roomTypeId, from, to, nights[]:{ stayDate, totalRooms, reserved, available, status },
//   rangeMinAvailable }.
export function getHotelAvailability(roomTypeId, from, to) {
  const res = http.get(`${API}/inventory/hotel/${roomTypeId}?from=${from}&to=${to}`, {
    headers: authHeaders(),
    tags: { name: 'inventory_hotel' },
  });
  if (res.status !== 200) {
    throw new Error(`Inventory read failed for room-type ${roomTypeId} [${from}..${to}): ${res.status} ${res.body}`);
  }
  return res.json();
}

// Read the current stock of a resolved offer (dispatch on type). Normalizes to a uniform
// shape { totalCapacity, reservedCount, available } so the experiment treats flight and hotel
// alike. For hotels, availability is per-night; we take the TIGHTEST night (min available /
// max reserved) — that is the night that gates the stay, and where oversell would first show.
export function getAvailability(offer) {
  if (offer.type === 'HOTEL') {
    const body = getHotelAvailability(offer.resourceId, offer.checkIn, offer.checkOut);
    const nights = body.nights || [];
    if (nights.length === 0) {
      throw new Error(`Hotel ${offer.resourceId} returned no nights to verify.`);
    }
    // Reduce the stay to its binding night: the tightest capacity, the most reserved, the
    // least available — that is where an oversell would first surface.
    const totalCapacity = Math.min(...nights.map((n) => n.totalRooms));
    const reservedCount = Math.max(...nights.map((n) => n.reserved));
    const available = Math.min(...nights.map((n) => n.available));
    return { totalCapacity, reservedCount, available };
  }
  const f = getFlightAvailability(offer.resourceId);
  return {
    totalCapacity: f.totalCapacity,
    reservedCount: f.reservedCount,
    available: f.available,
  };
}
