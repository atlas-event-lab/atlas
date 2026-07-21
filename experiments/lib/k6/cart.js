// Travel-cart helpers. Grounded in docs/contracts/openapi/travel-cart.yaml.
//
// Flow: a booking's authoritative total comes from the cart. You create a cart, add items
// to it (the cart re-prices and aggregates), and read back `totalInUSD` — the USD total
// that POST /bookings expects as `total`. This mirrors the real client journey
// (search -> cart -> checkout) instead of POSTing a booking out of thin air.
//
//   POST /carts                       -> CartResponse { id, ... }        (createCart)
//   PUT  /carts/{cartId}/flight       body CartItemUpsertRequest         (addFlight)
//   PUT  /carts/{cartId}/hotel        body CartItemUpsertRequest         (addHotel)
//   -> CartResponse { totalInUSD: MoneyDto, items[], ... }

import http from 'k6/http';
import { check } from 'k6';
import { API } from './config.js';
import { authHeaders } from './auth.js';

// POST /carts (no body). Returns the created cart's id.
export function createCart() {
  const res = http.post(`${API}/carts`, null, {
    headers: authHeaders(),
    tags: { name: 'create_cart' },
  });
  check(res, { 'cart created (200)': (r) => r.status === 200 });
  return { res, cartId: res.json('id') };
}

// PUT /carts/{cartId}/{type}. `type` is 'flight' or 'hotel'. The endpoint determines the item
// kind; the body is CartItemUpsertRequest — HOTEL additionally requires checkIn/checkOut (the
// stay range, ADR-0011), which the service validates and forwards to Booking at checkout.
function addItem(cartId, type, item) {
  const payload = JSON.stringify({
    resourceId: item.resourceId,
    unitPrice: item.unitPrice, // MoneyDto { amount, currency }
    quantity: item.quantity || 1,
    ...(item.checkIn ? { checkIn: item.checkIn } : {}),
    ...(item.checkOut ? { checkOut: item.checkOut } : {}),
  });
  const res = http.put(`${API}/carts/${cartId}/${type}`, payload, {
    headers: authHeaders(),
    tags: { name: `add_${type}` },
  });
  check(res, { [`${type} added (200)`]: (r) => r.status === 200 });
  return res;
}

// Add a flight offer (from searchFlights) to the cart. Returns the CartResponse.
export function addFlight(cartId, offer) {
  return addItem(cartId, 'flight', {
    resourceId: offer.resourceId,
    unitPrice: offer.unitPrice,
    quantity: offer.quantity || 1,
  });
}

// Add a hotel room-type offer to the cart. Returns the CartResponse. Forwards the stay range
// (checkIn/checkOut) discovered by searchHotels — required for HOTEL items (ADR-0011).
export function addHotel(cartId, offer) {
  return addItem(cartId, 'hotel', {
    resourceId: offer.resourceId,
    unitPrice: offer.unitPrice,
    quantity: offer.quantity || 1,
    checkIn: offer.checkIn,
    checkOut: offer.checkOut,
  });
}

// Add any offer to the cart, dispatching on its type. Returns the CartResponse.
export function addOffer(cartId, offer) {
  return offer.type === 'HOTEL' ? addHotel(cartId, offer) : addFlight(cartId, offer);
}

// Mark the cart CONVERTED (POST /carts/{cartId}/conversion). The real frontend calls this
// after a successful POST /bookings; doing the same closes the journey and leaves the user a
// fresh ACTIVE cart for their next iteration. Idempotent per the service spec.
export function convertCart(cartId) {
  const res = http.post(`${API}/carts/${cartId}/conversion`, null, {
    headers: authHeaders(),
    tags: { name: 'convert_cart' },
  });
  check(res, { 'cart converted (200)': (r) => r.status === 200 });
  return res;
}

// Pull the USD total off a CartResponse — this is what maps to booking.total.
export function totalInUSD(cartResponse) {
  return cartResponse.json('totalInUSD'); // MoneyDto { amount, currency }
}
