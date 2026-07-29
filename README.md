<!--
  Hub-repo README (atlas-event-lab/atlas). This is the repo-level front door: what lives HERE
  (architecture, the deploy automation, the experiments) and how to use it. The project vision,
  the "why", and the org-wide overview live in the organization profile:
    https://github.com/atlas-event-lab  (rendered from atlas-event-lab/.github → profile/README.md)
  Community-health files (LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY) live in that same
  `.github` repo and GitHub applies them to this repo automatically.
-->

<div align="center">

# 🌍 Atlas — hub

**The central repo: the architecture, the one-command deployment, and the experiments.**

Stand up the **entire** event-driven platform on your own Kubernetes cluster — the 8 services,
Kafka, Postgres, Keycloak, autoscalers, and full observability — then run the experiments that
turn its guarantees into evidence.

[![Deploy](https://img.shields.io/badge/deploy-any%20Kubernetes-326ce5.svg)](./DEPLOYMENT-RUNBOOK.md)
[![Architecture](https://img.shields.io/badge/docs-diagrams%20%26%20ADRs-informational.svg)](./diagrams)
[![Status](https://img.shields.io/badge/status-active%20learning%20lab-brightgreen.svg)](#)

**New here?** Start with the project overview and vision on the
**[organization profile](https://github.com/atlas-event-lab)**, then come back to run it.

</div>

---

## What's in this repo

This is the **hub** — everything you need to understand, deploy, and experiment on Atlas:

- **The architecture** — diagrams and the decision records behind them.
- **The deployment automation** — GitOps + scripts that bring the whole stack up on a fresh
  cluster, plus a manual runbook and a local Docker-Compose option.
- **The experiments** — the resilience/scalability probes, with their scripts and results.

The **service code** lives in its own per-service repositories under the
[organization](https://github.com/atlas-event-lab); this repo wires them together and deploys them.

---

## Understand the architecture

Start with the diagrams in **[`diagrams/`](./diagrams)** — system context, the booking saga
(happy path _and_ compensation), the service state machines, the payment flow, the CQRS search
projections, and the Kafka event/topic map:

| Diagram | What it shows |
|---------|---------------|
| [`diagrams/README.md`](./diagrams/README.md) | Index + system context |
| [`diagrams/booking-saga.md`](./diagrams/booking-saga.md) | The saga: confirm, fail, time out, compensate |
| [`diagrams/inventory.md`](./diagrams/inventory.md) | Reservation locks & the no-oversell invariant |
| [`diagrams/payment.md`](./diagrams/payment.md) | Crash-safe, idempotent charging |
| [`diagrams/search-cqrs.md`](./diagrams/search-cqrs.md) | CQRS read models built from events |
| [`diagrams/events-and-topics.md`](./diagrams/events-and-topics.md) | The Kafka event & topic map |

The **reasoning** behind each design decision is captured as
**[Architecture Decision Records](./docs/adr)** in `docs/adr/`.

**Non-negotiable principles:** database per service (no cross-service joins or foreign keys) ·
no distributed transactions / 2PC — consistency via the **Saga pattern** · events preferred over
synchronous REST · every endpoint born from a contract · identity via Keycloak JWTs validated by
each service.

---

## Services

Each service is an independent repository with its own CI pipeline; this repo deploys them.

| Service | Responsibility | Status |
|---------|----------------|--------|
| API Gateway | Single entry point · path routing (nginx / ingress-nginx) | Config-only |
| User | Profile & preferences | Implemented |
| Flight | Flight catalog | Implemented |
| Hotel | Hotel catalog | Implemented |
| Inventory | Seat/room availability & reservation locks (no-oversell) | Implemented |
| Travel Cart | Pre-booking selection (1 flight + 1 hotel), TTL | Implemented |
| Booking | Booking lifecycle · saga choreography | Implemented |
| Payment | Payment lifecycle · crash-safe, idempotent charging | Implemented |
| Search | Flight & hotel search read models (CQRS) | Implemented |
| Notification | Email notifications | Planned |

---

## Start here — the path

The whole point of Atlas is to **deploy your own cluster and run the experiments on it**, then
_see_ the evidence in Grafana — that only happens on Kubernetes, not locally.

And you can stand up the **entire architecture** yourself: the 8 services, **Kafka** and its
autoscalers, the **Postgres** databases, the **observability** stack (Prometheus / Loki / Tempo /
Grafana), and **Keycloak** for auth — all wired together and **automated in scripts**, so you
spin it up quickly and spend your time on the experiments instead of on plumbing. That is the
fast path to building real intuition for **Kafka, Event-Driven Architecture, distributed systems,
observability, and microservices**.

1. **Skim the [diagrams](./diagrams)** — context, the saga, the state machines. ~10 min.
2. **Bring up the whole stack on a cluster.** Two ways, same manifests:
   - **Manual runbook** — the ~30 ordered `kubectl`/`helm` commands, to understand what each
     piece does: **[`DEPLOYMENT-RUNBOOK.md`](./DEPLOYMENT-RUNBOOK.md)** (Oracle OKE or Civo on
     trial credits, with a per-vendor porting table).
   - **GitOps (recommended)** — `terraform apply` for a trial-credit cluster, then **one**
     `bootstrap.sh`, and Argo CD converges the entire stack wave by wave:
     **[`deploy/argocd/README.md`](./deploy/argocd/README.md)**.
   

   > **What it costs — and the free credits.** The stack runs on a **12 vCPU / 48 GB** cluster.
   > It's built for the free-trial credits of **Oracle Cloud (OKE)** and **Civo** — less
   > mainstream than AWS/GCP, but their trials hand you **enough** resources for the whole stack,
   > and both are where these experiments were actually run. Rough compute at 24/7:
   > **Civo ≈ $0.36/h (~$261/mo)** — the ~$250 trial buys **~700 cluster-hours**, plenty for
   > part-time use; **Oracle ≈ $0.22/h (~$155/mo)**, and only **~$17/mo** if you run it ~4 h/day.
   > The real cost lever is **destroying the cluster when idle** (step 6). Full model:
   > [`deploy/ops/README.md`](./deploy/ops/README.md) and
   > [`deploy/cluster/civo/terraform/README.md`](./deploy/cluster/civo/terraform/README.md).
3. **Make your first booking and open the dashboards** — Grafana (RED metrics, Kafka, traces
   threaded across the saga) and the Kafka UI. Each guide's **"See it work"** section walks you
   through it.
4. **Run the experiments** → **[`experiments/`](./experiments)**: load-test it (Exp 01), replay
   duplicates (Exp 03), kill a consumer mid-saga (Exp 04) — and watch it scale, heal, and never
   oversell or double-charge, **live in Grafana**.
5. **Read the [ADRs](./docs/adr)** to see _why_ each decision was made.
6. **Tear it down when you're done — so an idle cluster doesn't keep billing you.** A cloud
   charges for worker nodes while they are **running**, regardless of load, so destroy the
   cluster (or scale it to zero) the moment you finish experimenting:
   - **Civo:** `./deploy/ops/civo/cluster.sh down` or `terraform destroy` — the cluster is
     gone and billing drops to **$0**. It cleans up the orphaned block volumes for you (the raw
     `terraform destroy` gotcha is [TS-CIVO-03](./deploy/TROUBLESHOOTING.md#ts-civo-03--civo-terraform-destroy-fails-databasenetworkinusebyvolumes)).
   - **Oracle OKE:** `./deploy/ops/oracle/cluster-down.sh` — scales the node pool to **0** so the
     workers terminate; PVC data persists for the next `up`.

   The two on/off levers, what still bills while down, and the full cost model are in
   **[`deploy/ops/README.md`](./deploy/ops/README.md)**.

> **Just want to poke the API by hand, without a cluster?** There's a local Docker-Compose
> walkthrough in [`deploy-local/LOCAL-DEPLOYMENT.md`](./deploy-local/LOCAL-DEPLOYMENT.md).
> It's for manual API play only — the experiments need Kubernetes.

Stuck on a deploy? Known issues and fixes live in
**[`deploy/TROUBLESHOOTING.md`](./deploy/TROUBLESHOOTING.md)**.

---

## How it's built

Atlas is developed with **Specification-Driven Development (SDD)**: behavior is designed as
specifications and contracts first, and the code implements them. REST endpoints are
**contract-first**; events are described in **AsyncAPI**; cross-cutting and cross-service
decisions are captured as **ADRs**. Consistency is enforced mechanically (formatting via Spotless,
style via Checkstyle, tests as a CI gate).

---

## Tech stack

Java 21 · Spring Boot · Spring Data JPA · PostgreSQL · Apache Kafka · Redis · Keycloak ·
nginx / ingress-nginx · Docker · Kubernetes · Helm · Argo CD · Strimzi · CloudNativePG · KEDA ·
Prometheus · Loki · Tempo · Grafana · GitHub Actions · k6 · Terraform

---

## Future Changes

- **Notification service** (email / notification history) — specified, not yet built.
- **Phase 2 — Saga orchestration**: migrate the same saga from choreography to orchestration to
  compare the two approaches head-to-head.
- **CDC for the outbox pattern** — replace the polling outbox relay with **log-based Change Data
  Capture via Debezium**, streaming committed changes straight from the Postgres WAL to Kafka.
- **Avro + Schema Registry** — move Kafka messaging to **Avro** serialization backed by a
  **Schema Registry**, for enforced, versioned event schemas and compatibility checks.
---

_Part of the **Atlas Event Lab** — see the [organization profile](https://github.com/atlas-event-lab)
for the vision, the full overview, contributing guide, and license (Apache-2.0)._
