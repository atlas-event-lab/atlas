---
adr_id: ADR-0016
title: Raise hot-topic partitions (booking.created/confirmed → 9, inventory.reserved → 12) for consumer scale-out
service: Kafka-platform
status: COMPLETED
date: 2026-07-10
depends_on:
  - ADR-0014
  - ADR-0015
---

# ADR-0016 — Hot-topic partitions for consumer scale-out

# Status

`PENDING` (created 2026-07-10). Flip to `COMPLETED` when merged (`DR-003`). Origin:
[experiments/01-high-booking-concurrency/consumer-capacity-scaling.md](../../experiments/01-high-booking-concurrency/consumer-capacity-scaling.md).
Enables the consumer bumps in **ADR-0014** (inventory) and **ADR-0015** (payment).

# Context

`useful consumers = min(pods × concurrency, partitions)`. To let inventory reach 9 consumers and
payment reach 12 (ADR-0014/0015), the partition ceilings on the hot topics must rise. Current
(`deploy/platform/strimzi/topics.yaml`): `booking.created` = 6, `booking.confirmed` = 6,
`inventory.reserved` = 6.

# Decision

| Topic | Partitions | Consumer that needs it |
|---|---|---|
| `booking.created` | **6 → 9** | inventory saga (`3 pods × concurrency 3`) |
| `booking.confirmed` | **6 → 9** | inventory saga |
| `inventory.reserved` | **6 → 12** | payment (`4 pods × concurrency 3`) |
| `inventory.reserved-retry-*`, `-dlq` | **match main** | payment `@RetryableTopic(attempts=4)` |

Unchanged: `booking.cancelled/failed/expired` (unhappy-path, low volume) stay at 3;
`inventory.flight/hotel.reserved` (consumed by search) are **not** touched.

Constraints honoured:

- **Ordering.** `booking.*` and `inventory.reserved` are produced keyed by `bookingId` (outbox relay),
  so per-booking order is preserved across the added partitions. Search's ordering on
  `inventory.flight/hotel.reserved` is handled by the payload version field (ADR-0009) and those
  topics are out of scope here.
- **Partitions are applied by editing `topics.yaml`.** Strimzi grows partitions on existing
  `KafkaTopic` CRs directly; **only RF/replica changes need Cruise Control**
  (payment-service-scaling.md §7.5) — do not conflate. Partition counts can only be **raised**, never
  lowered, so 9 / 12 are chosen deliberately (raise again later if a re-run needs it).
- **Retry topics.** `@RetryableTopic` auto-generates the retry/DLQ topics; set their partition count to
  match `inventory.reserved` so retried events don't serialize on fewer partitions.

# Consequences

**Positive.** Lifts the parallelism ceilings that gate ADR-0014/0015; per-booking ordering intact.
**Negative.** +12 partition-replicas × RF3 ≈ +36 partition-replicas on the brokers — a few MB of
indexes/handles, negligible. Irreversible (can't shrink); acceptable at these modest counts.

# Documents to update at implementation

- `deploy/platform/strimzi/topics.yaml` — the four raises above (+ retry topics).
- Coordinate apply with ADR-0014 (inventory concurrency 3) and ADR-0015 (payment concurrency 3 / KEDA
  max 4) so consumers and partitions move together.

# Scope note

Per `DR-002`, captured as the **kafka-platform** ADR; the consuming services have their own
(ADR-0014 inventory, ADR-0015 payment).

# Alternatives considered

- **Go straight to 12 on the booking topics too**: unnecessary — inventory is capped at 3 pods ×
  concurrency 3 = 9; provisioning 12 would leave 3 idle partitions. Raise later only if inventory's
  cap rises.
- **Leave partitions, add pods only**: pods beyond the partition count sit idle (no assignment); the
  ceiling is the partition count, so it must move first.
