# Booking Saga

The core distributed flow in Atlas: a booking is created synchronously, then confirmed
asynchronously through a **choreographed saga** across Inventory and Payment. There is no
central orchestrator and no distributed transaction — each service reacts to events and
compensates on failure.

- [1. Create booking (synchronous REST)](#1-create-booking-synchronous-rest)
- [2. Saga — happy path](#2-saga--happy-path)
- [3. Saga — failure & compensation](#3-saga--failure--compensation)
- [4. Booking state machine](#4-booking-state-machine)
- [5. Cancellation](#5-cancellation)

---

## 1. Create booking (synchronous REST)

The write that starts everything. The controller holds no business logic; the booking is
persisted as `PENDING` and `BOOKING_CREATED` is written to the outbox in the same
transaction. The request is **idempotent** on a client key so retries never double-book.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant G as API Gateway
    participant B as Booking Service
    participant DB as booking-db + outbox

    C->>G: POST /api/v1/bookings (JWT, Idempotency-Key)
    G->>G: validate JWT (Keycloak)
    G->>B: forward request (UserId from JWT)
    B->>DB: check Idempotency-Key
    alt already seen
        DB-->>B: existing booking
        B-->>C: 200 OK (same booking)
    else new
        B->>B: validate price vs Flight/Hotel
        B->>DB: INSERT booking = PENDING + outbox(BOOKING_CREATED)
        B-->>C: 201 Created (bookingId, PENDING)
    end
    Note over B,DB: outbox relay publishes BOOKING_CREATED to Kafka
```

---

## 2. Saga — happy path

`BOOKING_CREATED` triggers inventory reservation; the successful reservation carries the
`amount` that triggers payment; a successful charge confirms the booking. Every hop is a
past-tense event on its own topic.

```mermaid
sequenceDiagram
    autonumber
    participant B as Booking
    participant K as Kafka
    participant I as Inventory
    participant P as Payment
    participant W as Fake Provider
    participant S as Search

    B->>K: booking.created
    K->>I: booking.created
    I->>I: reserve seats + rooms
    I->>K: inventory.reserved (amount)
    I->>K: inventory.flight/hotel.reserved (absolute reserved, version)

    K->>B: inventory.reserved
    B->>B: PENDING → INVENTORY_RESERVED

    K->>P: inventory.reserved (amount)
    P->>P: create Payment CREATED → PROCESSING
    P->>K: payment.requested
    P->>W: POST /payments (Idempotency-Key)
    W-->>P: 200 SUCCESS
    P->>K: payment.succeeded

    K->>B: payment.succeeded
    B->>B: INVENTORY_RESERVED → CONFIRMED
    B->>K: booking.confirmed

    Note over S: Search consumes the availability events<br/>emitted when Inventory reserved (not booking.*)
    K->>S: inventory.flight/hotel.reserved
    S->>S: update availability projections
```

> **Out-of-order safety.** Inventory and Payment events reach Booking on separate,
> unordered topics. A payment outcome that arrives while the booking is still `PENDING` is
> **deferred and retried** (never applied from `PENDING`, never wrongly rejected), so it
> settles once `inventory.reserved` has been processed.

---

## 3. Saga — failure & compensation

Two failure branches. Inventory rejection fails the booking before any money moves. Payment
failure/timeout fails or expires the booking and releases the already-reserved inventory —
the compensating action.

```mermaid
flowchart TB
    created([booking.created]) --> reserve{Inventory<br/>reservable?}

    reserve -->|no| rejected[inventory.rejected]
    rejected --> failedA[Booking: PENDING → FAILED]
    failedA --> bfailed[booking.failed → Notification]

    reserve -->|yes| reserved[inventory.reserved → PROCESSING payment]
    reserved --> pay{Payment<br/>outcome}

    pay -->|succeeded| confirmed[Booking → CONFIRMED<br/>booking.confirmed]
    pay -->|failed| failedB[Booking → FAILED<br/>booking.failed]
    pay -->|timed_out| expired[Booking → EXPIRED<br/>booking.expired]

    failedB --> release[[Inventory releases seats/rooms<br/>inventory.released]]
    expired --> release
    confirmed --> confirmInv[[Inventory confirms reservation]]
```

Compensation is itself event-driven: `booking.failed` / `booking.expired` /
`booking.cancelled` are consumed by Inventory, which releases the held capacity and emits
`inventory.released`.

---

## 4. Booking state machine

Booking state is the single source of truth for the lifecycle; **only Booking mutates it**,
driven by saga events. Every transition not shown is forbidden.

```mermaid
stateDiagram-v2
    [*] --> PENDING: BOOKING_CREATED
    PENDING --> INVENTORY_RESERVED: INVENTORY_RESERVED
    PENDING --> FAILED: INVENTORY_REJECTED
    PENDING --> EXPIRED: expiration job (safety-net)

    INVENTORY_RESERVED --> CONFIRMED: PAYMENT_SUCCEEDED
    INVENTORY_RESERVED --> FAILED: PAYMENT_FAILED
    INVENTORY_RESERVED --> EXPIRED: PAYMENT_TIMED_OUT

    CONFIRMED --> CANCELLING: cancel request (REST)
    CANCELLING --> CANCELLED: INVENTORY_RELEASED

    FAILED --> [*]
    EXPIRED --> [*]
    CANCELLED --> [*]

    note right of CONFIRMED
        Content is immutable;
        status may still change
        only via cancellation.
    end note
```

Ownership detail: `PENDING → EXPIRED` is owned by the scheduled expiration job;
`INVENTORY_RESERVED → EXPIRED` is owned **only** by Payment's `PAYMENT_TIMED_OUT`, to avoid
racing an in-flight payment.

---

## 5. Cancellation

A user may cancel **only** a `CONFIRMED` booking. In-flight states are intentionally not
user-cancellable (they would race the payment pivot, and Atlas has no refund path for a
settled charge). The booking stays in `CANCELLING` until compensation is confirmed.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant B as Booking
    participant K as Kafka
    participant I as Inventory

    C->>B: POST /bookings/{id}/cancel (only if CONFIRMED)
    B->>B: CONFIRMED → CANCELLING
    B->>K: booking.cancelled
    K->>I: booking.cancelled
    I->>I: release seats + rooms
    I->>K: inventory.released
    K->>B: inventory.released
    B->>B: CANCELLING → CANCELLED
```
