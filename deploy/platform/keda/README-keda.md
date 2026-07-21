# KEDA — lag-based autoscaling for payment-service

Part of Phase 7 / Experiment 01. Rationale and design:
[`experiments/01-high-booking-concurrency/payment-service-scaling.md`](../../../experiments/01-high-booking-concurrency/payment-service-scaling.md) §3.1.

`payment-service` is I/O-bound, so the CPU HPA barely triggers while the `inventory.reserved`
consumer lag grows. KEDA scales the Deployment on lag instead, using its native Kafka scaler
(reads lag directly from the broker — no Prometheus dependency).

## 1. Install KEDA (once)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda -n keda --create-namespace
```

Verify the operator and metrics-adapter are Running:

```bash
kubectl -n keda get pods
```

## 2. Make sure the chart side is deployed first

The payment values already set `autoscaling.enabled: false` (drops the CPU HPA) and
`keda.enabled: true` (the Deployment omits `replicas`, so GitOps/ArgoCD won't fight KEDA's HPA):

```bash
helm upgrade --install payment-service atlas-gitops/charts/atlas-service \
  -f atlas-gitops/charts/atlas-service/values/payment.yaml -n atlas-apps \
  --set image.tag=<current-live-tag>
```

## 3. Apply the ScaledObject

```bash
kubectl apply -f deploy/platform/keda/payment-scaledobject.yaml
```

## 4. Verify

```bash
kubectl -n atlas-apps get scaledobject payment-service          # READY=True, ACTIVE reflects lag
kubectl -n atlas-apps get hpa keda-hpa-payment-service          # TARGETS shows lag, not <unknown>
kubectl -n atlas-apps get deploy payment-service -w             # replicas 1 -> up to 3 under lag
```

`ACTIVE=False` with lag below `activationLagThreshold` (10) is normal — it means payment sits at
`minReplicaCount` (1) when there's nothing to do.

## Tuning

- `lagThreshold` (per-replica target lag): start `50`; with `concurrency: 2` per pod it can go
  toward `~100`. Lower = scales out sooner.
- `maxReplicaCount` (4) is tied to `inventory.reserved` having 12 partitions (ADR-0016) and
  `KAFKA_CONCURRENCY=3` (4 × 3 = 12 consumers, ADR-0015). If partitions change, revisit both.

## Rollback

```bash
kubectl -n atlas-apps delete -f deploy/platform/keda/payment-scaledobject.yaml
```

Then set `autoscaling.enabled: true` and `keda.enabled: false` in `values/payment.yaml` and
redeploy to restore the CPU HPA.
