# Atlas platform bootstrap (atlas-infra)

Ordered runbook to stand up the in-cluster platform on OKE (SPEC-DEPLOY-001 Phase 4).
Everything stateful runs in-cluster for portability (roadmap §0). Run the steps in order;
each ends with a validation check. Operators are installed from their official Helm
charts — we only own the namespaces, values, and custom resources here.

Namespaces: `atlas-system` (ingress, Keycloak), `atlas-data` (Postgres, Kafka),
`atlas-apps` (the 9 services + wiremock).

> Status: all four components have manifests + runbook steps. Validate each `kubectl`
> step against the cluster as you go (operator CR schemas can't be checked offline).

## Prerequisites
- `kubectl` context pointing at the OKE cluster (`kubectl config current-context`).
- `helm` 3.x.
- Per-service DB secrets created (see "Secrets" below) before applying the CNPG cluster.

## Step 0 — Namespaces
```bash
kubectl apply -f 00-namespaces.yaml
kubectl get ns atlas-system atlas-data atlas-apps
```

## Step 1 — Ingress (single public entry point)
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n atlas-system -f ingress-nginx/values.yaml
# wait for the OCI LoadBalancer to get an external IP:
kubectl get svc -n atlas-system ingress-nginx-controller -w
```

## Step 2 — Postgres (CloudNativePG)
```bash
# 2a. operator
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl rollout status deploy/cnpg-cloudnative-pg -n cnpg-system

# 2b. per-service DB secrets MUST exist before the cluster reconciles its roles.
#     Manual bootstrap (you are here): run the helper — creates all 9 secrets with
#     random passwords in the right namespaces. No sealed-secrets controller needed.
./cloudnative-pg/create-db-secrets.sh
kubectl get secret -n atlas-data        # expect the 9 *-secret entries
#     (GitOps alternative: seal them instead — see "Secrets" below. Needs the
#      sealed-secrets controller in-cluster + the kubeseal CLI.)

# 2c. cluster + databases
kubectl apply -f cloudnative-pg/cluster.yaml
kubectl wait --for=condition=Ready cluster/atlas-pg -n atlas-data --timeout=300s
kubectl apply -f cloudnative-pg/databases.yaml
kubectl get database -n atlas-data
```
Service connection string (already in the Helm values): `atlas-pg-rw.atlas-data:5432/<db>`
(`-rw` = primary; `-ro` = replicas for read-only workloads).

## Step 3 — Kafka (Strimzi, KRaft)
```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n atlas-data
kubectl rollout status deploy/strimzi-cluster-operator -n atlas-data

kubectl apply -f strimzi/kafka.yaml
kubectl wait --for=condition=Ready kafka/atlas -n atlas-data --timeout=300s
kubectl apply -f strimzi/topics.yaml
kubectl get kafkatopic -n atlas-data        # expect 24 topics
```
Baseline is 1 broker (RF=1). For replication/DLQ experiments, set the node pool
`replicas: 3` and raise the replication factors in `kafka.yaml`.
> Set `spec.kafka.version` in `kafka.yaml` to a version your installed Strimzi supports.

## Step 4 — Keycloak (operator + CNPG-backed)
```bash
# 4a. operator (pin a version — see the header of keycloak/keycloak.yaml)
V=26.0.5
kubectl apply -n atlas-system \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/keycloaks.k8s.keycloak.org-v1.yml \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -n atlas-system \
  -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes/kubernetes.yml

# 4b. Keycloak instance (uses keycloak_db + keycloak-db-secret from Step 2) + realm
kubectl apply -f keycloak/keycloak.yaml
kubectl wait --for=condition=Ready keycloak/keycloak -n atlas-system --timeout=300s
# paste your exported realm into keycloak/realm-import.yaml first, then:
kubectl apply -f keycloak/realm-import.yaml
```
Issuer: `http://keycloak-service.atlas-system:8080/realms/atlas` — this exact string is
both the Keycloak `hostname` and the services' `KEYCLOAK_ISSUER_URI`, so in-cluster JWT
validation matches. (Browser login needs the public Ingress hostname — wire that in Phase 5.)

## Step 5 — Deploy the services (Phase 5)
Prerequisite: images exist in GHCR (`ghcr.io/atlas-event-lab/atlas-<service>`), pushed by
each repo's CI (`ci.yml`). If the GHCR packages are private, create a pull secret in
`atlas-apps` and set `imagePullSecrets` in the chart values.

```bash
# All commands below run from deploy/platform/ (same as the earlier steps).

# 5a. Fake Payment Provider (payment depends on it). Mappings live at the repo root
#     (../../wiremock/mappings/ relative to here).
kubectl create configmap wiremock-mappings -n atlas-apps \
  --from-file=../../wiremock/mappings/ --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f apps/wiremock.yaml

# 5b. the 9 services (chart at ../helm/atlas-service)
cd ../helm/atlas-service
for s in user flight hotel inventory travel-cart booking payment search; do
  helm upgrade --install $s-service . -f values/$s.yaml -n atlas-apps
done

# 5c. edge routing
kubectl apply -f ../../platform/apps/atlas-ingress.yaml
kubectl get ingress -n atlas-apps
```
Exit criteria: `curl http://<LB-IP>/api/v1/flights` returns through the cluster and a full
Saga booking flow completes. Set each service's `image.tag` (CI does this in push-deploy);
until CI runs you can deploy a manually-built/pushed tag.

## Secrets (SEC-005)
Two paths:
- **Manual bootstrap (now):** `cloudnative-pg/create-db-secrets.sh` creates plaintext
  Secrets directly in the cluster. Nothing is committed, so this is safe — use it to get
  running. Skip the kubeseal steps below.
- **GitOps (later):** seal the same Secrets and commit the SealedSecret. Prerequisites:
  install the controller (`helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets
  -n kube-system`) and the `kubeseal` CLI locally.

Either way it is one **basic-auth** Secret per service with **four keys** so the same
secret serves CloudNativePG and the app:

| key | consumed by |
|-----|-------------|
| `username` / `password` | CloudNativePG role (`managed.roles[].passwordSecret`) |
| `DB_USERNAME` / `DB_PASSWORD` | the service (Helm `envSecret` → `envFrom`) |

`username` and `DB_USERNAME` MUST equal the role name (e.g. `booking_user`). Example to
seal (do NOT apply the plaintext form):
```bash
kubectl create secret generic booking-secret -n atlas-data \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=booking_user --from-literal=password='<pw>' \
  --from-literal=DB_USERNAME=booking_user --from-literal=DB_PASSWORD='<pw>' \
  --dry-run=client -o yaml | kubeseal -o yaml > booking-secret.sealed.yaml
```
> Note: the app pods run in `atlas-apps`, so the app-facing secret must also exist there.
> Either replicate the secret into both namespaces or keep a separate app secret in
> `atlas-apps`; decide when wiring Phase 5.

## Validation gates
- `kubectl get ns` shows the three namespaces.
- ingress-nginx Service has an EXTERNAL-IP.
- `cluster/atlas-pg` is Ready; `kubectl get database -n atlas-data` lists all 9.
- (4b) `kafka/atlas` Ready; Keycloak Ready and `/realms/atlas` reachable in-cluster.

## Open inputs (decide before/while applying)
- `storageClass` for CNPG (`oci-bv` assumed — verify with `kubectl get storageclass`).
- Object-storage bucket + creds for Postgres backups (commented in `cluster.yaml`).
- Keycloak external hostname/TLS for the realm issuer (Phase 4b).
- CloudNativePG version ≥ 1.24 for the `Database` CRD.
