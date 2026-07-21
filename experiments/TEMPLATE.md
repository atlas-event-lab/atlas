# Experiment NN — <Title>

**Category:** Scalability | Correctness | Resilience | Architecture · **Type:** load /
fault-injection / … · **Status:** draft | ready | done

## Why this experiment

One paragraph: what property of the system this probes, and why it matters for an
event-driven / distributed architecture. Link the relevant spec (feature, service,
constraint ID).

## Hypothesis

A falsifiable statement of expected behavior. "When X happens, the system does Y (and not
Z)." Be specific enough that a run can prove it wrong.

## What it does

The mechanism, step by step. For a load test: the traffic shape and the endpoint. For a
fault-injection test: the exact fault (kill which pod, when; which WireMock stub; which
message), and how the system is expected to react.

## Prerequisites

- Shared setup from the [repo README](./README.md) (k6, `.env`, Grafana).
- Anything specific: seeded data, a particular Kafka broker count, an HPA min, etc.

## How to run

```bash
set -a; source ../.env; set +a
# k6 run load.js        (load experiments)
# ./runbook.sh          (fault-injection experiments)
```

List the tunable env knobs.

## What to watch (Grafana)

| Layer | Panel / query | Healthy signal |
|-------|---------------|----------------|
| … | … | … |

## Success criteria

Bullet the pass/fail conditions. These should map directly back to the hypothesis.

## Results

Record each run in `RESULTS.md`.
