# Observability — Grafana LGTM stack

The evidence layer for the experiments (roadmap §0), added in order below:
- **Metrics** (Steps 1–2): Prometheus + Grafana scraping `/actuator/prometheus`.
- **Logs** (Step 3): Loki (single-binary) + Grafana Alloy DaemonSet. No app changes.
- **Traces** (Step 4): Tempo + Micrometer Tracing (OTLP). App changes: tracing deps + Kafka observation.
- **APM** (Step 5): RED per endpoint + Tempo service graph — for the load experiments.

Namespace: `atlas-observability`.

## Prerequisite — metrics-server (for the HPA)
The HPA needs the resource-metrics API (separate from Prometheus). If `kubectl top pods`
fails with "Metrics API not available":
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top pods -n atlas-apps
```

> If `kubectl top` still says **"Metrics API not available"** (common on managed/k3s clusters
> like Civo — the kubelet cert isn't trusted), see
> [TROUBLESHOOTING → TS-PLATFORM-03](../../TROUBLESHOOTING.md#ts-platform-03--metrics-server-metrics-api-not-available).

## Step 1 — Install kube-prometheus-stack
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n atlas-observability --create-namespace -f kube-prometheus-stack-values.yaml
kubectl -n atlas-observability rollout status deploy/kps-grafana
```
This installs the **Prometheus Operator CRDs** (PodMonitor, ServiceMonitor, …) needed by
the chart's PodMonitor. App scraping is already on — the service chart sets
`metrics.enabled: true` by default, so the PodMonitors exist from the Runbook Step 6 deploy
(toggle per service with `--set metrics.enabled=<bool>` from
[`deploy/helm/atlas-service`](../../helm/atlas-service)).

## Step 2 — Verify + explore
```bash
# Prometheus: confirm the app targets are UP
kubectl -n atlas-observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
#   open http://localhost:9090/targets  -> podMonitor/atlas-apps/* should be UP

# Grafana (admin / atlas-admin)
kubectl -n atlas-observability port-forward svc/kps-grafana 3000:80
#   open http://localhost:3000  -> add a dashboard, e.g. import 'JVM (Micrometer)' id 4701,
#   and 'Spring Boot 3.x Statistics' for http.server.requests.
```

## Step 3 — Logs (Loki + Alloy)
No app changes: the services already log structured JSON to stdout; Alloy ships it to Loki.

```bash
# 1. Loki (single-binary)
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm upgrade --install loki grafana/loki -n atlas-observability -f loki-values.yaml
kubectl get svc -n atlas-observability | grep loki      # confirm the service name/port
#   -> if it's NOT 'loki-gateway', fix the URL in alloy-values.yaml + loki-datasource.yaml

# 2. Alloy (log collector DaemonSet)
helm upgrade --install alloy grafana/alloy -n atlas-observability -f alloy-values.yaml
kubectl -n atlas-observability rollout status ds/alloy

# 3. Loki datasource in Grafana (sidecar auto-loads it, no restart)
kubectl apply -f loki-datasource.yaml
```

Verify: in Grafana → Explore → **Loki**, run `{namespace="atlas-apps"}` and you should
see live logs. Filter a service with `{app="booking-service"}`; since logs are JSON you can
parse fields, e.g. `{app="booking-service"} | json | correlationId != ""`.

> Loki/Alloy Helm charts are version-sensitive. If Alloy can't push, it's almost always the
> Loki service name in the `loki.write` URL — check `kubectl get svc -n atlas-observability`.

## Step 4 — Traces (Tempo + Micrometer)
App changes (already in the repos — commit/push to rebuild): `micrometer-tracing-bridge-otel`
+ `opentelemetry-exporter-otlp`, `management.tracing.sampling.probability: 1.0`, OTLP endpoint,
and Kafka `observation-enabled` (producer+consumer). Feign auto-propagates trace context via
Micrometer (no code change). Trace context crosses REST (Feign) and Kafka headers end-to-end.

```bash
# 1. Tempo
helm upgrade --install tempo grafana/tempo -n atlas-observability -f tempo-values.yaml
kubectl get svc -n atlas-observability | grep tempo     # confirm ports 3200 / 4317 / 4318

# 2. datasources (Tempo + updated Loki with traceId->Tempo link). Sidecar auto-loads.
kubectl apply -f tempo-datasource.yaml
kubectl apply -f loki-datasource.yaml

# 3. push the 8 service repos so CI rebuilds images WITH tracing, then they redeploy via CD
```
Verify: hit a flow that spans services (e.g. a booking that calls flight/hotel via Feign and
emits Kafka events), then Grafana → Explore → **Tempo** → Search recent traces. You should see
one trace spanning multiple services (REST + Kafka). From a **Loki** log line, click the
**TraceID** derived field to jump to its trace; from a Tempo span, jump to its logs.

> Endpoint wiring: apps push to `http://tempo.atlas-observability:4318/v1/traces`
> (`management.otlp.tracing.endpoint`, overridable via `MANAGEMENT_OTLP_TRACING_ENDPOINT`).
> Sampling is 1.0 (all traces) — fine for the lab/experiments; lower it for real load.
> Memory: Tempo adds ~256–512Mi. With the cluster already ~85% on one node, free memory first
> (clean the old ReplicaSets, or drop HPA minReplicas) before installing.

## Step 5 — APM (RED per endpoint + service graph)

Two complementary layers turn the LGTM stack into an APM view for the experiments.

**Layer A — per-endpoint RED from Micrometer (app-side).** Every service now publishes native
Prometheus histogram buckets for `http.server.requests`
(`management.metrics.distribution.percentiles-histogram` + `slo` in each `application.yml`).
That unlocks server-side percentiles and latency heatmaps per endpoint:

```promql
# p95 latency per service+endpoint
histogram_quantile(0.95, sum by (le, job, uri) (rate(http_server_requests_seconds_bucket[5m])))
# error rate per endpoint (5xx)
sum by (job, uri) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
```

Requires rebuilding + redeploying the 8 services (the change is in `application.yml`). A ready
RED dashboard ships as a provisioned ConfigMap — the Grafana sidecar auto-loads it (folder
**Atlas**, uid `atlas-red-http`):

```bash
kubectl apply -f atlas-red-dashboard.yaml
```

### Scrape Kafka — required, or the Kafka dashboard is entirely blank

Nothing scrapes Kafka until you apply its PodMonitor. It must be applied **here** rather than
in Runbook Step 4, because `PodMonitor` is a CRD that kube-prometheus-stack installs — earlier
and it fails with `no matches for kind "PodMonitor"`.

```bash
kubectl apply -f ../strimzi/kafka-exporter-podmonitor.yaml
```

One PodMonitor covers both metric families, since it selects `strimzi.io/kind: Kafka` on the
`tcp-prometheus` port and both the exporter pod and the broker pods carry that label:

| Metrics | Powering | Produced by |
|---------|----------|-------------|
| `kafka_brokers`, `kafka_consumergroup_lag`, `kafka_topic_partition_*` | Brokers online, Consumer Lag, under-replicated partitions | Kafka Exporter (`spec.kafkaExporter` in `kafka.yaml`) |
| `kafka_server_*`, `kafka_network_*`, `kafka_controller_*` | Throughput, request-handler idle, active controller | Broker JMX exporter (`spec.kafka.metricsConfig` + `kafka-metrics-configmap.yaml`, Runbook Step 4) |

Verify before moving on — an empty result here is why the dashboard is blank:

```bash
kubectl -n atlas-data get podmonitor
kubectl -n atlas-data get pods | grep -i exporter      # atlas-kafka-exporter-* must exist
# Grafana -> Explore -> Prometheus:
#   kafka_brokers                                   -> matches your broker count
#   kafka_consumergroup_lag                         -> one series per consumer group
#   kafka_server_brokertopicmetrics_bytesin_total   -> broker JMX is flowing
```

If `kafka_consumergroup_lag` returns nothing but `kafka_brokers` works, the exporter is not
running — check `spec.kafkaExporter` on the Kafka CR. The reverse (lag but no `kafka_server_*`)
means the JMX ruleset from Runbook Step 4 is missing.

**Install the remaining Atlas dashboards now, before the experiments.** They are expected to be
in Grafana by the time you reach `experiments/README.md`; the experiment guides reference them
by name and do not install them. The glob below is a superset — it re-applies the RED dashboard
you installed above, which is a harmless no-op.

```bash
# Every atlas-*-dashboard.yaml is already a ConfigMap labelled `grafana_dashboard: "1"` —
# the sidecar picks them up in ~30s. This is the same glob Argo CD uses, so the two
# deployment paths install exactly the same set and adding a dashboard needs no doc change.
for f in atlas-*-dashboard.yaml; do kubectl apply -f "$f"; done

# CNPG is the exception. --server-side is REQUIRED, not a preference: this dashboard is
# ~250 KB, and client-side apply stores the whole object in a `last-applied-configuration`
# annotation, which caps at 262144 bytes ("metadata.annotations: Too long"). Server-side
# apply writes no such annotation. Same reason the GitOps apps set ServerSideApply=true
# (TS-ARGO-04).
kubectl apply --server-side -f cnpg-dashboard.yaml
```

> `cnpg-dashboard.yaml` is generated from `cnpg-dashboard.json`, which stays in the repo as the
> source of truth (it is an upstream export). Refresh by re-exporting the JSON and regenerating
> the ConfigMap — the header of the YAML says how. Both deployment paths install the same file:
> Argo CD picks it up through the `*-dashboard.yaml` glob in `apps/40-obs-config.yaml`.

Verify — the sidecar logs each one it picks up:

```bash
kubectl -n atlas-observability get cm -l grafana_dashboard=1
```

| Dashboard | What it is for |
|---|---|
| **HTTP RED** | golden signals per endpoint — the view to keep open during every run |
| **Kafka** | consumer lag and DLQ traffic; the signal KEDA scales on |
| **CNPG** | Postgres under write pressure from the outbox |
| **Exp 01 — High Booking Concurrency** | Saga success rate + end-to-end duration vs the synchronous POST; HPA, pooler, lag |
| **Exp 02 — Inventory Contention** | `atlas_inventory_oversell_attempts_total`, the invariant that must stay `0` (Exp 03's duplicate-skip panel lives here too) |
| **Exp 04 — Consumer Crash mid-Saga** | the kill window, lag drain, duplicate skips, sweeper recoveries |
| **Exp 05 — Payment Timeout → Compensation** | units reserved vs released — the compensation closing |
| **Exp 06 — DLQ Recovery** | parked by reason vs replayed by outcome, and no double charge |
| **Exp 07 — Read Model Rebuild** | per-topic lag showing catalog draining before availability |

The experiment dashboards are for *watching* a run; each experiment's `runbook.sh` (or k6
`teardown()`) remains the authoritative pass/fail, because it reads Postgres ground truth.

> The Kafka dashboard's broker row (`kafka_server_*`, `kafka_controller_*`) needs the JMX
> ruleset applied in Runbook Step 4 (`strimzi/kafka-metrics-configmap.yaml`). Consumer lag
> comes from the kafka-exporter and works regardless. Panels that stay empty until traffic
> flows are expected — publish the catalog (Runbook Step 10) and they fill in.

It has golden-signal stats, rate/error/latency-by-endpoint timeseries, a top-failing-requests
table (`uri`/`status`/`exception`), a latency heatmap, and a pinned **Saga hot path** row for
booking/inventory/payment 5xx. The `$service` dropdown is driven by
`label_values(http_server_requests_seconds_count, job)` — if it's empty or shows the wrong
values, change `job` to `pod`/`container` in the variable query (the PodMonitor sets no explicit
`jobLabel`, so Prometheus defaults `job` to the PodMonitor name). You can also import
**'Spring Boot 3.x Statistics'** and **'JVM (Micrometer)'** (id 4701) for JVM internals.

**Layer B — span metrics + service graph from Tempo (trace-side).** Tempo's metrics-generator
derives RED metrics and the service graph from spans and remote-writes them to Prometheus:

- `tempo-values.yaml` → `metricsGenerator.enabled` + `remoteWriteUrl` + processors
  (`service-graphs`, `span-metrics`).
- `kube-prometheus-stack-values.yaml` → `enableRemoteWriteReceiver: true` (accept the write)
  and `enableFeatures: [exemplar-storage]` (histogram spike → trace link).
- `tempo-datasource.yaml` → `serviceMap` + `tracesToMetrics` wired to the `prometheus`
  datasource, so Grafana → Explore → **Tempo** shows the **Service Graph** tab.

Apply:
```bash
helm upgrade --install tempo grafana/tempo -n atlas-observability -f tempo-values.yaml
helm upgrade --install kps  prometheus-community/kube-prometheus-stack \
  -n atlas-observability -f kube-prometheus-stack-values.yaml
kubectl apply -f tempo-datasource.yaml
```
Verify the generator is producing series (both should be non-empty once traffic flows):
```promql
traces_spanmetrics_calls_total
traces_service_graph_request_total
```
> Processors go under `tempo.overrides.defaults.metrics_generator.processors` (the chart
> renders `tempo.overrides` verbatim into Tempo's `overrides:` config). Using `global_overrides`
> is silently ignored → generator runs with **no processors** → empty Service Graph. Tempo here
> is a **StatefulSet** (`sts/tempo`), not a Deployment. Confirm the rendered config with
> `kubectl -n atlas-observability get cm tempo -o jsonpath='{.data.tempo\.yaml}' | grep -A20 -i metrics_generator`.

For investigating the booking errors from experiment 01: filter `http_server_requests_*` by
`{job="booking-service", status=~"5.."}` to find which endpoint fails and at what RPS, then
open the Service Graph / a failing span in Tempo to see where in the Saga it breaks, and jump
to the correlated Loki logs by traceId.

## Notes
- Actuator/metrics live on port **9090** (management), so scrape traffic never pollutes
  the business `http.server.requests` metric (roadmap §1.1).
- Expose Grafana via the Ingress with a host + TLS when you want browser access without
  port-forward (Phase 5 pattern).
- Lean profile: Alertmanager off, 12h retention. Raise when needed.
