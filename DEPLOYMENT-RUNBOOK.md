# Atlas — Deployment Runbook (Kubernetes, vendor-agnostic)

How to take Atlas from zero to a running, scalable, observable stack on **any** conformant
Kubernetes cluster. This runbook generalizes the original Oracle-OKE-specific runbook to the
portability principle: everything stateful runs in-cluster.

> **Portability thesis.** All stateful infrastructure (Postgres, Kafka, Keycloak) runs
> **inside the cluster** via operators. The only vendor-specific surfaces are (1) the
> **node pool** and (2) the **LoadBalancer** that fronts Ingress. Moving vendor = recreate
> those two and re-apply the manifests.

> **Where the manifests live.** All manifests referenced below are in this repo under
> [`deploy/`](./deploy) — `deploy/platform/` (operators, CRs, observability, KEDA),
> `deploy/helm/atlas-service/` (the library chart + per-service values), and `deploy/ops/`
> (cost/capacity scripts). Paths below are relative to the repo root. The same charts are
> also mirrored in the GitOps repo (`atlas-event-lab/atlas-gitops`) for continuous delivery.

---

## 0. Prerequisites

| Tool | Used for |
|------|----------|
| `kubectl` (context pointing at the new cluster) | applying manifests |
| `helm` 3.x | operators & charts |
| A block-storage `StorageClass` | Postgres/Kafka PVCs |
| Images in an accessible registry | `ghcr.io/atlas-event-lab/atlas-<service>` |

```bash
kubectl config current-context      # confirm you are on the right cluster
kubectl get storageclass            # note the StorageClass name (you will need it)
kubectl get nodes                   # node pool ready
```

**Vendor-specific decisions to make up front:**

1. **StorageClass** — each vendor names its own (`oci-bv`, `standard-rwo` on GKE, `gp3` on
   EKS, `managed-csi` on AKS, `local-path` on kind/k3d). Set it in the CNPG cluster and
   Kafka manifests.
2. **LoadBalancer** — ingress-nginx requests a cloud LB. On local clusters (kind/k3d) use
   `NodePort` or MetalLB.
3. **Stable public IP / hostname** — Keycloak's `issuer` is pinned to it; if it changes it
   breaks JWT validation across all services. Reserve a static IP where the vendor allows.

---

## 1. Namespaces

```bash
kubectl apply -f deploy/platform/00-namespaces.yaml
kubectl get ns atlas-system atlas-data atlas-apps
```

`atlas-system` (ingress, Keycloak) · `atlas-data` (Postgres, Kafka) · `atlas-apps` (the
services + simulated payment provider).

## 2. Ingress (single entry point)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n atlas-system -f deploy/platform/ingress-nginx/values.yaml
kubectl get svc -n atlas-system ingress-nginx-controller -w   # wait for EXTERNAL-IP
```

> **kind/k3d:** without a cloud LB there is no EXTERNAL-IP. Use the kind/k3d ingress add-on
> or install MetalLB.

## 3. Postgres (CloudNativePG operator)

```bash
# 3a. operator
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl rollout status deploy/cnpg-cloudnative-pg -n cnpg-system

# 3b. per-service DB secrets (BEFORE creating the cluster)
./deploy/platform/cloudnative-pg/create-db-secrets.sh
kubectl get secret -n atlas-data          # expect the per-service *-secret entries

# 3c. cluster + databases  (edit storageClass first)
kubectl apply -f deploy/platform/cloudnative-pg/cluster.yaml
kubectl wait --for=condition=Ready cluster/atlas-pg -n atlas-data --timeout=300s
kubectl apply -f deploy/platform/cloudnative-pg/databases.yaml
kubectl get database -n atlas-data
```

Connection string (already in the Helm values): `atlas-pg-rw.atlas-data:5432/<db>`
(`-rw` primary; `-ro` read replicas).

## 4. Kafka (Strimzi, KRaft — no ZooKeeper)

```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n atlas-data
kubectl rollout status deploy/strimzi-cluster-operator -n atlas-data

kubectl apply -f deploy/platform/strimzi/kafka.yaml   # edit storageClass
kubectl wait --for=condition=Ready kafka/atlas -n atlas-data --timeout=300s
kubectl apply -f deploy/platform/strimzi/topics.yaml
kubectl get kafkatopic -n atlas-data
```

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

kubectl apply -f deploy/platform/keycloak/keycloak.yaml
kubectl wait --for=condition=Ready keycloak/keycloak -n atlas-system --timeout=300s
kubectl apply -f deploy/platform/keycloak/realm-import.yaml   # paste your exported realm first
```

Issuer: set Keycloak's **public** hostname (`KC_HOSTNAME`) to the LoadBalancer host from Step 2
— the host browser logins go through (e.g. `keycloak.<LB-IP>.nip.io`, or your DNS name). The
services validate that **same** issuer string, supplied to them via the `atlas-issuer` Secret
in Step 6, so browser-login tokens and service-side validation agree on one issuer. (Keep the
issuer host out of git — it lives only in that Secret.)

## 6. Atlas services

Prerequisite: images exist in GHCR, pushed by each repo's CI. If the GHCR packages are
private, create a pull secret in `atlas-apps` and set `imagePullSecrets` in the chart values.

### App secret — `atlas-issuer` (create this BEFORE deploying the services)

Every service reads `KEYCLOAK_ISSUER_URI` from a Secret named **`atlas-issuer`** in
`atlas-apps` (via `secretKeyRef` in the chart values). It is kept **out of git** so the public
host/IP is never committed. **Create it first** — if it is missing, the pods never start and
sit in `CreateContainerConfigError: secret "atlas-issuer" not found`.

The value MUST equal Keycloak's **public** issuer (its `KC_HOSTNAME` from Step 5) — the host
browser logins go through, i.e. the LoadBalancer host from Step 2 (`keycloak.<LB-IP>.nip.io`,
or your own DNS name):

```bash
kubectl create secret generic atlas-issuer -n atlas-apps \
  --from-literal=KEYCLOAK_ISSUER_URI='http://keycloak.<LB-host>/realms/atlas'
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
```

## 7. Observability (optional, recommended)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n atlas-system -f deploy/platform/observability/kube-prometheus-stack-values.yaml
helm upgrade --install loki  grafana/loki  -n atlas-system -f deploy/platform/observability/loki-values.yaml
helm upgrade --install tempo grafana/tempo -n atlas-system -f deploy/platform/observability/tempo-values.yaml
helm upgrade --install alloy grafana/alloy -n atlas-system -f deploy/platform/observability/alloy-values.yaml
```

Atlas dashboards (RED, Kafka, CNPG, experiments) live in `deploy/platform/observability/`.

## 8. Autoscaling under load (optional — experiments)

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm upgrade --install keda kedacore/keda -n keda --create-namespace
kubectl apply -f deploy/platform/keda/     # ScaledObjects (Kafka-lag driven)
```

---

## Validation gates

- [ ] `kubectl get ns` shows the three namespaces.
- [ ] ingress-nginx Service has an `EXTERNAL-IP`.
- [ ] `cluster/atlas-pg` is `Ready`; `kubectl get database -n atlas-data` lists all DBs.
- [ ] `kafka/atlas` is `Ready`; `kubectl get kafkatopic -n atlas-data` lists the topics.
- [ ] Keycloak `Ready` and `/realms/atlas` reachable in-cluster.
- [ ] `curl http://<LB-IP>/api/v1/flights` returns through the cluster.
- [ ] A full end-to-end saga booking reaches `CONFIRMED`.

---

## Operations (cost & capacity)

Two independent levers (script names assume a cloud CLI; the concept is portable):

| Lever | Effect |
|-------|--------|
| cluster down/up | node pool → 0 / → N. Stops compute billing. |
| apps idle/resume | scale apps to 0 (delete HPAs first) while the platform stays up. |

> When porting to another vendor, adapt the node-pool resize scripts (they call the cloud's
> CLI) — that is the only non-portable part of operations.

---

## Vendor porting checklist

| Concern | OKE | GKE | EKS | AKS | kind/k3d (local) |
|---------|-----|-----|-----|-----|------------------|
| StorageClass | `oci-bv` | `standard-rwo` | `gp3` | `managed-csi` | `local-path` |
| LoadBalancer | OCI LB | Google LB | NLB | Azure LB | MetalLB / NodePort |
| Resize node pool | `oci ce ...` | `gcloud container ...` | `eksctl ...` | `az aks ...` | n/a |
| Stable public IP | Reserved IP | Static IP | EIP | Static Public IP | n/a |

Everything else (operators, charts, manifests, secrets flow) is identical across vendors —
which is exactly what a second deployment should **prove**.

---

## Secrets

Two supported paths:

- **Manual bootstrap (to get running):** `cloudnative-pg/create-db-secrets.sh` creates
  Secrets directly in the cluster with random passwords. Nothing is committed → safe.
- **GitOps (later):** seal the same Secrets with `kubeseal` and commit the `SealedSecret`.
  Requires the sealed-secrets controller in-cluster and the `kubeseal` CLI.

Per-cluster app secrets to create before the services (Step 6):

| Secret | Namespace | Holds | Notes |
|--------|-----------|-------|-------|
| per-service DB secret | `atlas-data` / `atlas-apps` | `DB_USERNAME` / `DB_PASSWORD` | via `create-db-secrets.sh` (Step 3b) |
| `atlas-issuer` | `atlas-apps` | `KEYCLOAK_ISSUER_URI` | public Keycloak issuer; imperative, recreate per cluster (Step 6) |

Never commit plaintext Secrets or the cluster `kubeconfig`.
