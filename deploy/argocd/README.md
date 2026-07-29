# GitOps for Atlas (Argo CD)

Deploy Atlas and watch the whole stack converge **wave by wave** in the Argo CD UI. Self-heals, surfaces errors visually, it deploys the manifests under [`deploy/platform/`](../platform) and the Helm chart under [`deploy/helm/atlas-service/`](../helm/atlas-service). GitOps just drives them declaratively.

---

## Quick start

1. Provision a cluster and point kubectl at it — pick your vendor (Oracle OKE, Civo, …).

#### Option A - Oracle
```bash
cd deploy/cluster/oracle/terraform   # from repo root
cp terraform.tfvars.example terraform.tfvars   # your OCIDs, region, ssh key
terraform init && terraform apply
```

#### Option B - Civo
```bash
cd deploy/cluster/civo/terraform      # from repo root
export CIVO_TOKEN="your-civo-api-key" #got to your civo Dashboard (Account → Security → API keys)
terraform init && terraform apply
./save-kubeconfig.sh
export KUBECONFIG=~/.kube/civo-atlas.yaml
```

After the cluster is ready, verify that all nodes are healthy:

```bash
kubectl get nodes                                      # expect 3 Ready nodes BEFORE step 2
```

All the steps below are vendor-agnostic:

```
# 2. Bootstrap (from the repo root). Vendor-agnostic — runs against whatever cluster your kubectl points at. No arguments needed.
# from repo root
./deploy/argocd/bootstrap.sh  

# 3. Open the Argo CD UI from the printed URL card and watch it go green.
#    While it converges, open Grafana, Kafka UI and a DB session — see
#    "Open everything" below. You want them ready BEFORE step 4.

# 4. Once the services are green, publish the catalog (two POSTs) and watch the
#    events flow through all of it. See "Publish the catalog" below.
```

Everything else — operators, Postgres/Kafka/Keycloak, the **complete `atlas` realm**, the 8
services, observability, KEDA — is created and reconciled by Argo CD. `bootstrap.sh` also
generates every per-cluster secret, sets the realm users' passwords, and seeds the k6 load-test
pool, so the cluster comes up ready for `experiments/`.

**What bootstrap gives you, and what it deliberately leaves out:**

| | |
|---|---|
| ✅ DB secrets, `atlas-issuer`, `atlas-realm-credentials`, Kafka UI basic-auth | generated per cluster, never in git |
| ✅ `atlas-user` / `atlas-admin` with working passwords | from `atlas-realm-credentials` |
| ✅ `loadtest-1…N` pool | `--loadtest-users N` (default 200, `0` skips) |
| ✅ public `nip.io` hostnames patched onto Argo CD, Keycloak, Kafka UI | the LB IP is only known at runtime |
| ❌ the **catalog is not published** | needs the services healthy first — two POSTs, see [Publish the catalog](#publish-the-catalog--and-watch-it-happen) |
| ❌ `temp-admin` is still Keycloak's bootstrap admin | replace and delete it — same section |

**Useful flags** (all optional):

```bash
./deploy/argocd/bootstrap.sh \
  --loadtest-users 50 \                 # smaller k6 pool (0 = skip seeding)
  --kafka-ui-user me --kafka-ui-pass s3cret
```

---

## Open everything (do this before publishing the catalog)

Set these up while Argo finishes converging. The point is to have the four views **already
open** when you publish the catalog, so you watch the events flow instead of reading about it
afterwards. `LB` is the IP printed on the bootstrap card.

```bash
LB=<the IP from the bootstrap card>
```

### Argo CD — the deployment itself

```
http://argocd.$LB.nip.io        admin / (printed on the card)
```

```bash
# lost the password?
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo
```

Wave by wave, tiles go yellow → green. Services (wave 7) show **red** until Postgres, Kafka and
Keycloak are ready above them — that is the ordering working, not a failure.

### Grafana — metrics, logs, traces

Run the following command to open a connection to the Kubernetes cluster and forward the Grafana service to your local machine on port `3000`. Keep this terminal window running while you use Grafana.

```bash
kubectl -n atlas-observability port-forward svc/kps-grafana 3000:80
#   http://localhost:3000     admin / atlas-admin
```

All four Atlas dashboards live in the **Atlas** folder and are provisioned by Argo (wave 4) —
you do not import anything:

| Dashboard | uid | What it is for |
|-----------|-----|----------------|
| Atlas — HTTP RED (per endpoint) | `atlas-red-http` | rate, errors, latency per service and endpoint. The one to keep open. |
| Atlas — Kafka / Event Backbone | `atlas-kafka` | topic throughput, consumer-group lag, DLQ backlog |
| Atlas — Experiment 02: Inventory Contention | `atlas-exp02-contention` | the no-oversell invariant |
| CloudNativePG | (upstream) | Postgres under write pressure |

Empty panels before you publish the catalog are expected — there is no traffic yet. If they
are *still* empty afterwards, check `kubectl -n atlas-data get podmonitor`.

### Kafka UI — the events themselves

Kafka UI is exposed through the NGINX Ingress with HTTP Basic Authentication.

Open:

```text
http://kafka.$LB.nip.io
```

- **Username:** `admin`
- **Password:** Printed during the bootstrap process.

> **Note:** If you don't know the load balancer IP, retrieve it with:

```bash
kubectl -n atlas-system get svc ingress-nginx-controller
```

Then replace `$LB` with the value of the **EXTERNAL-IP** field.

Open **Topics** and leave it there. Also worth a tab: **Consumer Groups**, where
`inventory-service` and `search-service` will show lag spike and drain.

### Databases — where the patterns are visible

Nine databases, one per service. Credentials were generated by bootstrap and live only in the
cluster:

```bash
SVC=search   # flight | hotel | inventory | search | booking | payment | travel-cart | user
kubectl -n atlas-data get secret ${SVC}-secret -o jsonpath='{.data.password}' | base64 -d ; echo

kubectl -n atlas-data port-forward svc/atlas-pg-rw 5432:5432    # -ro for the read replicas
```

Then connect with `psql`, DBeaver, pgAdmin — host `localhost`, port `5432`, database
`<svc>_db`, user `<svc>_user`. Before publishing, run this in `flight_db`:

```sql
SELECT status, count(*) FROM outbox GROUP BY status;   -- empty
SELECT count(*) FROM flight_projections;               -- in search_db: 0
```

Those two zeros are the "before" picture — you will watch both change in the next section.

What each database holds:

| Database | Owner role | What is interesting in it |
|----------|-----------|---------------------------|
| `flight_db` / `hotel_db` | `flight_user` / `hotel_user` | catalog + `outbox` |
| `inventory_db` | `inventory_user` | `reservations`, `inventory`, `outbox` |
| `search_db` | `search_user` | read model: `*_projections`, `consumed_events` |
| `booking_db` | `booking_user` | `bookings` (saga state), `booking_status_history` |
| `payment_db` | `payment_user` | payments + `outbox` |
| `travel_cart_db` / `user_db` | `travel_cart_user` / `user_user` | active carts / profiles |
| `keycloak_db` | `keycloak_user` | Keycloak's own storage — leave it alone |

Two queries worth knowing once you have made a booking. Saga state, where `correlation_id` is
the thread you can paste into Loki to get every service's log line for one booking:

```sql
-- booking_db
SELECT booking_id, status, saga_id, correlation_id, created_at, confirmed_at
FROM bookings ORDER BY created_at DESC LIMIT 5;

-- inventory_db — Experiment 02 is decided here; confirmed units must never exceed capacity
SELECT status, count(*) FROM reservations GROUP BY status;
```

> **Read, don't write.** You may read any database as an operator, but a *service* may only
> ever touch its own — that separation is a non-negotiable of the architecture. Editing by hand
> puts the read models and the saga out of step with the events that produced them, and the
> experiments then measure your edit instead of the system.

### Keycloak

```
http://keycloak.$LB.nip.io/admin      temp-admin / (printed on the card)
```

```bash
# realm user passwords
kubectl -n atlas-system get secret atlas-realm-credentials -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

`temp-admin` is a **bootstrap** account that Keycloak never removes — replace and delete it once
you are past the first run (how, at the end of the next section).

---

## Publish the catalog — and watch it happen

With those tabs open, this is the moment the system comes alive.

**Why it is needed.** Each service seeds its own catalog through Flyway migrations that ship
inside the image. Those migrations `INSERT` straight into `flight_db` / `hotel_db` — they
**bypass the outbox**, so no domain event was ever emitted. `inventory-service` and
`search-service` own no catalog: they learn about flights and hotels **only** from events. On a
fresh cluster the catalog exists in Postgres and is invisible to everything else, so
`/api/v1/search/flights` returns `[]` and no booking can be made.

The reconciliation endpoints close that gap. Each asks its repository for the rows that never
published a Created event and writes them to the outbox, which the relay ships to Kafka like
any other event — same path, no shortcut.

Wait until the `*-service` apps are green in Argo, then:

```bash
LB=<the IP from the bootstrap card>

# ADMIN token. Both endpoints are @PreAuthorize("hasRole('ADMIN')"), so atlas-user gets a 403.
# atlas-admin carries the ADMIN realm role; its password is in atlas-realm-credentials.
ADMIN_PW=$(kubectl -n atlas-system get secret atlas-realm-credentials \
             -o jsonpath='{.data.admin-password}' | base64 -d)
TOKEN=$(curl -s http://keycloak.$LB.nip.io/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password -d client_id=atlas-web \
  -d username=atlas-admin --data-urlencode "password=$ADMIN_PW" | jq -r .access_token)

# Publish. Both are POST with no body and answer "SUCCESS".
curl -s -X POST http://$LB/api/v1/flights/reconciliation -H "Authorization: Bearer $TOKEN"; echo
curl -s -X POST http://$LB/api/v1/hotels/reconciliation  -H "Authorization: Bearer $TOKEN"; echo
```

- `403` — the token belongs to `atlas-user`, not `atlas-admin`.
- `401` — the `atlas-issuer` Secret does not match Keycloak's public hostname. Compare
  `kubectl -n atlas-apps get secret atlas-issuer -o jsonpath='{.data.KEYCLOAK_ISSUER_URI}' | base64 -d`
  against `http://keycloak.$LB.nip.io/realms/atlas`.
- `invalid_grant` on the token call — the realm passwords were never applied. Re-run
  `LB=$LB ./deploy/platform/keycloak/set-realm-passwords.sh` (idempotent).

**Now watch, in this order.** Each step is one seam of the architecture:

1. **`flight_db` → `outbox`** — the rows you queried as empty now appear, then flip to
   published as the relay ships them. This is the transactional outbox: the event and the
   state change committed together, never a dual write.
   ```sql
   SELECT status, count(*) FROM outbox GROUP BY status;
   SELECT event_type, status, created_at, published_at FROM outbox ORDER BY created_at DESC LIMIT 10;
   ```
2. **Kafka UI → Topics** — message counts leave zero on the catalog topics.
3. **Kafka UI → Consumer Groups** — `inventory-service` and `search-service` lag spikes, then
   drains back to `0`. Lag that climbs and stays means a consumer is down; it is the same
   signal the load experiments watch and KEDA scales on.
4. **`search_db`** — the read model fills up, built entirely from events:
   ```sql
   SELECT count(*) FROM flight_projections;
   SELECT count(*) FROM hotel_projections;
   SELECT event_type, count(*) FROM consumed_events GROUP BY event_type;
   ```
   `consumed_events` is the idempotency ledger — the reason replaying a duplicate event
   changes nothing. Compare its count with what Kafka UI reports delivered.
5. **Grafana → Atlas — HTTP RED** — your two POSTs as traffic on `flight-service` and
   `hotel-service`, and the consumer-side work on `inventory-service` and `search-service`. A
   flat error rate is what you want.
6. **Grafana → Atlas — Kafka** — the same lag story as Kafka UI, in the shape you will read
   during load. And **CNPG** shows the write burst from the outbox inserts.
7. **Tempo** — pick a request in the RED latency panel and follow its exemplar into the trace.
   This is the tooling that later shows a booking saga threaded across six services.

Produced, transported, consumed, projected — the whole architecture, from two commands.

**Confirm and move on:**

```bash
curl -s "http://$LB/api/v1/search/flights" | jq 'length'   # was 0, now > 0
```

> Re-running the reconciliation is safe: it only picks up rows with no Created event, so a
> second call after a successful one publishes nothing.

### Two things to know about your identity setup

**`temp-admin` is a bootstrap account.** Keycloak creates it on first start, in the `master`
realm, only to get you in — and never removes it. Create your own admin (Keycloak admin console
→ `master` realm → Users → Add user → Role mapping → `admin`), verify you can log in as it,
then delete `temp-admin`.

**The realm users** are `atlas-user` (no roles, drives the booking flow), `atlas-admin` (the
`ADMIN` role, what you just used) and `loadtest-1…N` (the k6 pool). All three passwords:

```bash
kubectl -n atlas-system get secret atlas-realm-credentials \
  -o jsonpath='{.data.user-password}' | base64 -d ; echo      # or admin-password / loadtest-password
```

---

## Next: the experiments

The cluster is up, the catalog is live, and you know where to look. Load-test it, replay
duplicate events, kill a consumer mid-saga, and watch it scale, heal, and never oversell or
double-charge: **[`experiments/README.md`](../../experiments/README.md)**.

Credentials for k6 are read straight from the cluster — no `.env` editing:

```bash
cd experiments
export LB=<the IP from the bootstrap card>
eval "$(./scripts/cluster-credentials.sh)"
make run EXP=01-high-booking-concurrency
```

The load-test user pool was already seeded by `bootstrap.sh` (`--loadtest-users`, default 200).

---

## Folder map

| Path | What it is |
|------|-----------|
| `bootstrap.sh` | The one imperative script (secrets, WireMock CM, installs Argo CD, applies the root app, patches the LB host). Idempotent. |
| `root-app.yaml` | The **app-of-apps** root — a `directory` Application over `apps/` (recurse). Creates every child. |
| `apps/*.yaml` | The 24 child Applications / the services `ApplicationSet`, each with a `sync-wave`. |
| `projects/atlas-project.yaml` | The `atlas` AppProject — whitelists source repos, destinations, cluster kinds. |
| `install/argocd-values.yaml` | Helm values for Argo CD itself (ingress host, `server.insecure`, RBAC). |
| `install/argocd-cm-health.yaml` | Custom health for the CNPG `Cluster` / Strimzi `Kafka` / `Keycloak` CRs. |

**How it fits together:** `bootstrap.sh` installs Argo CD and applies `root-app.yaml`. The root app
watches `apps/`, so every `apps/*.yaml` becomes a child Application. Each child carries a
`argocd.argoproj.io/sync-wave`, and Argo only advances to wave *N+1* once wave *N* is **Synced +
Healthy** — reproducing the runbook's ordering. Custom health makes the stateful-CR waves wait for
real Postgres/Kafka/Keycloak readiness (not just "the object exists").

---

## Sync-wave layout

| Wave | Apps | Why here |
|------|------|----------|
| **0** | `namespaces`, `node-tuning` | Namespaces + inotify limits — everything else needs them. |
| **1** | `ingress-nginx`, `metrics-server` | ingress-nginx **provisions the LoadBalancer** (its IP drives Phase B); metrics-server backs the HPAs. |
| **2** | `cnpg-operator`, `strimzi-operator`, `keycloak-operator`, `kube-prometheus-stack`, `keda-operator` | Operators + their **CRDs** (CRD-before-CR). |
| **3** | `cnpg-cluster`, `kafka-cluster`, `redis`, `obs-loki`, `obs-tempo`, `obs-alloy` | The stateful CRs — gated on the operators, and held Progressing by custom health until Ready. |
| **4** | `cnpg-databases`, `kafka-topics`, `obs-config` | Depend on a **Ready** Postgres/Kafka; Grafana datasources + dashboards. |
| **5** | `keycloak` | Needs `keycloak_db` + `keycloak-db-secret` (wave 4). |
| **6** | `wiremock` | Fake payment provider; payment depends on it. |
| **7** | `atlas-services` (**ApplicationSet**) | The 8 services — one Application per `values/<svc>.yaml`. |
| **8** | `atlas-ingress`, `kafka-ui` | Edge routing + Kafka UI. |
| **9** | `keda-scaledobjects` | Autoscalers — target the service Deployments + KEDA CRDs. |

**Shared `syncPolicy`:** `automated{prune, selfHeal}` + `syncOptions: [CreateNamespace=true,
ServerSideApply=true, ApplyOutOfSyncOnly=true]`. `ServerSideApply` is **required** for the oversized
CRDs (Prometheus Operator, Keycloak, Strimzi) that exceed the client-side-apply annotation limit.

**Pinned versions.** Every Helm app sets `targetRevision` (chart version) and the Keycloak operator
is pinned to `26.0.5`, for reproducibility and so the CR `status.conditions` shapes don't drift out
from under the custom health checks. Bump them deliberately in the `apps/*.yaml`.

---

## What stays imperative (`bootstrap.sh`)

Four things can't live in git as-is, so they're the only imperative pieces (v1 decision):

1. **Per-service DB secrets** — random passwords, per-cluster (`create-db-secrets.sh`, reused as-is).
2. **`atlas-issuer` Secret** — the public Keycloak issuer URL; depends on the **runtime LB IP**.
3. **WireMock mappings ConfigMap** — built from `wiremock/mappings/`.
4. **Public nip.io hostnames** — the Keycloak CR / Keycloak & Kafka-UI ingresses / Argo UI carry a
   `<cluster-ip>` placeholder patched to the live LB IP. Each is covered by `ignoreDifferences` so
   self-heal keeps the per-cluster value instead of reverting to the committed placeholder.

`bootstrap.sh` runs in two phases but is **one command**: **Phase A** sets up secrets + Argo CD +
the root app; **Phase B** blocks until Argo has provisioned the LB IP and the host-bearing objects,
patches them, applies the `atlas-issuer` + `kafka-ui-basic-auth` secrets, optionally applies your
realm, and prints a URL card. Re-runnable end to end.

> **Follow-ups (more pure-GitOps), documented not done:** move the DB secrets to `sealed-secrets`
> or ESO (note: sealing pins passwords, losing the random-per-cluster property); move the LB-host
> patching into an in-cluster PreSync hook Job with a scoped ServiceAccount (keep exactly one owner
> of the LB-host value); pin `image.tag` per service (default is `:latest` → not reproducible) and
> add Argo Image Updater / a CI tag-bump for real continuous delivery.

---

## Watch it converge (UI walkthrough)

1. Open `http://argocd.<LB>.nip.io` (or `kubectl -n argocd port-forward svc/argocd-server 8080:443`).
   Log in as `admin` with the password from the URL card.
2. The `atlas-root` app fans out into the child apps. Tiles go **yellow (Progressing) → green
   (Healthy)** wave by wave: namespaces → ingress → operators → Postgres/Kafka/Keycloak →
   databases/topics → services → ingress/Kafka-UI → KEDA.
3. **Expected transient red:** the 8 services show `CreateContainerConfigError: secret
   "atlas-issuer" not found` until Phase B creates that Secret — the intended, visible convergence
   signal. They flip green on the next reconcile.
4. Click any resource → **Events** and **Logs** are in its drawer (no `kubectl` needed).

**Self-healing demo:** delete a service pod or a `KafkaTopic` — Argo + the operators restore it and
the tile flips OutOfSync → Synced with no human action. Then run
[`experiments/README.md`](../../experiments/README.md) and watch KEDA scale payment on Kafka lag,
live in Grafana.

---

## Errors → fixes

Each degraded resource shows its Events + Logs in the Argo drawer. Common cases:

| You see | Meaning | Go to |
|---------|---------|-------|
| Services red: `secret "atlas-issuer" not found` | Phase B hasn't run yet — **expected transient**. | Finish `bootstrap.sh` (or re-run it). |
| App stuck **Progressing** on a stateful CR | Missing/failing custom health, or the CR genuinely isn't Ready. | [TS-ARGO-03](../TROUBLESHOOTING.md#ts-argo-03--app-stuck-progressing-on-a-stateful-cr) |
| App **OutOfSync/Degraded** after a wave | Wave gating / sync error. | [TS-ARGO-01](../TROUBLESHOOTING.md#ts-argo-01--app-outofsync-or-degraded) |
| CR wave fails: `no matches for kind …` | CRD-before-CR ordering. | [TS-ARGO-02](../TROUBLESHOOTING.md#ts-argo-02--crd-before-cr-no-matches-for-kind) |
| Big CRD sync fails: annotation too long | Needs `ServerSideApply`. | [TS-ARGO-04](../TROUBLESHOOTING.md#ts-argo-04--oversized-crd-serversideapply) |
| Postgres `initdb` pod `Pending` | Unbound PVC / no default StorageClass. | [TS-PLATFORM-02](../TROUBLESHOOTING.md#ts-platform-02--postgres-initdb-pod-stuck-pending-unbound-pvc) |
| `kubectl top` / HPA: "Metrics API not available" | kubelet TLS on managed clusters. | [TS-PLATFORM-03](../TROUBLESHOOTING.md#ts-platform-03--metrics-server-metrics-api-not-available) |
| `permission denied` running `bootstrap.sh` | Not executable. | [TS-PLATFORM-01](../TROUBLESHOOTING.md#ts-platform-01--permission-denied-running-a-sh-script) |

---

## Verify (before a real cluster)

```bash
# Render the Argo CD chart with our values (no cluster needed):
helm template argocd argo/argo-cd --version <pinned> -f install/argocd-values.yaml >/dev/null

# Client-side validate the Argo objects:
kubectl apply --dry-run=client -f projects/ -f root-app.yaml -f apps/

# Lint the bootstrap:
bash -n bootstrap.sh && shellcheck bootstrap.sh
```

Then the real test: on a fresh Civo/OKE cluster, `terraform apply` → `./bootstrap.sh` → confirm the
Argo UI tree reaches **all green** with no manual `kubectl` beyond the bootstrap.
