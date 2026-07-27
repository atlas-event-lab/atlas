# Changelog

All notable changes to Atlas are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> The `[1.0.0]` notes below are **prepared but not yet tagged**. v1.0.0 is gated on one
> acceptance test: **standing up the full platform on a fresh Kubernetes cluster by following
> [`DEPLOYMENT-RUNBOOK.md`](./DEPLOYMENT-RUNBOOK.md) alone** — proving the portability thesis
> is documented, not just intended. Tag `v1.0.0` once that succeeds (ideally on a different
> cloud than the one it was developed on). Until then, this section is the release candidate.

## [Unreleased]

### Added

- **GitOps deployment (Argo CD)** under [`deploy/argocd/`](./deploy/argocd/README.md): an
  app-of-apps root + sync-waves brings up the whole stack (operators, stateful CRs, the 8
  services via an `ApplicationSet`, observability, KEDA) and self-heals it. Deploy is now
  `terraform apply` + one idempotent `bootstrap.sh` (DB secrets, WireMock CM, `atlas-issuer`,
  LB-host patching), watchable wave-by-wave in the Argo UI. Custom health gates the stateful-CR
  waves on real CNPG/Kafka/Keycloak readiness. The manual `DEPLOYMENT-RUNBOOK.md` is kept as the
  didactic path (its Steps 1–8 map 1:1 to the waves); new `TS-ARGO-01..04` troubleshooting cases.

- Tag `v1.0.0` after the deployment-runbook acceptance test passes on a fresh cluster.

## [1.0.0] — _pending runbook validation_

First public release of Atlas — an open, event-driven distributed-systems **learning
laboratory**: a simplified travel-booking platform you can run locally, break on purpose,
load-test, and deploy to any Kubernetes, with every guarantee demonstrated by a reproducible
experiment.

### Platform & domain

- Eight implemented services — User, Flight, Hotel, Inventory, Travel Cart, Booking, Payment,
  Search — plus an nginx / ingress-nginx gateway and a WireMock fake payment provider.
- End-to-end booking flow driven by a **choreographed Saga** across Booking, Inventory and
  Payment, with full compensation on failure/timeout/cancellation.
- **Database per service** (no cross-service joins or foreign keys); no distributed
  transactions / 2PC.

### Event-driven & data

- Apache Kafka (KRaft) as the event backbone, with a **transactional outbox**, **idempotent
  consumers** (effectively-once processing), retry policy, and **per-consumer dead-letter
  topics** with a manual replay path.
- **CQRS** read models in Search (flight/hotel catalog + per-night availability), rebuildable
  from the event log; catalog/availability **resync** for rebuilds beyond retention.
- Identity via Keycloak (OAuth2 / OIDC); each service validates JWTs.

### Deployment & operations

- **Vendor-agnostic Kubernetes** deployment: all stateful infrastructure (PostgreSQL via
  CloudNativePG, Kafka via Strimzi, Keycloak via its operator) runs in-cluster, so only the
  node pool and LoadBalancer are vendor-specific.
- Helm library chart with per-service values; sealed/imperative secrets; cost/capacity
  controls (idle-down and cluster on/off scripts).
- Autoscaling under load (HPA + KEDA on Kafka lag).
- A full **local stack** via Docker Compose (services + Kafka + Postgres + Keycloak + Redis +
  the fake provider + gateway).

### Observability

- OpenTelemetry distributed tracing threaded across the saga; Prometheus metrics, Loki logs,
  Tempo traces, and Grafana dashboards (RED, Kafka, CloudNativePG, per-experiment).

### Experiments (demonstrated, not asserted)

- Seven reproducible resilience/scalability experiments with hypotheses, k6/fault-injection
  scripts and recorded results: high-booking concurrency, inventory contention (no oversell),
  duplicate-message idempotency, consumer crash mid-saga (no double charges), payment
  timeout → compensation, DLQ recovery, and read-model rebuild.

### Documentation & quality

- Central README, local **QUICKSTART**, a vendor-agnostic **DEPLOYMENT-RUNBOOK** (with a
  per-vendor porting table), architecture **diagrams** (context, saga, state machines,
  payment, CQRS, event map), and **27 Architecture Decision Records**.
- Specification-Driven Development; contract-first REST (OpenAPI) and AsyncAPI events.
- CI gates: Spotless (formatting) + Checkstyle (style) + tests, per service.

### License & community

- Apache License 2.0. Contributing guide, code of conduct, security policy, and issue / PR
  templates included.

<!-- Version-compare links — adjust the org/repo to the real atlas repository before publishing.
[Unreleased]: https://github.com/atlas-event-lab/atlas/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/atlas-event-lab/atlas/releases/tag/v1.0.0
-->
