# Atlas — Deployment Runbook (Kubernetes, vendor-agnostic)

How to take Atlas from zero to a running, scalable, observable stack on **any** conformant
Kubernetes cluster. This runbook generalizes the original Oracle-OKE-specific runbook to the
portability principle: everything stateful runs in-cluster.

> **Portability thesis.** All stateful infrastructure (Postgres, Kafka, Keycloak) runs
> **inside the cluster** via operators. The only vendor-specific surfaces are (1) the
> **node pool** and (2) the **LoadBalancer** that fronts Ingress. Moving vendor = recreate
> those two and re-apply the manifests.

> **Where everything lives.** All manifests and scripts are under [`deploy/`](./deploy) —
> see [`deploy/README.md`](./deploy/README.md) for the map. In short: `deploy/cluster/`
> (provision a cluster), `deploy/platform/` (operators, CRs, observability, KEDA),
> `deploy/helm/atlas-service/` (the library chart + per-service values), `deploy/ops/`
> (cost/lifecycle scripts), and [`deploy/TROUBLESHOOTING.md`](./deploy/TROUBLESHOOTING.md)
> (errors & fixes). **Run every command below from the repo root** (the `atlas/` folder) —
> the paths are relative to it.

---

## 0. Get a cluster + prerequisites

**No cluster yet?** Provision one first — turnkey Terraform for **Oracle OKE** or **Civo**,
with reference sizing, is in **[`deploy/cluster/README.md`](./deploy/cluster/README.md)**.
Already have a cluster with `kubectl` pointing at it? Skip to the checks below.

| Tool / input | Used for | What you need to do |
|--------------|----------|---------------------|
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | applying manifests | Install it; its context must point at your cluster (Step 0 provisioning sets this up). |
| [`helm`](https://helm.sh/docs/intro/install/) 3.x | operators & charts | Install it. |
| A block-storage `StorageClass` | Postgres/Kafka PVCs | **Nothing** — the manifests leave it unset, so they use your cluster's **default** StorageClass (works on any cloud). Confirm one is marked `(default)` with `kubectl get storageclass`. |
| Container images | the 9 services | **Nothing** — they're **public** on GHCR (`ghcr.io/atlas-event-lab/atlas-<service>`), published by each service repo's CI. Kubernetes pulls them anonymously; no login or pull-secret needed. |

> **Stuck on an error?** Known issues and fixes (provisioning, platform *and* the services)
> live in [`deploy/TROUBLESHOOTING.md`](./deploy/TROUBLESHOOTING.md). Check there before
> assuming something is broken — several normal-but-alarming states are documented, notably
> slow first image pulls and startup-probe warnings during JVM boot.
>
> **A `kubectl wait … --timeout` hitting its limit is not a failure.** On a fresh cluster the
> first image pulls and volume provisioning are slow, so a `wait` can expire while the
> resource is still coming up. If it does, don't stop — check `kubectl get <resource>` and
> `kubectl get pods -n <namespace>`; once it reports `Ready`, continue (or just re-run the
> same `wait`). Treat it as a real problem only if pods are stuck `Pending` /
> `CrashLoopBackOff` / `Error` — then see the troubleshooting guide.

```bash
kubectl config current-context      # confirm you are on the right cluster
kubectl get storageclass            # note the StorageClass name (you will need it)
kubectl get nodes                   # node pool ready
```

### Node health — run this now, and again whenever something is inexplicably stuck

Almost everything in this runbook lands on a node and mounts a volume, so a single unhealthy
node produces failures that look like *your* misconfiguration: pods that never leave
`ContainerCreating`, volumes that never mount, JVMs killed mid-startup. Establishing that the
nodes are clean **before** you start turns hours of misdiagnosis into one command.

```bash
# 1. No node should report a *Pressure or an unreachable condition as True.
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status',\
DISK:'.status.conditions[?(@.type=="DiskPressure")].status',\
MEM:'.status.conditions[?(@.type=="MemoryPressure")].status',\
PID:'.status.conditions[?(@.type=="PIDPressure")].status'

# 2. The CSI driver must be registered and STABLE on every node. Restarts here are the
#    single best early warning: a flapping CSI node plugin breaks every PVC on that node.
kubectl -n kube-system get pods -o wide | grep -i csi

# 3. Nothing should be restarting across the cluster.
kubectl get pods -A --sort-by=.status.containerStatuses[0].restartCount \
  | awk 'NR==1 || $5+0 > 3'
```

Expect `READY=True` and `False` for all three pressures, CSI pods `Running` with **0
restarts**, and an empty list from the third command.

> **A node that fails this is not a puzzle to solve — it is a node to replace.** Cloud
> instances degrade; it is not caused by anything in this repo and it is not worth debugging
> component by component. If one node accumulates failures across unrelated workloads (CSI,
> observability agents, a database replica, a broker), replace it:
> `civo kubernetes recycle <cluster> --node=<node>` and see
> [TS-PLATFORM-06](./deploy/TROUBLESHOOTING.md#ts-platform-06--stateful-pod-stuck-containercreating-with-a-bound-pvc).
> A low `kubectl top` reading on such a node is **not** reassurance — it is idle because
> nothing can start on it.

**The two vendor-specific surfaces — and whether you act on them:**

1. **StorageClass** — ✅ *automatic.* The Postgres, Kafka and observability manifests leave
   `storageClass` unset, so Kubernetes uses your cluster's **default** class (`civo-volume`
   on Civo, `oci-bv` on OKE, `standard-rwo` on GKE, `gp3` on EKS, `local-path` on kind/k3d).
   Confirm one is marked `(default)` via `kubectl get storageclass`. Want a *specific* class?
   Uncomment `storageClass` in `cloudnative-pg/cluster.yaml` and `strimzi/kafka.yaml`.
2. **LoadBalancer** — ✅ *automatic.* You don't provision one. Installing ingress-nginx
   (Step 2) creates a `Service type=LoadBalancer`, and the managed cloud assigns it an
   `EXTERNAL-IP` on its own. (Local kind/k3d is the exception — see Step 2.)
3. **Stable public IP / hostname** — 🟡 *optional, skip on a first run.* The auto-assigned
   LB IP works out of the box (Keycloak uses it via `nip.io`). Reserve a **static** IP only
   if you'll destroy/recreate the cluster and want the Keycloak `issuer` to stay valid
   across rebuilds (a changed issuer breaks JWT validation across all services).

---

## 1. Namespaces

```bash
kubectl apply -f deploy/platform/00-namespaces.yaml
kubectl get ns atlas-system atlas-data atlas-apps atlas-observability
```

`atlas-system` (ingress, Keycloak) · `atlas-data` (Postgres, Kafka) · `atlas-apps` (the
services + simulated payment provider) · `atlas-observability` (Grafana stack, Step 7).

## 2. Ingress (single entry point)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n atlas-system -f deploy/platform/ingress-nginx/values.yaml
kubectl get svc -n atlas-system ingress-nginx-controller -w   # wait for EXTERNAL-IP, then Ctrl-C

# Capture it — Steps 5, 6, 7 and the smoke test all need it. Keep this shell, or re-run
# this line in any new one. Every later `LB=<EXTERNAL-IP>` in this runbook means this value.
LB=$(kubectl get svc -n atlas-system ingress-nginx-controller \
       -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$LB"
```

> **On a managed cloud (OKE / Civo / GKE / EKS):** no action — just wait ~1–2 min for the
> `EXTERNAL-IP` to appear (that's the cloud LoadBalancer being provisioned). This IP is the
> single most reused value in this runbook: Keycloak's hostname and Ingress (Step 5), the
> `atlas-issuer` Secret (Step 6), the Kafka UI Ingress (Step 7) and the smoke test all
> derive from it. If it ever changes, all four must be redone — see
> [TS-APPS-04](./deploy/TROUBLESHOOTING.md#ts-apps-04--401-on-every-authenticated-call).
>
> **Only on local kind/k3d:** there is no cloud LB, so no `EXTERNAL-IP` — enable the
> kind/k3d ingress add-on or install MetalLB before continuing.

## 3. Postgres (CloudNativePG operator)

```bash
# 3a. operator
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl rollout status deploy/cnpg-cloudnative-pg -n cnpg-system

# 3b. per-service DB secrets (BEFORE creating the cluster)
# `permission denied` here (or on any other .sh in this runbook) is TROUBLESHOOTING
# TS-PLATFORM-01 — git did not preserve the executable bit.
./deploy/platform/cloudnative-pg/create-db-secrets.sh
kubectl get secret -n atlas-data          # expect the per-service *-secret entries

# 3c. cluster + databases  (uses the cluster's default StorageClass)
kubectl apply -f deploy/platform/cloudnative-pg/cluster.yaml
kubectl wait --for=condition=Ready cluster/atlas-pg -n atlas-data --timeout=600s
kubectl apply -f deploy/platform/cloudnative-pg/databases.yaml
kubectl get database -n atlas-data
```

> **Stuck here?** An `initdb` pod `Pending` on an unbound PVC is
> [TS-PLATFORM-02](./deploy/TROUBLESHOOTING.md#ts-platform-02--postgres-initdb-pod-stuck-pending-unbound-pvc).
> A pod stuck in `Init`/`ContainerCreating` while its PVC already reads `Bound` is a
> different failure —
> [TS-PLATFORM-06](./deploy/TROUBLESHOOTING.md#ts-platform-06--stateful-pod-stuck-containercreating-with-a-bound-pvc).

Connection string (already in the Helm values): `atlas-pg-rw.atlas-data:5432/<db>`
(`-rw` primary; `-ro` read replicas).

## 4. Kafka (Strimzi, KRaft — no ZooKeeper)

```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n atlas-data
kubectl rollout status deploy/strimzi-cluster-operator -n atlas-data

# The JMX->Prometheus ruleset MUST exist BEFORE the Kafka CR: kafka.yaml references it via
# spec.kafka.metricsConfig, and Strimzi fails the WHOLE reconciliation if it is missing —
# it creates the Services and PVCs but never the brokers. See TROUBLESHOOTING TS-PLATFORM-07.
kubectl apply -f deploy/platform/strimzi/kafka-metrics-configmap.yaml

kubectl apply -f deploy/platform/strimzi/kafka.yaml   # uses the default StorageClass
kubectl wait --for=condition=Ready kafka/atlas -n atlas-data --timeout=600s
kubectl apply -f deploy/platform/strimzi/topics.yaml
kubectl get kafkatopic -n atlas-data

# Gate: brokers must actually exist. `kafka/atlas` reporting nothing at all (empty READY and
# VERSION columns) means the operator never reconciled — read its status, not just the pods:
kubectl -n atlas-data get pods -l strimzi.io/cluster=atlas
kubectl -n atlas-data get endpoints atlas-kafka-bootstrap    # must NOT be <none>
```

> **`endpoints` empty is the failure that matters.** Every service then logs
> `Disconnecting from node -1 due to socket connection setup timeout` against
> `atlas-kafka-bootstrap.atlas-data:9092`, which reads like a network problem and is not —
> there is simply no broker behind the Service. Diagnose it from the Kafka CR's conditions:
> `kubectl -n atlas-data describe kafka atlas | sed -n '/Status:/,$p'`. See
> [TS-PLATFORM-07](./deploy/TROUBLESHOOTING.md#ts-platform-07--kafka-has-no-broker-pods-and-no-status).

Baseline is 1 broker (RF=1). For replication/DLQ experiments, scale the node pool to 3 and
raise the replication factors in `kafka.yaml`. Set `spec.kafka.version` to a version your
installed Strimzi supports.

## 5. Keycloak (operator, CNPG-backed)

```bash
V=26.0.5   # pin the version (see the header of deploy/platform/keycloak/keycloak.yaml)
kubectl apply -n atlas-system \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/keycloaks.k8s.keycloak.org-v1.yml \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -n atlas-system \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/kubernetes.yml

# Keycloak CR + its Ingress. BOTH manifests carry a literal `<cluster-ip>` placeholder;
# substituting it in the pipe (not with `sed -i`) keeps the public IP out of git.
LB=<EXTERNAL-IP>          # the ingress-nginx EXTERNAL-IP from Step 2
sed "s/<cluster-ip>/$LB/g" deploy/platform/keycloak/keycloak.yaml         | kubectl apply -f -
sed "s/<cluster-ip>/$LB/g" deploy/platform/keycloak/keycloak-ingress.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready keycloak/keycloak -n atlas-system --timeout=600s

# Gate: this MUST return 200 before you go on. A 404 with an HTML body is nginx saying no
# Ingress rule matches — the placeholder is still unsubstituted, or the Ingress was skipped
# (TS-PLATFORM-04). Keycloak restarting in a loop with exit code 137 is TS-PLATFORM-08.
curl -sI http://keycloak.$LB.nip.io/realms/master/.well-known/openid-configuration | head -1

# realm import: needs the atlas-realm-credentials Secret first — see Step 5b below
```

> **Don't skip the Ingress.** Keycloak needs a *public, resolvable* host for two different
> reasons: the admin console has to work in a browser, and the issuer (`iss`) baked into
> every token has to be reachable and identical on both sides. Without
> `keycloak-ingress.yaml` there is no route to Keycloak at all, and every later step —
> the realm import gate, the smoke test, the experiments — fails with an nginx 404 whose
> HTML body then breaks `jq` with `Invalid numeric literal`:
> [TS-PLATFORM-04](./deploy/TROUBLESHOOTING.md#ts-platform-04--keycloak-host-404s-nginx-default-page).
>
> **If `keycloak-0` never reaches `1/1`**, check its restart count before anything else. A
> loop with exit code `137` roughly every 10 minutes is
> [TS-PLATFORM-08](./deploy/TROUBLESHOOTING.md#ts-platform-08--keycloak-restarts-forever-exit-code-137)
> — the first-start Quarkus build not fitting inside the startup probe.

Issuer: Keycloak's **public** hostname (`KC_HOSTNAME`) is the LoadBalancer host from Step 2
— the host browser logins go through (`keycloak.<LB-IP>.nip.io`, or your DNS name). The
services validate that **same** issuer string, supplied to them via the `atlas-issuer` Secret
in Step 6, so browser-login tokens and service-side validation agree on one issuer. It must
match character for character, including scheme:

```bash
kubectl -n atlas-apps get secret atlas-issuer \
  -o jsonpath='{.data.KEYCLOAK_ISSUER_URI}' | base64 -d ; echo
# -> http://keycloak.$LB.nip.io/realms/atlas
```

(Keep the issuer host out of git — it lives only in that Secret and in the `sed` above.)

> **The LB IP changed?** Re-run both `sed | kubectl apply` lines and recreate `atlas-issuer`,
> then restart the services (`kubectl -n atlas-apps rollout restart deploy`). A stale issuer
> is silent at deploy time and only shows up as `401` on every authenticated call.

### 5a. Admin credentials — read them, don't guess

There is **no fixed default password**. When `spec.bootstrapAdmin` is unset (our case), the
operator generates a random one and stores it in a Secret named `<CR-name>-initial-admin`
— here `keycloak-initial-admin`, in `atlas-system`. Read it:

```bash
kubectl -n atlas-system get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d ; echo     # -> temp-admin
kubectl -n atlas-system get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Log in at `http://keycloak.<LB-IP>.nip.io/admin` with those.

> ⚠️ **This account is temporary by design.** Keycloak creates it only on first start, in
> the `master` realm, to bootstrap access — it is **not** meant to be your admin account.
> Create a permanent admin user (master realm → Users → *Add user* → Role mapping →
> `admin`), verify you can log in as it, then **delete `temp-admin`**. Keycloak does not
> remove it for you. See
> [Bootstrapping and recovering an admin account](https://www.keycloak.org/server/bootstrap-admin-recovery).

### 5b. The `atlas` realm — one apply, no console clicking

`deploy/platform/keycloak/realm-import.yaml` ships the **complete realm**: the `ADMIN` role,
the `atlas-web` client with direct access grants, and two users. It creates those users
**without passwords**, so nothing sensitive is committed; a second command sets them from a
Secret you create per cluster:

```bash
# 1. the passwords (per-cluster secret, like atlas-issuer — never in git).
#    loadtest-password is shared by the k6 user pool (experiments/README.md).
kubectl create secret generic atlas-realm-credentials -n atlas-system \
  --from-literal=user-password="$(openssl rand -base64 18)" \
  --from-literal=admin-password="$(openssl rand -base64 18)" \
  --from-literal=loadtest-password="$(openssl rand -base64 18)"

# 2. the realm
kubectl apply -f deploy/platform/keycloak/realm-import.yaml
kubectl wait --for=condition=Done keycloakrealmimport/atlas-realm -n atlas-system --timeout=300s

# 3. the passwords onto the users (idempotent — re-run any time to reset them)
LB=<EXTERNAL-IP> ./deploy/platform/keycloak/set-realm-passwords.sh
```

Read a password back when you need it:

```bash
kubectl -n atlas-system get secret atlas-realm-credentials \
  -o jsonpath='{.data.user-password}' | base64 -d ; echo
```

Step 3 is separate because the realm file carries no credentials — that is what keeps it
committable. (Keycloak has a native mechanism for this that does not work on the pinned
version; the reasoning is in the header of `realm-import.yaml` if you ever bump Keycloak.)

What you get:

| Item | Why it is there |
|------|-----------------|
| Realm `atlas` | The issuer path the services validate (`/realms/atlas`) |
| Realm role `ADMIN` | The **only** role any service checks — 18 `@PreAuthorize("hasRole('ADMIN')")` and no others. It is a *realm* role because `KeycloakRealmRoleConverter` reads `realm_access.roles` |
| Public client `atlas-web`, direct access grants on | Mints a token with `grant_type=password` from curl |
| Confidential client `atlas-loadtest` | Used by the k6 experiments. Its secret is **generated by Keycloak**, never committed — read it with `experiments/scripts/cluster-credentials.sh` |
| User `atlas-user`, no roles | Drives the booking saga — every non-admin endpoint is just `.anyRequest().authenticated()` |
| User `atlas-admin`, role `ADMIN` | Seeds the catalog and hits the reconciliation endpoints |

> **Two lab-only settings to tighten before anyone else can reach this cluster:** the realm
> sets `sslRequired: none` (the nip.io host has no certificate, and Keycloak's default would
> reject HTTP token requests with "HTTPS required"), and `atlas-web` accepts wildcard
> `redirectUris`. Both are flagged in the manifest.

**The load experiments need more users.** travel-cart keeps one active cart per JWT subject,
so a k6 run with N virtual users needs N distinct users. That pool is *not* in the realm
file — create it with
[`experiments/scripts/seed-loadtest-users.sh`](./experiments/scripts/seed-loadtest-users.sh),
which is idempotent.

> ### ⚠️ Re-applying does NOT update an existing realm
>
> The operator **only creates** realms: *"If a Realm with the same name already exists in
> Keycloak, it will not be overwritten. The Realm Import CR only supports creation of new
> realms and does not update or delete those."* Re-running `kubectl apply` on a realm that
> already exists reports `Done` and changes **nothing** — silently.
>
> So any change to `realm-import.yaml` — a new client, a new role, a renamed user — reaches
> the cluster only by **deleting the realm and importing it again**. Never by clicking it
> into the admin console: that change would live in one cluster and in no manifest.
>
> Deleting the realm deletes **everything inside it**, including the load-test user pool, so
> the last two commands rebuild what the earlier steps created. Nothing here is destructive
> beyond the realm — the passwords live in the Secret, not in Keycloak.
>
> ```bash
> LB=<EXTERNAL-IP>
>
> # 1. delete the CR and its Job
> kubectl -n atlas-system delete keycloakrealmimport atlas-realm
>
> # 2. delete the realm itself, via the admin API (Step 5a has the admin password)
> ADMIN_USER=$(kubectl -n atlas-system get secret keycloak-initial-admin \
>                -o jsonpath='{.data.username}' | base64 -d)
> ADMIN_PW=$(kubectl -n atlas-system get secret keycloak-initial-admin \
>              -o jsonpath='{.data.password}' | base64 -d)
> TOK=$(curl -s http://keycloak.$LB.nip.io/realms/master/protocol/openid-connect/token \
>         -d grant_type=password -d client_id=admin-cli \
>         -d username="$ADMIN_USER" --data-urlencode "password=$ADMIN_PW" | jq -r .access_token)
> curl -s -X DELETE http://keycloak.$LB.nip.io/admin/realms/atlas \
>        -H "Authorization: Bearer $TOK"
>
> # 3. re-import
> kubectl apply -f deploy/platform/keycloak/realm-import.yaml
> kubectl wait --for=condition=Done keycloakrealmimport/atlas-realm -n atlas-system --timeout=300s
>
> # 4. re-apply the user passwords (the users came back empty)
> LB=$LB ./deploy/platform/keycloak/set-realm-passwords.sh
>
> # 5. re-seed the load-test pool, if you had one (idempotent, safe to skip otherwise)
> cd experiments && eval "$(LB=$LB ./scripts/cluster-credentials.sh)" \
>   && ./scripts/seed-loadtest-users.sh && cd -
> ```

**Verify the import actually took.** The `Done` condition only means the Job ran — it does not
mean the passwords resolved. Mint a token before moving on:

```bash
PW=$(kubectl -n atlas-system get secret atlas-realm-credentials \
       -o jsonpath='{.data.user-password}' | base64 -d)
curl -s http://keycloak.$LB.nip.io/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password -d client_id=atlas-web \
  -d username=atlas-user -d password="$PW" | jq -r '.access_token // .'
```

A JWT means you are done here. `invalid_grant` almost always means step 3 did not run — see
[TS-PLATFORM-05](./deploy/TROUBLESHOOTING.md#ts-platform-05--invalid_grant-when-requesting-a-token).

**Changing the realm.** Edit `realm-import.yaml`, then follow the delete-and-re-import dance
above — there is no in-place update. If a service ever adds a role, that manifest must change
in the same commit: it is derived from the code, not from a console export. To go the other
way (you configured something in the console and want it back in git), export and diff:

```bash
kubectl -n atlas-system exec -it keycloak-0 -- \
  /opt/keycloak/bin/kc.sh export --realm atlas --file /tmp/atlas-realm.json
```

**New to Keycloak?** Three concepts make the rest of this runbook readable: a **realm** is an
isolated tenant (users + clients + roles); a **client** is an application that requests
tokens; the **issuer** (`iss`) is the realm's public URL, which every Atlas service validates
and which must match the `atlas-issuer` Secret from Step 6 exactly — character for character,
including scheme and port. The official
[Getting Started](https://www.keycloak.org/getting-started/getting-started-kube) guide is a
30-minute tour if you want the console walkthrough;
[Automating a realm import](https://www.keycloak.org/operator/realm-import) documents the CR
this step applies.

## 6. Atlas services

**Prerequisite — images (no CI of your own needed).** The service images are **public** on
GHCR (`ghcr.io/atlas-event-lab/atlas-<service>`), built and pushed to `:latest` by each
service repo's CI on every push to main (see Step 0). **Deploying is just `helm` (below);
you never run a pipeline.** By default each service pulls `:latest` (the chart's
`appVersion`), so the commands below work as-is. For a reproducible run, pin a fixed tag
with `--set image.tag=<tag>`.

### App secret — `atlas-issuer` (create this BEFORE deploying the services)

Every service reads `KEYCLOAK_ISSUER_URI` from a Secret named **`atlas-issuer`** in
`atlas-apps` (via `secretKeyRef` in the chart values). It is kept **out of git** so the public
host/IP is never committed. **Create it first** — if it is missing, the pods never start and
sit in `CreateContainerConfigError: secret "atlas-issuer" not found`.

The value MUST equal Keycloak's **public** issuer (its `KC_HOSTNAME` from Step 5) — the host
browser logins go through, i.e. the LoadBalancer host from Step 2 (`keycloak.<LB-IP>.nip.io`,
or your own DNS name):

```bash
LB=<EXTERNAL-IP>          # same value as Step 5
kubectl create secret generic atlas-issuer -n atlas-apps \
  --from-literal=KEYCLOAK_ISSUER_URI="http://keycloak.$LB.nip.io/realms/atlas"
```

> **This is an imperative, per-cluster Secret** — not in git, not created by CI. **Recreate it
> on every new cluster** (right here, before the services). If you want it reproducible instead,
> seal it with `kubeseal` and commit the `SealedSecret`, or have your CI upsert it from a
> GitHub/secret-manager value before deploy (see the Secrets section below).

```bash
# 6a. Fake Payment Provider (payment depends on it)
kubectl create configmap wiremock-mappings -n atlas-apps \
  --from-file=wiremock/mappings/ --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/platform/apps/wiremock.yaml

# 6b. the services (library chart at deploy/helm/atlas-service)
cd deploy/helm/atlas-service
for s in user flight hotel inventory travel-cart booking payment search; do
  helm upgrade --install $s-service . -f values/$s.yaml -n atlas-apps
done
cd -

# 6c. edge routing
kubectl apply -f deploy/platform/apps/atlas-ingress.yaml
kubectl get ingress -n atlas-apps

# 6d. gate — all 8 services Running. First run on a cold node takes a while: each image is
# ~265 MB and kubelet pulls them ONE AT A TIME per node, so 10+ min of ContainerCreating is
# expected, not broken. See TROUBLESHOOTING TS-APPS-02.
kubectl get pods -n atlas-apps -w
```

> **`Startup probe failed` warnings during boot are normal** — Spring Boot needs longer than
> the first probes allow, and the pod's event history keeps them after it goes healthy. Judge
> a pod by `Ready` and its restart count, not by past warnings:
> [TS-APPS-03](./deploy/TROUBLESHOOTING.md#ts-apps-03--startup-probe-failed-warnings-while-a-service-boots).

> **Coming back after `ops/apps/idle.sh`? Do NOT use 6b — run `./deploy/ops/apps/resume.sh`.**
> `inventory`, `booking` and `search` have `autoscaling.enabled`, and `payment` has
> `keda.enabled`, so the chart renders all four **without** `spec.replicas` — an autoscaler
> owns the count. An HPA cannot lift a Deployment off **0** replicas (with no pods it has no
> per-pod metrics to read), so the `helm upgrade` in 6b leaves those four silently stuck at
> zero — `helm` reports success and `kubectl get pods` simply shows nothing for them.
> `resume.sh` nudges each one to its `minReplicas` and un-pauses the KEDA ScaledObjects.
> See TROUBLESHOOTING TS-APPS-01.

## 7. Observability + Kafka UI (required — this is how you *see* it work)

The **evidence layer**. Not optional: the load and resilience experiments are validated *in
Grafana* — metrics, logs, and traces threaded across the saga — not by assertion.

**Grafana LGTM stack** (Prometheus + Loki + Tempo + Alloy) plus the Atlas dashboards and
datasources. The full ordered procedure — `metrics-server` prerequisite, per-service
scraping, datasources, and the dashboards — is in
**[`deploy/platform/observability/README.md`](./deploy/platform/observability/README.md)**.
Follow it end to end, then come back here.

> **Two things in that README are easy to skip and both leave you with empty dashboards:**
>
> 1. **Kafka's PodMonitor** (`strimzi/kafka-exporter-podmonitor.yaml`). Nothing scrapes Kafka
>    without it, so every panel of the Kafka dashboard — brokers online, consumer lag,
>    under-replicated partitions, throughput — stays blank. It belongs here, not in Step 4:
>    `PodMonitor` is a CRD that kube-prometheus-stack installs.
> 2. **All the Atlas dashboards, not just RED.** The experiments reference **HTTP RED**,
>    **Kafka**, **CNPG** and one dashboard **per experiment** (Exp 01, 02, 04–07) by name, and
>    install none of them. They ship as ConfigMaps and go in with a single glob; the exception
>    is `cnpg-dashboard.json`, a raw Grafana export that has to be wrapped and applied
>    `--server-side`.
>
> Check both: `kubectl -n atlas-data get podmonitor` and
> `kubectl -n atlas-observability get cm -l grafana_dashboard=1` (expect nine).
>
> **On the GitOps path you get all of this for free** — the `obs-config` Application (wave 4)
> globs `*-dashboard.yaml`, so every dashboard is installed at bootstrap.

> **Loki, Tempo and Prometheus are StatefulSets with PVCs.** If one sits in
> `ContainerCreating` while `kubectl get pvc -n atlas-observability` already shows `Bound`,
> that is a volume-mount failure, not a slow install — see
> [TS-PLATFORM-06](./deploy/TROUBLESHOOTING.md#ts-platform-06--stateful-pod-stuck-containercreating-with-a-bound-pvc)
> and re-run the node-health check from Step 0.

**Kafka UI** — inspect topics, consumer groups and lag. Its Ingress carries the same
`<cluster-ip>` placeholder as the Keycloak manifests in Step 5, so substitute it the same way:

```bash
kubectl apply -f deploy/platform/kafka/kafka-ui.yaml
kubectl -n atlas-data rollout status deploy/kafka-ui

LB=<EXTERNAL-IP>          # same value as Step 5
sed "s/<cluster-ip>/$LB/g" deploy/platform/kafka/kafka-ui-ingress.yaml | kubectl apply -f -
# -> http://kafka.$LB.nip.io   (no port-forward needed)
```

Prefer not to expose it? Skip the Ingress and port-forward instead:
`kubectl -n atlas-data port-forward svc/kafka-ui 8081:8080`.

## 8. Autoscaling with KEDA (for the load/resilience experiments)

Needed by the experiments that scale on Kafka lag (Exp 01, 04, …):

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm upgrade --install keda kedacore/keda -n keda --create-namespace
kubectl apply -f deploy/platform/keda/     # ScaledObjects (Kafka-lag driven)

# Verify — BOTH must appear, and payment must have no CPU HPA of its own:
kubectl -n atlas-apps get scaledobject                     # payment-service, wiremock
kubectl -n atlas-apps get hpa                              # expect keda-hpa-payment-service
kubectl -n atlas-apps get hpa payment-service 2>&1 | tail -1   # expect: NotFound
```

> **A Deployment may have only ONE autoscaler.** If a CPU HPA named `payment-service` exists,
> KEDA's admission webhook rejects the ScaledObject outright:
> `admission webhook "vscaledobject.kb.io" denied the request: the workload 'payment-service'
> ... is already managed by the hpa 'payment-service'`. The apply above then fails **for that
> one file** while the rest succeed — easy to miss in the output, and payment silently keeps
> CPU scaling, which is precisely what ADR-0015 rejected for an I/O-bound service. This is why
> `values/payment.yaml` sets `autoscaling.enabled: false` **and** `keda.enabled: true`. If you
> hit the error on an existing cluster, see
> [TS-APPS-05](./deploy/TROUBLESHOOTING.md#ts-apps-05--keda-scaledobject-rejected-workload-already-managed-by-an-hpa).

## 9. Connect to the databases (optional, but this is where the patterns become visible)

Nine databases live in one CloudNativePG cluster, **one per service** — that separation is a
non-negotiable of the architecture, not a convention. As an operator you can read any of them;
a *service* may only ever touch its own.

| Database | Owner role | Secret (`atlas-data`) | What is interesting in it |
|----------|-----------|------------------------|---------------------------|
| `flight_db` | `flight_user` | `flight-secret` | catalog + `outbox` |
| `hotel_db` | `hotel_user` | `hotel-secret` | catalog + `outbox` |
| `inventory_db` | `inventory_user` | `inventory-secret` | `reservations`, `inventory`, `outbox` |
| `search_db` | `search_user` | `search-secret` | read model: `*_projections`, `consumed_events` |
| `booking_db` | `booking_user` | `booking-secret` | `bookings` (saga state), `booking_status_history` |
| `payment_db` | `payment_user` | `payment-secret` | payments + `outbox` |
| `travel_cart_db` | `travel_cart_user` | `travel-cart-secret` | active carts |
| `user_db` | `user_user` | `user-secret` | profiles, preferences |
| `keycloak_db` | `keycloak_user` | `keycloak-db-secret` | Keycloak's own storage — leave it alone |

### Credentials and connection

Passwords were generated by `create-db-secrets.sh` in Step 3b and exist only in the cluster.
Read the one you need:

```bash
SVC=search        # flight | hotel | inventory | search | booking | payment | travel-cart | user
kubectl -n atlas-data get secret ${SVC}-secret -o jsonpath='{.data.username}' | base64 -d ; echo
kubectl -n atlas-data get secret ${SVC}-secret -o jsonpath='{.data.password}' | base64 -d ; echo
```

Forward the primary and connect with whatever client you like — `psql`, DBeaver, pgAdmin,
DataGrip. Keep the forward running in its own terminal:

```bash
kubectl -n atlas-data port-forward svc/atlas-pg-rw 5432:5432
```

Then, in another one:

```bash
PGPASSWORD=$(kubectl -n atlas-data get secret search-secret \
               -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -p 5432 -U search_user -d search_db
```

GUI clients want the same four values: host `localhost`, port `5432`, database `<svc>_db`,
user `<svc>_user`, password from the Secret.

> **`atlas-pg-rw` is the primary — `atlas-pg-ro` are the replicas.** For pure inspection,
> forward `svc/atlas-pg-ro` instead and you cannot disturb the write path at all. Use `-rw`
> only when you actually intend to write.
>
> **Read, don't write.** Mutating a table by hand puts the read models and the saga out of
> step with the events that produced them, and the experiments then measure your edit instead
> of the system. If you want a clean slate, recreate the cluster.

### Four queries that show the architecture

**1. The outbox pattern — and Step 10 doing its job.** The catalog rows were seeded by Flyway
straight into the table, so they have no event. Run this in `flight_db` *before* Step 10:

```sql
SELECT status, count(*) FROM outbox GROUP BY status;
```

Empty. Run Step 10, then run it again: rows appear and move to published as the relay ships
them. This is the transactional outbox — the event and the state change committed together,
never a dual write.

```sql
SELECT event_type, status, created_at, published_at
FROM outbox ORDER BY created_at DESC LIMIT 10;
```

**2. The read model filling up.** `search_db` owns no catalog; everything in it arrived as an
event from `flight_db` / `hotel_db`:

```sql
SELECT count(*) FROM flight_projections;
SELECT count(*) FROM hotel_projections;
SELECT event_type, count(*) FROM consumed_events GROUP BY event_type;
```

`consumed_events` is the idempotency ledger — the reason replaying a duplicate event (Exp 03)
changes nothing. Compare its count against what Kafka UI reports delivered.

**3. Saga state, once you have made a booking.** `booking_db` records every transition:

```sql
SELECT booking_id, status, saga_id, correlation_id, created_at, confirmed_at
FROM bookings ORDER BY created_at DESC LIMIT 5;

SELECT * FROM booking_status_history
WHERE booking_id = '<id from above>' ORDER BY 1;
```

The `correlation_id` is the thread: paste it into Loki in Grafana and you get every service's
log line for that one booking. `saga_id` groups the compensations.

**4. The no-oversell invariant.** `inventory_db` is where Experiment 02 is decided:

```sql
SELECT status, count(*) FROM reservations GROUP BY status;
SELECT resource_id, quantity, status, expires_at
FROM reservations WHERE status = 'CONFIRMED' ORDER BY created_at DESC LIMIT 10;
```

Total confirmed units per resource must never exceed capacity in `inventory` — under load,
that is the invariant `atlas_inventory_oversell_attempts_total` watches from the other side.

## 10. Publish the catalog (reconciliation) — the cluster is empty until you do

**Why this step exists.** Each service seeds its own catalog through Flyway migrations that
ship inside the image (`flight-service` `V4__seed_catalog.sql` / `V5__seed_flights.sql`,
`hotel-service` `V3__seed_catalog.sql` / `V6__seed_hotel_catalog_*.sql`). Those migrations
`INSERT` straight into `flight_db` / `hotel_db` — they **bypass the outbox**, so no domain
event was ever emitted for them.

`inventory-service` and `search-service` own no catalog of their own: they learn about flights
and hotels **only** from events. So on a fresh cluster the catalog exists in Postgres and is
invisible to everything else. `/api/v1/search/flights` returns an empty list and no booking can
be made, with nothing in any log to suggest why.

The reconciliation endpoints close that gap. Each one asks its repository for the rows that
never published a Created event and writes them to the outbox, which the relay then ships to
Kafka like any other event — same path, no shortcut.

```bash
LB=<EXTERNAL-IP>

# ADMIN token — both endpoints are @PreAuthorize("hasRole('ADMIN')"), so atlas-user will
# get a 403 here. atlas-admin carries the ADMIN realm role (Step 5b).
ADMIN_PW=$(kubectl -n atlas-system get secret atlas-realm-credentials \
             -o jsonpath='{.data.admin-password}' | base64 -d)
TOKEN=$(curl -s http://keycloak.$LB.nip.io/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password -d client_id=atlas-web \
  -d username=atlas-admin --data-urlencode "password=$ADMIN_PW" | jq -r .access_token)

# Publish. Both are POST with no body and answer "SUCCESS".
curl -s -X POST http://$LB/api/v1/flights/reconciliation -H "Authorization: Bearer $TOKEN"; echo
curl -s -X POST http://$LB/api/v1/hotels/reconciliation  -H "Authorization: Bearer $TOKEN"; echo
```

`403` means the token is `atlas-user`'s, not `atlas-admin`'s. `401` means the issuer does not
match — [TS-APPS-04](./deploy/TROUBLESHOOTING.md#ts-apps-04--401-on-every-authenticated-call).

**Confirm it landed.** The read model is populated asynchronously, so give it a few seconds:

```bash
curl -s "http://$LB/api/v1/search/flights" | jq 'length'   # was 0, now > 0
```

### First look at the system working

This is the first time data crosses every seam in the architecture, which makes it the best
moment to learn where to look. The same three views are how you will read the experiments.

**Kafka UI** — the events themselves:

```bash
kubectl -n atlas-data port-forward svc/kafka-ui 8081:8080   # → http://localhost:8081
```

Open **Topics** and look at the flight and hotel catalog topics: message counts jumped from
zero. Then **Consumer Groups** — `inventory-service` and `search-service` should show lag
returning to `0` as they drain what you just published. Lag that climbs and stays is the
signal that a consumer is down, and it is the same signal the load experiments watch.

**Grafana** — the golden signals (access per
[`deploy/platform/observability/README.md`](./deploy/platform/observability/README.md)):

- **Atlas → HTTP RED** (uid `atlas-red-http`): your two POSTs appear as traffic on
  `flight-service` and `hotel-service`, and the consumer-side work shows up on
  `inventory-service` and `search-service`. A flat error rate is what you want.
- **Atlas → Kafka**: throughput on the catalog topics and consumer-group lag draining — the
  same story as Kafka UI, in the shape you will use during load.
- **CNPG**: the write burst on `flight_db` / `hotel_db` from the outbox inserts.

**Tempo** — pick any request in the RED dashboard's latency panel and follow its exemplar into
the trace. This is the tooling that later shows a booking saga threaded across six services.

**The databases** — if you kept a session open from Step 9, this is the moment the outbox
query pays off. `flight_db` / `hotel_db` show rows appearing in `outbox` and moving to
published; `search_db` shows `flight_projections` and `hotel_projections` going from zero to
populated, and `consumed_events` recording exactly what it processed. Event produced,
transported, consumed, projected — all four in one command's worth of consequences.

> **Re-running is safe.** `reconcile()` only picks up rows with no Created event, so a second
> call after a successful one publishes nothing. If you ever wipe a read model and need to
> republish the *whole* catalog, that is a different operation (`resyncAll`, ADR-0026) and not
> exposed on this endpoint.

---

## Validation gates

- [ ] `kubectl get ns` shows the four namespaces (incl. `atlas-observability`).
- [ ] ingress-nginx Service has an `EXTERNAL-IP`.
- [ ] `cluster/atlas-pg` is `Ready`; `kubectl get database -n atlas-data` lists all DBs.
- [ ] `kafka/atlas` is `Ready`; `kubectl get kafkatopic -n atlas-data` lists the topics.
- [ ] `kubectl get ingress -n atlas-system` shows the `keycloak` Ingress with the real IP
      in its host (no literal `<cluster-ip>`), and
      `curl -sI http://keycloak.<LB-IP>.nip.io/realms/atlas/.well-known/openid-configuration`
      returns `200`.
- [ ] Keycloak `Ready` and `/realms/atlas` reachable in-cluster.
- [ ] `keycloakrealmimport/atlas-realm` reports `Done`; `atlas-web`, `atlas-user` and
      `atlas-admin` exist (Step 5b), and `temp-admin` has been replaced by a permanent
      admin and deleted (Step 5a).
- [ ] `curl http://<LB-IP>/api/v1/flights` returns through the cluster.
- [ ] Catalog published (Step 10): `/api/v1/search/flights` returns a **non-empty** list, and
      the `inventory-service` / `search-service` consumer groups show lag back at `0`.
- [ ] The Atlas dashboards are loaded in Grafana (RED, Kafka, Exp 02, CNPG), and
      `kubectl -n atlas-data get podmonitor` lists `kafka-resources-metrics` — without it the
      whole Kafka dashboard is blank.
- [ ] A full end-to-end saga booking reaches `CONFIRMED`.

---

## See it work — first booking, then the experiments

The stack is up. Now watch a booking flow through the saga, open the dashboards, and run the
experiments — the whole reason the lab exists.

**1. Smoke-test the API.** Use the LoadBalancer host (the `EXTERNAL-IP` from Step 2) and a
token from Keycloak. The client `atlas-web` and the user `atlas-user` come from the realm
import in Step 5b; the password is read straight out of the Secret you created there.

> An empty `[]` from the search call below means Step 10 has not run — the catalog is in
> Postgres but was never published to the read models.

```bash
LB=<EXTERNAL-IP>
PW=$(kubectl -n atlas-system get secret atlas-realm-credentials \
       -o jsonpath='{.data.user-password}' | base64 -d)
TOKEN=$(curl -s http://keycloak.$LB.nip.io/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password -d client_id=atlas-web \
  -d username=atlas-user -d password="$PW" | jq -r .access_token)
curl -s http://$LB/api/v1/search/flights -H "Authorization: Bearer $TOKEN" | jq
```

> No token back?
> [TS-PLATFORM-05](./deploy/TROUBLESHOOTING.md#ts-platform-05--invalid_grant-when-requesting-a-token)
> covers `invalid_grant`. `unauthorized_client` means direct access grants are off on the
> client and `HTTPS required` means the realm's `sslRequired` is not `none` — both are
> settings in `realm-import.yaml`. A token that *is* issued but gets `401` from every service
> is [TS-APPS-04](./deploy/TROUBLESHOOTING.md#ts-apps-04--401-on-every-authenticated-call).
> Swap `atlas-user` for `atlas-admin` when you need the `ADMIN` role.

Then create a booking and watch it reach `CONFIRMED`. The request shapes are identical to the
[local walkthrough](./deploy-local/LOCAL-DEPLOYMENT.md#4-create-a-booking-kicks-off-the-saga) —
just against `http://$LB` instead of `localhost:8080`.

**2. Open the dashboards — the evidence.**

- **Grafana** — RED metrics, Kafka, CNPG, and traces threaded across the saga. Access and the
  Atlas dashboards: [`deploy/platform/observability/README.md`](./deploy/platform/observability/README.md).
- **Kafka UI** — topics, consumer groups, lag:
  ```bash
  kubectl -n atlas-data port-forward svc/kafka-ui 8081:8080   # → http://localhost:8081
  ```

**3. Run the experiments** — load-test it, replay duplicates, kill a consumer mid-saga, and
watch it scale, heal, and never oversell or double-charge, live in Grafana:
**[`experiments/README.md`](./experiments/README.md)**.

---

## Operations (cost & capacity)

Turn worker compute off when idle to save trial credit (the big saver), and idle the apps
while keeping the platform up. The per-cloud scripts and the cost model are in
**[`deploy/ops/README.md`](./deploy/ops/README.md)**.

---

## Vendor porting checklist

| Concern | OKE | Civo | GKE | EKS | kind/k3d (local) |
|---------|-----|------|-----|-----|------------------|
| StorageClass | `oci-bv` | `civo-volume` | `standard-rwo` | `gp3` | `local-path` |
| LoadBalancer | OCI LB | Civo LB | Google LB | NLB | MetalLB / NodePort |
| Resize node pool | `oci ce ...` | `terraform apply` | `gcloud container ...` | `eksctl ...` | n/a |
| Stable public IP | Reserved IP | Reserved IP | Static IP | EIP | n/a |

Everything else (operators, charts, manifests, secrets flow) is identical across vendors —
which is exactly what a second deployment should **prove**.

---

## Secrets

Two supported paths:

- **Manual bootstrap (to get running):** `cloudnative-pg/create-db-secrets.sh` creates
  Secrets directly in the cluster with random passwords. Nothing is committed → safe.
- **GitOps (later):** seal the same Secrets with `kubeseal` and commit the `SealedSecret`.
  Requires the sealed-secrets controller in-cluster and the `kubeseal` CLI.

The exact per-service DB secret shape (one `basic-auth` Secret with four keys, serving both
CNPG and the app) is documented in
[`deploy/platform/README.md`](./deploy/platform/README.md#db-secret-shape-referenced-from-the-runbook).

Per-cluster app secrets to create before the services (Step 6):

| Secret | Namespace | Holds | Notes |
|--------|-----------|-------|-------|
| per-service DB secret | `atlas-data` / `atlas-apps` | `DB_USERNAME` / `DB_PASSWORD` | via `create-db-secrets.sh` (Step 3b) |
| `atlas-realm-credentials` | `atlas-system` | `user-password` / `admin-password` / `loadtest-password` | realm user passwords, applied by `set-realm-passwords.sh` and read by the experiments; recreate per cluster (Step 5b) |
| `atlas-issuer` | `atlas-apps` | `KEYCLOAK_ISSUER_URI` | public Keycloak issuer; imperative, recreate per cluster (Step 6) |

Never commit plaintext Secrets or the cluster `kubeconfig`.
