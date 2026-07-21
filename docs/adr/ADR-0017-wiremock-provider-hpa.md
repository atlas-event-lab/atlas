---
adr_id: ADR-0017
title: HPA for the WireMock fake payment provider (scale with payment concurrency; idle-down)
service: Platform (WireMock)
status: COMPLETED
date: 2026-07-10
depends_on:
  - ADR-0015
---

# ADR-0017 — WireMock provider HPA

# Status

`PENDING` (created 2026-07-10). Flip to `COMPLETED` when merged (`DR-003`). Origin:
[experiments/01-high-booking-concurrency/consumer-capacity-scaling.md](../../experiments/01-high-booking-concurrency/consumer-capacity-scaling.md).
Ships together with **ADR-0015** (payment scale-up).

# Context

WireMock is the **fake payment provider** (`deploy/platform/apps/wiremock.yaml`), called by
payment-service at `PAYMENT_PROVIDER_URL`. Today it runs a **static `replicas: 2`** with no HPA.

Two forces meet:

1. **Payment is being scaled to 12 in-flight consumers** (ADR-0015) ⇒ up to **12 concurrent provider
   calls**. If WireMock can't serve them, payment's consumer lag simply becomes provider
   latency/timeouts — the bottleneck relocates. So provider capacity must track payment concurrency.
2. **WireMock is only exercised during payments.** Two pods sitting idle when there is no payment
   traffic is wasteful; it should scale down at rest.

The stub delays responses (default lognormal ~150 ms; a 7 s `TIMEOUT` fault-injection path), so each
request holds a Jetty thread/connection **asleep** — burning little CPU. The previous pod loss was a
**liveness kill under load** (health endpoint slow while CPU-throttled at 250 m), not an OOM.

# Decision

Add a **HorizontalPodAutoscaler** for the WireMock deployment:

1. **Scale on load, idle-down.** `minReplicas: 1` (lean floor at rest), `maxReplicas` sized to serve
   peak payment concurrency (start ~4; tune from the re-run). Never 0 — a cold start mid-run would
   time out the ramp.
2. **Metric — KEDA + Prometheus on payment's provider-call rate (chosen).** Because delayed responses
   are not CPU-heavy, a CPU-target HPA under-scales while the thread/connection pool saturates. KEDA
   (already installed) scales WireMock on a **Prometheus query** over payment's Feign client request
   rate (`http_client_requests_seconds_count{clientName="com.atlas.payment.client.PaymentProviderFeignClient"}`,
   confirmed against the live Prometheus; note the label is `clientName` = the full Feign client class
   name, not `payment-provider`), scraped by kube-prometheus-stack at
   `prometheus-operated.atlas-observability:9090`. Manifest:
   `deploy/platform/keda/wiremock-scaledobject.yaml`; the Deployment drops its static `replicas` so
   KEDA owns the count. Only `threshold` remains to tune from the re-run. A CPU-target HPA is kept
   only as a documented fallback.
3. **Fast scale-up, damped scale-down.** Short scale-up stabilization so it reacts to the ramp;
   longer scale-down window so it doesn't flap between payment bursts. Payment's retry ladder
   (`@RetryableTopic`) absorbs the brief warm-up window at the ramp start.
4. **Resources.** Keep the current `requests 100m/256Mi · limits 500m/512Mi` as the per-pod envelope
   (already bumped after the liveness kill); the HPA adds pods rather than growing each.

# Consequences

**Positive.** Provider capacity tracks payment concurrency, so ADR-0015's scale-up actually lands
instead of relocating the bottleneck; idle-down saves cluster budget between runs. **Negative /
trade-offs.** A non-CPU metric needs the metrics adapter wired (more moving parts than a CPU HPA);
a too-low `minReplicas` risks ramp-start timeouts (mitigated by the retry ladder and a floor of 1).

# Scope note & caveat

WireMock is a **test double**. This HPA is a **load-test-environment** decision (realism + cost of the
test cluster), **not** production architecture — in production the real payment provider is an external
dependency with its own capacity and SLAs. Captured as a platform ADR (`DR-002`); it exists to keep
Experiment 01 honest, and pairs with ADR-0015.

# Documents to update at implementation

- `deploy/platform/keda/wiremock-scaledobject.yaml` — the KEDA Prometheus ScaledObject (added).
- `deploy/platform/apps/wiremock.yaml` — drop the static `replicas` so KEDA owns the count (done).
- Metric name/labels confirmed against the live Prometheus (`http_client_requests_seconds_count`,
  label `clientName`); only `threshold` remains to tune on the re-run.

# Alternatives considered

- **Keep static `replicas`, just raise the count** (e.g. 4): serves peak but wastes the count at rest —
  the whole point was idle-down. Rejected.
- **CPU-only HPA**: simplest, but under-scales for delay-bound (sleeping) request handlers; kept only
  as a fallback with a low target + larger thread pool.
- **Scale to 0 at idle (KEDA)**: maximal savings but a guaranteed cold-start timeout at ramp start for
  a synchronous dependency; rejected for a provider on the Saga hot path.
