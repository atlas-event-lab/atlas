# atlas-service Helm chart

One reusable chart for every Atlas stateless Spring Boot microservice. You deploy
**one release per service**, passing a thin per-service values file. Implements
`DEP-001`/`DEP-002` and the port/probe conventions in `docs/deployment/deployment-roadmap.md`
(§1.1: 8080 business API, 9090 actuator; probes use Spring Boot health groups).

## What it renders
- `Deployment` — non-root securityContext, `http`(8080) + `management`(9090) ports,
  startup/liveness/readiness probes on 9090, `envFrom` ConfigMap + Secret, resources,
  optional pod anti-affinity.
- `Service` (ClusterIP, port 8080) — routed externally by the NGINX Ingress in Phase 5.
- `HorizontalPodAutoscaler` — when `autoscaling.enabled`.
- `ConfigMap` — non-secret config (`config`). `replicas` is omitted when the HPA owns it.
- `ServiceAccount`.

## Usage
```bash
# lint + render (run locally — these are the real validation gates)
helm lint . -f values/booking.yaml
helm template booking-service . -f values/booking.yaml -n atlas-apps

# deploy
helm upgrade --install booking-service . -f values/booking.yaml -n atlas-apps
```

## Per-service values
Each service overrides only what differs: `image.repository`, `autoscaling`,
`podAntiAffinity`, `config` (in-cluster DNS for Kafka/Keycloak/Postgres + sibling
services), and the `envSecret.name` holding `DB_USERNAME`/`DB_PASSWORD`. See
`values/booking.yaml` (Saga HA) and `values/search.yaml` (CQRS read side) as templates;
the remaining services follow the same shape.

## Notes
- Secrets are **not** created here — they come from a `SealedSecret`/External Secret
  (roadmap §7, §8b). The chart only references the Secret by name via `envFrom`.
- These example values live in the chart for validation; in the GitOps model they move
  to `atlas-gitops` (roadmap §2).
- `metrics.enabled` stays off until Phase 6 adds the Prometheus actuator endpoint.
