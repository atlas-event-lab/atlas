# Observability — Phase 6

Chosen stack (roadmap §0, §Phase 6): Grafana LGTM, added incrementally.
- **6a — Metrics:** Prometheus + Grafana scraping `/actuator/prometheus`.
- **6b — Logs:** Loki (single-binary) + Grafana Alloy DaemonSet. No app changes.
- **6c — Traces:** Tempo + Micrometer Tracing (OTLP). App changes: tracing deps + Kafka observation.

Namespace: `atlas-observability`.

## Prerequisite — metrics-server (for the HPA)
The HPA needs the resource-metrics API (separate from Prometheus). If `kubectl top pods`
fails with "Metrics API not available":
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# On some OKE setups the kubelet cert isn't trusted; if metrics-server crashloops, add:
#   kubectl -n kube-system patch deploy metrics-server --type=json \
#     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top pods -n atlas-apps
```

## Step 1 — Install kube-prometheus-stack
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n atlas-observability --create-namespace -f kube-prometheus-stack-values.yaml
kubectl -n atlas-observability rollout status deploy/kps-grafana
```
This installs the **Prometheus Operator CRDs** (PodMonitor, ServiceMonitor, …) needed by
the chart's PodMonitor.

## Step 2 — Turn on app scraping
The app images already expose `/actuator/prometheus` (Micrometer). Enable the PodMonitor
per service by setting `metrics.enabled=true` — flip it in the chart default (`values.yaml`)
so the next CI deploy includes it, or one-off:
```bash
# from atlas-gitops/charts/atlas-service (or a local copy)
for s in user flight hotel inventory travel-cart booking payment search; do
  helm upgrade --install $s-service . -f values/$s.yaml -n atlas-apps \
    --reuse-values --set metrics.enabled=true
done
kubectl get podmonitor -n atlas-apps           # 8 PodMonitors
```

## Step 3 — Verify + explore
```bash
# Prometheus: confirm the app targets are UP
kubectl -n atlas-observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
#   open http://localhost:9090/targets  -> podMonitor/atlas-apps/* should be UP

# Grafana (admin / atlas-admin)
kubectl -n atlas-observability port-forward svc/kps-grafana 3000:80
#   open http://localhost:3000  -> add a dashboard, e.g. import 'JVM (Micrometer)' id 4701,
#   and 'Spring Boot 3.x Statistics' for http.server.requests.
```

## 6b — Logs (Loki + Alloy)
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

## 6c — Traces (Tempo + Micrometer)
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

## 6d — APM (RED per endpoint + service graph) — Phase 7

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
