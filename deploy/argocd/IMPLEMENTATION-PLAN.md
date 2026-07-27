# Argo CD (GitOps) for Atlas — Implementation Plan

## Context

Deploying the Atlas platform today is ~30 manual `kubectl`/`helm` commands driven by
`DEPLOYMENT-RUNBOOK.md`. It's tedious, error-prone, and users get lost mid-way (as happened
in this project's own dry-run). The goal: turn it into **2 commands + a web UI where the whole
stack converges wave-by-wave**, self-heals, and surfaces errors visually — a far more fluid
and didactic experience for a Kubernetes learning lab.

**Approach:** Argo CD with the **app-of-apps** pattern + **sync waves** manages the ~90%
declarative stack (operators, CRs, the 8 service Helm releases, observability, KEDA). The only
per-cluster imperative pieces — DB secrets (random passwords), `atlas-issuer` (depends on the
runtime LoadBalancer IP), the WireMock configmap, and the Keycloak realm — stay in a small
**`bootstrap.sh`** run once (v1 decision; SealedSecrets/ESO documented as a follow-up). The
manual runbook is **kept intact** as the "understand what each piece does" reference.

**Repo naming caveat (grounded):** the GitHub remote is `github.com/atlas-event-lab/hub`
(the local folder is `atlas/`, but the repo is `hub`). Every `Application.spec.source.repoURL`
must be `https://github.com/atlas-event-lab/hub.git` with `path: deploy/...`. If the GitHub repo
is later renamed to `atlas`, update the `repoURL`s. Existing manifests stay where they are —
Argo just references them.

**Nothing GitOps exists today** (verified: no Argo/Flux/Kustomize/Helmfile; `booking-secret.sealed.yaml`
is an empty placeholder). This is greenfield.

---

## New folder — `deploy/argocd/` (all files NEW)

```
deploy/argocd/
  README.md                     # GitOps guide: map, wave table, UI walkthrough, error->TS map, hub-naming note
  bootstrap.sh                  # single idempotent script (Phase A pre-root, Phase B after LB IP)
  install/
    argocd-values.yaml          # argo/argo-cd Helm values: server.ingress host, server.insecure, RBAC
    argocd-cm-health.yaml       # custom Lua health for CNPG Cluster / Strimzi Kafka / Keycloak
  projects/
    atlas-project.yaml          # AppProject 'atlas': allowed repos, destinations, cluster CRDs
  root-app.yaml                 # app-of-apps root -> path deploy/argocd/apps (directory, recurse)
  apps/                         # child Applications, each with argocd.argoproj.io/sync-wave
    00-namespaces.yaml  05-node-tuning.yaml
    10-ingress-nginx.yaml  15-metrics-server.yaml
    20-cnpg-operator.yaml  20-strimzi-operator.yaml  20-keycloak-operator.yaml
    20-kube-prometheus-stack.yaml  20-keda-operator.yaml
    30-cnpg-cluster.yaml  30-kafka-cluster.yaml  30-redis.yaml
    30-obs-loki.yaml  30-obs-tempo.yaml  30-obs-alloy.yaml
    40-cnpg-databases.yaml  40-kafka-topics.yaml  40-obs-config.yaml
    50-keycloak.yaml  60-wiremock.yaml
    70-atlas-services.yaml      # ApplicationSet over deploy/helm/atlas-service/values/*.yaml
    80-atlas-ingress.yaml  80-kafka-ui.yaml  90-keda-scaledobjects.yaml
```

Design choices:
- `root-app.yaml` uses a `directory` source (`recurse: true`) over `apps/` → children auto-discovered.
- Child apps are thin: `source` + `destination` + `sync-wave` + shared `syncPolicy`.
- Directory apps that share a platform folder use `source.directory.include` globs to pick files.
- Helm apps that need a git values file use **Argo multi-source** (`ref: values` + `valueFiles: [$values/deploy/platform/.../values.yaml]`).
- The **8 services = one `ApplicationSet`** (git generator over `deploy/helm/atlas-service/values/*.yaml`), templating `name: <svc>-service`, chart `deploy/helm/atlas-service`, `sync-wave: "7"`. Mirrors the existing runbook loop exactly — reuses the chart + per-service values unchanged.

---

## Sync-wave layout (the dependency chain, enforced)

Argo advances to wave N+1 only when wave N is **Synced + Healthy**. Custom health (below) makes
the stateful-CR waves wait for `Cluster`/`Kafka`/`Keycloak` readiness — reproducing the runbook order.

| # | Component | App file | Source | Target ns | Wave |
|---|-----------|----------|--------|-----------|------|
| 1 | Namespaces | 00-namespaces | dir `platform/00-namespaces.yaml` | cluster | 0 |
| 2 | node-tuning (inotify) | 05-node-tuning | dir `platform/node-tuning/` | kube-system | 0 |
| 3 | ingress-nginx (**provisions LB**) | 10-ingress-nginx | helm `ingress-nginx` + values | atlas-system | 1 |
| 4 | metrics-server (`--kubelet-insecure-tls`) | 15-metrics-server | helm `metrics-server` | kube-system | 1 |
| 5 | CNPG operator | 20-cnpg-operator | helm `cnpg/cloudnative-pg` | cnpg-system | 2 |
| 6 | Strimzi operator | 20-strimzi-operator | helm `strimzi/strimzi-kafka-operator` | atlas-data | 2 |
| 7 | Keycloak operator (CRDs+op, pin **26.0.5**) | 20-keycloak-operator | dir git `keycloak-k8s-resources`@26.0.5 | atlas-system | 2 |
| 8 | kube-prometheus-stack (Prom CRDs+Grafana) | 20-kube-prometheus-stack | helm `kube-prometheus-stack` + values | atlas-observability | 2 |
| 9 | KEDA operator | 20-keda-operator | helm `kedacore/keda` | keda | 2 |
| 10 | CNPG Cluster `atlas-pg` | 30-cnpg-cluster | dir `cloudnative-pg/` incl `cluster.yaml` | atlas-data | 3 |
| 11 | Kafka `atlas` + NodePool + metrics cm | 30-kafka-cluster | dir `strimzi/` incl `kafka.yaml`,`kafka-metrics-configmap.yaml` | atlas-data | 3 |
| 12 | Redis | 30-redis | dir `redis/redis.yaml` | atlas-data | 3 |
| 13-15 | Loki / Tempo / Alloy | 30-obs-* | helm `grafana/*` + values | atlas-observability | 3 |
| 16 | 9 Database CRs | 40-cnpg-databases | dir `cloudnative-pg/` incl `databases.yaml` | atlas-data | 4 |
| 17 | 24 KafkaTopics + exporter podmonitor | 40-kafka-topics | dir `strimzi/` incl `topics.yaml`,`kafka-exporter-podmonitor.yaml` | atlas-data | 4 |
| 18 | Grafana datasources + dashboards | 40-obs-config | dir `observability/` incl `*-datasource.yaml`,`*-dashboard.yaml` | atlas-observability | 4 |
| 19 | Keycloak CR + ingress + realm | 50-keycloak | dir `keycloak/` incl `keycloak.yaml`,`keycloak-ingress.yaml`,`realm-import.yaml` | atlas-system | 5 |
| 20 | WireMock fake payment | 60-wiremock | dir `apps/wiremock.yaml` | atlas-apps | 6 |
| 21 | **8 Atlas services** | 70-atlas-services | **ApplicationSet** over `values/*.yaml` | atlas-apps | 7 |
| 22 | Edge routing (atlas-api) | 80-atlas-ingress | dir `apps/atlas-ingress.yaml` | atlas-apps | 8 |
| 23 | Kafka UI + ingress | 80-kafka-ui | dir `kafka/` incl `kafka-ui.yaml`,`kafka-ui-ingress.yaml` | atlas-data | 8 |
| 24 | KEDA ScaledObjects (payment, wiremock) | 90-keda-scaledobjects | dir `keda/` incl `*-scaledobject.yaml` | atlas-apps | 9 |

**Notes:** CRD-before-CR is enforced by operator wave 2 → CR wave 3 → dependents wave 4. Keycloak
(5) is after databases (4) — needs `keycloak_db` + `keycloak-db-secret`. Services (7) show **red**
(`CreateContainerConfigError: secret "atlas-issuer" not found`) until `bootstrap.sh` Phase B creates
it — the intended, visible convergence signal; they flip green on the next reconcile. The realm
import is applied by the bootstrap (see below), not a wave. `cnpg-system`/`keda` namespaces come from
`CreateNamespace=true`.

**Shared `syncPolicy`:** `automated{prune, selfHeal}`, `syncOptions: [CreateNamespace=true,
ServerSideApply=true, ApplyOutOfSyncOnly=true]`. `ServerSideApply` is **required** for the oversized
CRDs (Prometheus Operator, Keycloak, Strimzi). Set `targetRevision` on every Helm app (replaces the
runbook's `helm repo update` = latest) for reproducibility.

**Custom health (`install/argocd-cm-health.yaml`), ~10 lines each:**
- `postgresql.cnpg.io/Cluster` → Ready on `status.conditions[type=Ready]==True`
- `kafka.strimzi.io/Kafka` → same
- `k8s.keycloak.org/Keycloak` → Ready on `status.conditions`

**`projects/atlas-project.yaml` (AppProject `atlas`)** whitelists source repos (this repo + the
remote Helm repos + the keycloak/metrics-server git), destinations (all `atlas-*`, `cnpg-system`,
`keda`, `kube-system`, `argocd`), and cluster-scoped kinds.

---

## `bootstrap.sh` — the one imperative piece (v1, idempotent, run once)

Blocks on the LB IP between phases so the user still runs **one command**.

**Phase A (before the root app):**
1. Preflight: `kubectl` reachable, a `(default)` StorageClass exists.
2. `kubectl apply -f deploy/platform/00-namespaces.yaml` (so secrets have a home).
3. `./deploy/platform/cloudnative-pg/create-db-secrets.sh` — **reuse as-is**: the 9 basic-auth
   secrets, random passwords, replicated across `atlas-data`+`atlas-apps` (keycloak into `atlas-system`).
3b. `atlas-realm-credentials` in `atlas-system` — three random passwords (`user-password`,
   `admin-password`, `loadtest-password`) applied to the realm users in Phase B. The realm
   manifest ships them **without** credentials so nothing sensitive is committed.
4. `kubectl create configmap wiremock-mappings -n atlas-apps --from-file=wiremock/mappings/ --dry-run=client -o yaml | kubectl apply -f -`.
5. *(nothing to do — the complete `atlas` realm is in the repo and Argo applies it in wave 5;
   `--realm` only overrides it with a user's own export.)*
6. Install Argo CD via the `argo/argo-cd` Helm chart with `install/argocd-values.yaml`; apply
   `install/argocd-cm-health.yaml`; wait for `deploy/argocd-server`.
7. Apply `projects/atlas-project.yaml`, then **`root-app.yaml`** → Argo drives waves 0..9.

**Phase B (LB-IP-dependent; poll until it exists):**
8. Poll `svc/ingress-nginx-controller` for `status.loadBalancer.ingress[0].ip` → `$LB`.
9. `kubectl create secret generic atlas-issuer -n atlas-apps --from-literal=KEYCLOAK_ISSUER_URI="http://keycloak.$LB.nip.io/realms/atlas"` (apply-style, re-runnable).
10. Patch `$LB` into the live objects that carry a `<cluster-ip>` placeholder — Keycloak CR
    `spec.hostname.hostname`, `keycloak-ingress`, `kafka-ui-ingress`, Argo UI host — each covered by
    `ignoreDifferences` in its Application so self-heal won't revert the per-cluster value.
11. Print a URL card (Argo UI, Grafana, Kafka UI, Keycloak) + the Argo `admin` password.

> Follow-up (more pure-GitOps): move steps 8–10 into an in-cluster **PreSync hook Job** with a scoped
> ServiceAccount, dropping them from the script. Keep exactly one owner of the LB-host patch.

---

## User-facing flow

1. **Cluster:** `cd deploy/cluster/civo/terraform && terraform apply`; export the kubeconfig.
2. **Bootstrap:** `./deploy/argocd/bootstrap.sh` (prints the URL card).
3. **Watch it converge:** open `https://argocd.<LB>.nip.io` (`admin` + printed password). The tree
   fills wave by wave — namespaces → ingress → operators → Postgres/Kafka/Keycloak → databases/topics
   → services → ingress/kafka-ui → KEDA — each tile yellow (Progressing) → green (Healthy). Fallback:
   `kubectl -n argocd port-forward svc/argocd-server 8080:443`.
4. **Evidence layer:** Grafana (`svc/kps-grafana`, `admin`/`atlas-admin`) for RED/Kafka/CNPG dashboards
   + Tempo traces; Kafka UI at `https://kafka.<LB>.nip.io`.
5. **Self-healing demo + experiments:** delete a service pod / KafkaTopic → Argo + operators restore
   it; then run `experiments/README.md` and watch KEDA scale payment on Kafka lag, live in Grafana.

**Errors → `deploy/TROUBLESHOOTING.md`:** each degraded resource shows Events + Logs in its Argo
drawer. The new `deploy/argocd/README.md` ships an error map: `atlas-issuer not found` → Phase B not
done yet (expected transient); CNPG initdb `Pending` → **TS-PLATFORM-02**; `Metrics API not available`
→ **TS-PLATFORM-03**; App stuck Progressing on a stateful CR → missing/failing custom health; a `.sh`
`permission denied` → **TS-PLATFORM-01**.

---

## Documentation changes

- **NEW `deploy/argocd/README.md`** — the GitOps guide (map, wave table, bootstrap explanation, UI
  walkthrough, error→TS map, `hub`-vs-`atlas` naming note).
- **`DEPLOYMENT-RUNBOOK.md`** — add a top banner: *"Two ways to deploy: (A) GitOps — 2 commands,
  self-healing, watchable (`deploy/argocd/README.md`); (B) this manual runbook — the didactic path."*
  Keep the runbook intact; its Steps 1–8 map 1:1 to the Argo waves.
- **`deploy/README.md`** — add `argocd/` to the directory map + the "path for a new user".
- **`deploy/TROUBLESHOOTING.md`** — add a `TS-ARGO-0x` section (OutOfSync/Degraded, CRD-before-CR wave
  gating, missing health check, `atlas-issuer` red services, ServerSideApply for oversized CRDs).
- **`CHANGELOG.md`** — note the GitOps addition.

---

## Risks / decisions

1. **Secrets = `bootstrap.sh` (decided, v1).** DB secrets + `atlas-issuer` stay imperative. Follow-up:
   add a `sealed-secrets` controller (wave-2 app) + seal them — note sealing pins passwords (loses the
   random-per-cluster property); `atlas-issuer` still needs LB-host templating.
2. **LB-host templating:** bootstrap-patch + `ignoreDifferences` (v1) vs in-cluster hook Job (follow-up).
3. **Custom-CR health:** waves only gate if Argo has health for CNPG/Strimzi/Keycloak — pin operator
   versions so `status.conditions` shapes don't drift.
4. **`:latest` reproducibility:** `image.tag: ""` → appVersion `latest`, `pullPolicy: Always`. Argo shows
   Synced despite drift and won't redeploy on a new push (manifest unchanged). Pin `image.tag` per service
   for reproducible runs; add Argo Image Updater / CI tag-bump for real CD later.
5. **Pin versions:** `targetRevision` on every Helm app; `26.0.5` for keycloak-k8s-resources.
6. **Repo named `hub`:** all `repoURL` = `.../hub.git` (or rename the GitHub repo to `atlas`).
7. **Oversized CRDs → `ServerSideApply=true`** (Prometheus Operator, Keycloak, Strimzi).
8. **Resource pressure:** waves bring the stack up fast; on a small node Tempo (+256–512Mi) and 3-broker
   Kafka can thrash — size per `deploy/cluster/README.md`.

---

## Verification (end to end, after implementation)

1. **Dry-render the Argo config** without a cluster: `helm template` the argo-cd chart with
   `install/argocd-values.yaml`; `kubectl apply --dry-run=client -f` the `apps/*.yaml`, `root-app.yaml`,
   `projects/`, and `install/` manifests; `argocd app manifests` / `argocd-util` lint if available.
   `bash -n deploy/argocd/bootstrap.sh` + `shellcheck`.
2. **On a fresh Civo cluster (the real test):** `terraform apply` → `./deploy/argocd/bootstrap.sh` →
   confirm the Argo UI tree reaches **all green** with no manual `kubectl` beyond the bootstrap.
   Check waves fired in order (`argocd app list`, sync-wave timestamps).
3. **Functional gate (same as the runbook's):** `curl http://<LB>/api/v1/flights` returns; a full saga
   booking reaches `CONFIRMED`; Grafana shows the RED dashboard populating; Kafka UI lists 24 topics.
4. **Self-heal gate:** `kubectl delete pod <a-service>` and `kubectl delete kafkatopic <one>` → both are
   restored automatically; Argo tiles flip OutOfSync→Synced without human action.
5. **Error-path gate:** temporarily skip Phase B (no `atlas-issuer`) → confirm the services show the
   expected red state in the UI and that `deploy/argocd/README.md`'s error map points to it. Restore.