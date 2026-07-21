# Plan — Update experiments for date-based hotel inventory (ADR-0008/0009/0010/0011)

> Planning only. Two targets: (A) `scripts/reset-state.sh`, (B) the k6 harness under
> `01-high-booking-concurrency/` + `lib/k6/`. Field names/tables below were verified against
> the current migrations and DTOs.

---

## A. `scripts/reset-state.sh`

**What changed underneath it:**
- inventory-db: `inventory` was renamed to **`flight_inventory`** (dropped `resource_type` /
  `parent_resource_id`), and hotel stock now lives in **`room_type_availability`** (per night,
  column `reserved`). `reservations` gained `check_in`/`check_out` (same table).
- search-db: **`availability_projections` was dropped**. Flight availability folded into
  **`flight_projections`** (`reserved`, `version`); hotel availability is
  **`room_type_availability`** (`reserved`, `version`, per night).
- Availability events are now **absolute + `version`** (not delta counters). Inventory emits
  `version = clock.millis()` (monotonic wall clock).

**A1. inventory_db block** — replace the single `UPDATE inventory …` with two updates; the
TRUNCATE stays as-is (`reservations` / `reservation_history` / `consumed_events` / `outbox`
are still valid table names):

```diff
 info "inventory_db (truncate reservations/outbox; reset stock counters, keep seeded rows)"
 psql_do inventory_db \
   "TRUNCATE TABLE reservations, reservation_history, consumed_events, outbox RESTART IDENTITY CASCADE;"
-psql_do inventory_db \
-  "UPDATE inventory SET reserved_count = 0, updated_at = now();"
+psql_do inventory_db \
+  "UPDATE flight_inventory SET reserved_count = 0, updated_at = now();"
+psql_do inventory_db \
+  "UPDATE room_type_availability SET reserved = 0, updated_at = now();"
```

**A2. search_db block** — `availability_projections` no longer exists; reset the two new
carriers of `reserved`. Also zero `version` so the projection is a pristine baseline (safe:
post-reset events carry `version = clock.millis()` ≫ 0, so they always re-apply; strictly it
would also work without zeroing because the clock is monotonic, but zeroing removes any doubt):

```diff
 info "search_db (reset read-model reserved to mirror inventory; keep catalog + capacity)"
-# availability_projections.reserved is a delta counter fed by inventory events; it will NOT
-# self-correct on idle. Reset it to 0 (same baseline as inventory.reserved_count) WITHOUT
-# truncating — capacity comes from catalog events and would not be repopulated while idle.
-psql_do search_db \
-  "UPDATE availability_projections SET reserved = 0, updated_at = now();"
+# reserved is now an ABSOLUTE value guarded by `version` (ADR-0008/0009), split across
+# flight_projections (flights) and room_type_availability (hotels, per night). Reset both to 0
+# WITHOUT truncating — capacity/calendar come from catalog events and won't be repopulated
+# while idle. Zero `version` too so any post-reset availability event re-applies cleanly.
+psql_do search_db \
+  "UPDATE flight_projections SET reserved = 0, version = 0, updated_at = now();"
+psql_do search_db \
+  "UPDATE room_type_availability SET reserved = 0, version = 0, updated_at = now();"
 psql_do search_db \
   "TRUNCATE TABLE consumed_events RESTART IDENTITY;"
```

**A3. Header comment** (top of file) — update the "Read model" line from the delta wording:

```diff
-#   • Read model— search availability_projections.reserved reset to 0 to mirror inventory
-#                 (delta counter maintained from inventory events; catalog/capacity kept).
+#   • Read model— search reserved reset to 0 to mirror inventory, across flight_projections
+#                 and room_type_availability (absolute + version model; catalog/capacity kept).
```

**A4. Final spot-check queries** — the `inventory`/`availability_projections` sums no longer
resolve:

```diff
-  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d inventory_db -c 'SELECT sum(reserved_count) FROM inventory;'"
-  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d search_db    -c 'SELECT sum(reserved) FROM availability_projections;'"
+  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d inventory_db -c 'SELECT sum(reserved_count) FROM flight_inventory;'"
+  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d inventory_db -c 'SELECT sum(reserved) FROM room_type_availability;'"
+  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d search_db    -c 'SELECT sum(reserved) FROM flight_projections;'"
+  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d search_db    -c 'SELECT sum(reserved) FROM room_type_availability;'"
```

**No change** needed to the booking / payment / travel_cart / flight / hotel blocks: the
SINGLE_TABLE inheritance (booking_items, cart_items, reservations) reuses the same physical
tables, and the outbox truncations are unchanged.

**Also update** `scripts/reset-state.md` (the companion doc) to mention the new tables.

**Optional (out of scope of a plain reset):** if you ever need the hotel calendar itself
rebuilt (e.g. after the horizon rolled), that requires a catalog replay/reconcile, not a
`reserved` reset — the reset intentionally keeps capacity/calendar rows and only zeroes
`reserved`.

---

## B. k6 harness (`01-high-booking-concurrency/` + `lib/k6/`)

**Good news — already date-aware where it reads:** `searchHotels` (booking.js) already sends
`checkIn`/`checkOut` to `GET /search/hotels`, and the grouped response shape it parses
(`content[].rooms[].{roomTypeId,roomsAvailable,pricePerNight}`, `content[].id` as hotelId)
matches the current `HotelSearchResponse`. `CONFIG.search.nights` (default 2) drives
`checkOut = checkIn + nights`. Flights are unaffected (a flight already is a date).

**The gap — dates are dropped after discovery.** The hotel selection must now carry the stay
range all the way through: `CartItemUpsertRequest` and `BookingItemSelectionRequest` both have
`checkIn`/`checkOut` (verified), **required for HOTEL** (service-side cross-field validation →
a HOTEL cart-add or booking without them returns 400). Today the k6 offer object and the
cart/booking payloads omit them. Three small edits:

**B1. `lib/k6/booking.js` → `searchHotels`:** attach the stay dates to each hotel offer so
downstream steps can forward them. `checkIn`/`checkOut` are already computed locally:

```diff
       offers.push({
         type: 'HOTEL',
         resourceId: room.roomTypeId,
         hotelId: group.id,
         unitPrice: room.pricePerNight,
         quantity: CONFIG.search.rooms,
         available: room.roomsAvailable,
+        checkIn,
+        checkOut,
         label: `${route.city}`,
       });
```

**B2. `lib/k6/cart.js` → hotel add:** include the dates in the upsert body for HOTEL. Make
`addItem` accept optional dates and have `addHotel` pass them (flights send none):

```diff
-function addItem(cartId, type, item) {
+function addItem(cartId, type, item) {
   const payload = JSON.stringify({
     resourceId: item.resourceId,
     unitPrice: item.unitPrice,
     quantity: item.quantity || 1,
+    ...(item.checkIn ? { checkIn: item.checkIn } : {}),
+    ...(item.checkOut ? { checkOut: item.checkOut } : {}),
   });
   ...
 }

 export function addHotel(cartId, offer) {
   return addItem(cartId, 'hotel', {
     resourceId: offer.resourceId,
     unitPrice: offer.unitPrice,
     quantity: offer.quantity || 1,
+    checkIn: offer.checkIn,
+    checkOut: offer.checkOut,
   });
 }
```

**B3. `lib/k6/booking.js` → `toBookingItem`:** add the dates for HOTEL items:

```diff
 function toBookingItem(offer) {
   const item = {
     type: offer.type,
     resourceId: offer.resourceId,
     quantity: offer.quantity || 1,
     unitPrice: offer.unitPrice,
   };
   if (offer.hotelId) item.hotelId = offer.hotelId;
+  if (offer.checkIn)  item.checkIn  = offer.checkIn;
+  if (offer.checkOut) item.checkOut = offer.checkOut;
   return item;
 }
```

That is the whole functional change; `load.js`, `auth.js`, `config.js` and `.env.example`
need **no** code change for correctness (only the data caveats below).

### Data / measurement caveats to check before a hotel run
- **Route dates vs the horizon & today.** `/search/hotels` requires `checkIn ≥ today` and
  every night of `[checkIn, checkOut)` must exist in the seeded calendar (inventory horizon =
  `INVENTORY_HOTEL_HORIZON_DAYS`, default **365**; search mirrors it). `searchHotels` throws on
  a non-200, which aborts `setup()`. So for `SCENARIO=hotel`/`both`, ensure every ROUTES
  `departureDate` (used as check-in) is ≥ today and `departureDate + nights` is within 365 days
  — the current table has a few near/at "today" and far-2027 dates; trim or refresh them, or
  keep `hotel`/`both` on a curated near-term subset.
- **Per-night contention is the new concurrency axis.** With per-night stock, only journeys
  hitting the **same room type on overlapping nights** actually compete. Since a bundle fixes
  city+date and picks a random room, contention is realistic — but if seeded `total_rooms` per
  night is small, high RPS will drive `INVENTORY_REJECTED` (async saga failure). Note: k6 counts
  POST `/bookings` 201 as success (it's just the saga kickoff); the later rejection won't show
  in `booking_success_rate`. For a clean throughput baseline seed generous per-night capacity,
  or watch inventory/booking terminal states separately.
- **`nights` and pricing.** Booking now charges `pricePerNight × nights × rooms`; the cart’s
  `totalInUSD` already reflects it, and the harness passes the cart total to booking, so the
  price-revalidation (ADR-0001/0010) stays consistent — no k6 change, just be aware the totals
  are larger for `nights>1`.

### Verification
- Smoke first: `k6 run -e SCENARIO=hotel -e ITERATIONS=5 load.js` — should create 5 bookings
  with 201s; a 400 on cart-add or booking means dates aren’t being forwarded (B2/B3).
- Then `SCENARIO=both` smoke, then the ramping load.
