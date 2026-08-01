# Deployment troubleshooting

Known issues (and fixes) hit while **provisioning a cluster** or **deploying the platform**.
Every entry has a stable ID (`TS-<AREA>-NN`) so you can jump to it, and so docs elsewhere
can point at the exact case. Entries follow the same shape — **Symptom → Cause → Fix**.

> Adding a case? Give it the next free ID in its area, add a row to the index, and keep the
> **Symptom → Cause → Fix** shape. Never renumber existing IDs (links point at them).

## Index

| ID | Area | Issue |
|----|------|-------|
| [TS-CIVO-01](#ts-civo-01--civo-kubectl-cannot-connect-empty-kubeconfig-or-stale-ip-after-a-recreate) | Civo | `kubectl` cannot connect — empty kubeconfig (`localhost:8080 refused`) **or** stale IP after a recreate (`i/o timeout`) |
| [TS-CIVO-02](#ts-civo-02--civo-a-pod-is-stuck-in-containercreating-failedcreatepodsandbox) | Civo | A pod is stuck in `ContainerCreating` for minutes (`FailedCreatePodSandBox`) — a bad node |
| [TS-CIVO-03](#ts-civo-03--civo-leftover-csi-volumes-or-recovering-a-dirty-terraform-state) | Civo | Leftover `pvc-*` CSI volumes keep billing after teardown; or a dirty state (network rename / half-applied) — recover with `cluster.sh reset` |
| [TS-OKE-01](#ts-oke-01--oke-terraform-init-provider-version-conflict) | Oracle OKE | `terraform init` — provider version conflict (`~> 6.0` vs `>= 8.19.0`) |
| [TS-OKE-02](#ts-oke-02--oke-terraform-plan-fails-on-bastionoperator-images) | Oracle OKE | `terraform plan` — "Splat of null value" (bastion / operator) |
| [TS-OKE-03](#ts-oke-03--oke-terraform-plan-fails-resolving-the-worker-image) | Oracle OKE | `terraform plan` — worker image "argument must not be null" |
| [TS-OKE-04](#ts-oke-04--oke-kubectl-times-out-on-the-public-api-endpoint-io-timeout) | Oracle OKE | `kubectl` times out on the public API endpoint (`dial tcp …:6443: i/o timeout`) |
| [TS-PLATFORM-01](#ts-platform-01--permission-denied-running-a-sh-script) | Platform | `permission denied` running a `.sh` script |
| [TS-PLATFORM-02](#ts-platform-02--postgres-initdb-pod-stuck-pending-unbound-pvc) | Platform | Postgres `initdb` pod stuck `Pending` — unbound PVC |
| [TS-PLATFORM-03](#ts-platform-03--metrics-server-metrics-api-not-available) | Platform | `kubectl top` / HPA: "Metrics API not available" |
| [TS-PLATFORM-04](#ts-platform-04--keycloak-host-404s-nginx-default-page) | Platform | `keycloak.<IP>.nip.io` returns **404** / `jq: Invalid numeric literal` |
| [TS-PLATFORM-05](#ts-platform-05--invalid_grant-when-requesting-a-token) | Platform | `invalid_grant` / "Invalid user credentials" requesting a token |
| [TS-PLATFORM-06](#ts-platform-06--stateful-pod-stuck-containercreating-with-a-bound-pvc) | Platform | Stateful pod stuck `ContainerCreating` with a **Bound** PVC |
| [TS-PLATFORM-07](#ts-platform-07--kafka-has-no-broker-pods-and-no-status) | Platform | Kafka has **no broker pods** and no status; services log `node -1` timeouts |
| [TS-PLATFORM-08](#ts-platform-08--keycloak-restarts-forever-exit-code-137) | Platform | Keycloak restarts forever, exit code **137**, never becomes Ready |
| [TS-PLATFORM-09](#ts-platform-09--password-authentication-failed-for-user-svc_user-across-services) | Platform | `password authentication failed for user "<svc>_user"` across many services (rotated DB secrets) |
| [TS-PLATFORM-10](#ts-platform-10--tempo-crashloops-field-metrics_generator-not-found-in-legacyoverrides) | Platform | Tempo CrashLoops — `field metrics_generator not found in type overrides.LegacyOverrides` |
| [TS-APPS-01](#ts-apps-01--four-services-have-no-pods-after-a-helm-upgrade) | Apps | Four services have **no pods at all** after `helm upgrade` |
| [TS-APPS-02](#ts-apps-02--pods-stuck-containercreating-or-imagepullbackoff-for-minutes) | Apps | Pods stuck `ContainerCreating` / `ImagePullBackOff` for minutes |
| [TS-APPS-03](#ts-apps-03--startup-probe-failed-warnings-while-a-service-boots) | Apps | `Startup probe failed` warnings while a service boots |
| [TS-APPS-04](#ts-apps-04--401-on-every-authenticated-call) | Apps | `401` on every authenticated call, or the issuer host does not resolve |
| [TS-APPS-05](#ts-apps-05--keda-scaledobject-rejected-workload-already-managed-by-an-hpa) | Apps | KEDA ScaledObject rejected — *workload already managed by the hpa* |
| [TS-ARGO-01](#ts-argo-01--app-outofsync-or-degraded) | Argo CD | App **OutOfSync** or **Degraded** after a wave |
| [TS-ARGO-02](#ts-argo-02--crd-before-cr-no-matches-for-kind) | Argo CD | CR wave fails: `no matches for kind …` (CRD-before-CR) |
| [TS-ARGO-03](#ts-argo-03--app-stuck-progressing-on-a-stateful-cr) | Argo CD | App stuck **Progressing** on a stateful CR |
| [TS-ARGO-04](#ts-argo-04--oversized-crd-serversideapply) | Argo CD | Oversized CRD sync fails: annotation too long |
| [TS-ARGO-05](#ts-argo-05--ingress-patch-fails-with-x509-certificate-signed-by-unknown-authority) | Argo CD | Ingress apply/patch fails: `x509: certificate signed by unknown authority` (empty webhook caBundle) |
| [TS-ARGO-06](#ts-argo-06--kafka-never-comes-up-strimzi-crashloops-or-the-kafka-cr-wont-apply) | Argo CD | Kafka never comes up — Strimzi CrashLoopBackOff (`emulationMajor`) or the Kafka CR won't apply (`v1` vs `v1beta2`) |
| [TS-ARGO-07](#ts-argo-07--apps-stuck-syncunknown-with-comparisonerror--terminatingreplicas) | Argo CD | Apps stuck `SYNC=Unknown` — `ComparisonError … .status.terminatingReplicas: field not declared in schema` |
| [TS-ARGO-08](#ts-argo-08--kafka-broker-pvcs-stuck-terminating-kafka-cluster-never-healthy) | Argo CD | Kafka broker PVCs stuck `Terminating`, `kafka-cluster` never Healthy (Argo prunes Strimzi PVCs) |

---

## Cluster provisioning

### TS-CIVO-01 — Civo: `kubectl` cannot connect (empty kubeconfig, or stale IP after a recreate)

**Symptom.** `kubectl get nodes` fails, in one of two ways:

- **A — empty kubeconfig.** `terraform apply` succeeds and prints `api_endpoint`, but
  `terraform output -raw kubeconfig > ~/.kube/civo-atlas.yaml` writes an **empty** file, and
  kubectl fails with `The connection to the server localhost:8080 was refused` (kubectl's
  default when it has no usable kubeconfig).
- **B — stale IP after a recreate.** You `destroy`ed and re-`apply`ed the cluster (the
  documented "off when idle" workflow), and now kubectl hangs then fails with
  `dial tcp <old-ip>:6443: i/o timeout`. The kubeconfig is **valid but points at the previous
  cluster's API IP** — Civo assigns a new `master_ip` on every recreate.

**Cause.**
1. The Civo Terraform provider's `kubeconfig` attribute can come back **empty right after
   apply** (the control plane is still finalizing when the value is read into state), so the
   file you write is empty. It is also **only populated at create time** — on a state that has
   since been refreshed or re-applied, `terraform output -raw kubeconfig` returns **empty**, so
   it can't be used to recover a stale kubeconfig either.
2. `civo kubernetes config … --save` **merges into `~/.kube/config`**, but if you exported
   `KUBECONFIG` to the empty `civo-atlas.yaml`, kubectl keeps reading that empty file — the
   env var wins over `~/.kube/config`.
3. A recreated cluster gets a **new API server IP**, but your saved kubeconfig (and any
   `atlas-civo` context in `~/.kube/config`) still holds the old one → `i/o timeout`.

The fix is the same for both: **re-fetch the kubeconfig from Civo** (never reuse the old file,
and don't rely on `terraform output` here).

> **The happy path already handles this.** `deploy/cluster/civo/terraform/save-kubeconfig.sh`
> (used by the Quick start and by `ops/civo/cluster.sh up`) tries `terraform output` and, when it
> comes back empty, **automatically falls back to the Civo CLI** — so a normal run never lands
> here. Reach for the manual steps below only if that script itself failed (e.g. the Civo CLI
> isn't installed or authenticated).

**Fix.** Fetch the kubeconfig with the Civo CLI **to stdout** (not `--save`) and point
`KUBECONFIG` at that file:

```bash
# 1. Save your API key and make it the current one (the token, not the literal word).
civo apikey save atlas "$CIVO_TOKEN" && civo apikey current atlas
civo apikey ls                                    # confirm it's saved and current

# 2. Confirm the cluster is ACTIVE and note its region.
civo kubernetes list --region nyc1                # region = whatever you set in tfvars, LOWERCASE

# 3. Dump the kubeconfig straight to the file, then point kubectl at it.
civo kubernetes config atlas-civo --region nyc1 > ~/.kube/civo-atlas.yaml
head -5 ~/.kube/civo-atlas.yaml                   # must show YAML: apiVersion / clusters / server
grep server: ~/.kube/civo-atlas.yaml              # after a recreate: confirm it's the NEW api_endpoint IP
export KUBECONFIG=~/.kube/civo-atlas.yaml
kubectl get nodes                                 # expect 3 Ready nodes
```

**Notes.**
- **The CLI region is case-sensitive and lowercase** (`nyc1`, `lon1`, …) even though
  `terraform.tfvars` accepts `NYC1`. Passing `--region NYC1` fails with
  `database_region_not_found`. Confirm the code with `civo region ls`.
- Use the real key or `$CIVO_TOKEN` **with the `$`** — `civo apikey save atlas CIVO_TOKEN`
  stores the literal string and every later call fails auth.
- Prefer the `> file` redirect over `--save`: `--save` merges into `~/.kube/config` and
  collides with an exported `KUBECONFIG`.
- Always `head -5` the file to confirm it has YAML before running `kubectl`.
- **A brand-new terminal times out on the OLD IP?** `export KUBECONFIG` is **per-shell** — a fresh
  terminal without it falls back to `~/.kube/config`, whose `atlas-civo` context still holds a
  *previous* cluster's API IP (the `> file` / `--local-path` forms never updated it). Either
  `export KUBECONFIG=~/.kube/civo-atlas.yaml` in that shell, or refresh the default context once so
  plain `kubectl` works everywhere: `civo kubernetes config atlas-civo --save --region nyc1`
  (no `--local-path`, so it merges into `~/.kube/config`).
- **Foolproof fallback:** Civo Dashboard → your cluster → **Download Config**, then
  `export KUBECONFIG=<downloaded-file>`.

### TS-CIVO-02 — Civo: a pod is stuck in `ContainerCreating` (`FailedCreatePodSandBox`)

**Symptom.** A pod never starts — `kubectl -n <ns> get pods` shows it `ContainerCreating` (or
`Init:0/1`) for **many minutes**, and `bootstrap.sh` fails on the Argo CD wait with
`context deadline exceeded`. Its events repeat:

```
Warning  FailedCreatePodSandBox  ...  code = DeadlineExceeded desc = context deadline exceeded
Warning  FailedCreatePodSandBox  ...  code = FailedPrecondition desc = failed to reserve sandbox name "..." is reserved for "..."
```

**Cause.** One worker node came up with a **broken container runtime** — its `containerd`
can't create the pod sandbox (network namespace + CNI), so every pod the scheduler places
there hangs. The `DeadlineExceeded` is the first attempt timing out; the `reserved for …`
lines are the retries colliding with that stuck first attempt. It is **not** a slow image
pull (those clear on their own in a minute or two) and **not** the RFC 1123 host bug
([the `<cluster-ip>` placeholders are already fixed to valid IPs](../argocd/install/argocd-values.yaml)).
A node coming up unhealthy is a provisioning flake — it can happen on any fresh cluster.

**Confirm it's one bad node.** Every stuck pod will be on the **same** node; the healthy pods
are all elsewhere:

```bash
kubectl get pods -A -o wide | grep -E 'ContainerCreating|Init:' | awk '{print $8}' | sort -u
#   → all rows show ONE node name = that node is the bad one
kubectl get nodes                                  # it still reports Ready — the runtime lies
```

**Fix — recycle just that node** (Civo replaces the instance, ~2–4 min; the other two stay up):

```bash
BADNODE=<the node name from above>
civo kubernetes recycle atlas-civo --node "$BADNODE" --region nyc1   # region LOWERCASE (see TS-CIVO-01)
kubectl get nodes -w                               # old node leaves, a fresh one joins Ready
```

Then re-run the step that failed — `bootstrap.sh` is idempotent, so just run it again; the
pods now schedule onto healthy nodes and the images are already cached cluster-wide, so it
comes up fast. (If the release is wedged from an earlier failed attempt:
`helm uninstall argocd -n argocd` first, wait for the `argocd` namespace pods to clear, then
re-run.)

> **Whole cluster looks wrong, not just one node?** Then it isn't this — `terraform destroy &&
> terraform apply` for a clean slate is the bigger hammer, but a single bad node never needs it.

### TS-CIVO-03 — Civo: leftover CSI volumes, or recovering a dirty Terraform state

**Symptom.** After a teardown, `civo volume ls` still shows `pvc-*` volumes quietly billing. Or,
if you are on an **old** state that still managed a dedicated network, `terraform apply` fails with
`[ERR] An error occurred while renaming the network`, or `terraform destroy` fails with
`DatabaseNetworkInUseByVolumes: … Please delete the volumes first …`.

**Cause.** The stack's stateful pods (the 3 Kafka brokers, Postgres, Loki, Tempo, Prometheus) each
get a **Civo block volume** from the CSI driver — one `pvc-*` volume per PVC. Terraform never
created them, so it can't delete them; they outlive the cluster and keep billing until swept.

The current Terraform **no longer manages a network** — the cluster and firewall run on Civo's
**default network** (see the NETWORK note in
[`cluster/civo/terraform/main.tf`](./cluster/civo/terraform/main.tf)). Terraform therefore never
tries to delete a network, so those orphaned volumes **can't block a destroy** anymore, and the old
"rename network" / `DatabaseNetworkInUseByVolumes` failures can't recur. Both symptoms above are
the legacy managed-network design; a state created before that change still carries a
`civo_network`, which is exactly what leaves things stuck.

**Fix — normal case (just orphaned volumes):** `./deploy/ops/civo/cluster.sh down` releases the
PVCs while the cluster is still reachable and then sweeps any leftovers. To sweep by hand (region
LOWERCASE — see TS-CIVO-01):

```bash
# Dangling = attached to nothing, safe to delete. NEVER a bare `-f id` without a filter.
civo volume ls --region nyc1 --dangling -o custom -f id \
  | while read -r id; do [ -n "$id" ] && civo volume delete "$id" --region nyc1 -y; done
```

**Fix — dirty / half-applied state** (the rename error, an old `civo_network` in state, or a
teardown that half-completed): run the idempotent recovery, then bring it back up:

```bash
cd deploy/ops/civo
export CIVO_TOKEN=...          # if not already exported
./cluster.sh reset            # sweeps volumes, removes leftover cluster/firewall/legacy network, wipes local state
./cluster.sh up               # rebuilds firewall + cluster from zero on the default network
```

> **Prevent it:** always tear down with `./deploy/ops/civo/cluster.sh down` (not a bare
> `terraform destroy`) so the PVCs are released while the cluster is still reachable — fix a stale
> kubeconfig (TS-CIVO-01) first so `kubectl` can reach it. If you ever land in a stuck state,
> `./cluster.sh reset` gets you back to a clean slate without touching Terraform.

### TS-OKE-01 — OKE: `terraform init` provider version conflict

**Symptom.** `init` fails: `no available releases match the given constraints … ~> 6.0 …
>= 8.19.0` for `oracle/oci`.

**Cause.** The OKE module requires `oci >= 8.19.0`; an older pin (`~> 6.0`) can never satisfy it.

**Fix.** Pin the provider to `~> 8.0` in
[`oracle/terraform/providers.tf`](./cluster/oracle/terraform/providers.tf) (already set).

### TS-OKE-02 — OKE: `terraform plan` fails on bastion/operator images

**Symptom.** `plan` errors in `module-bastion.tf` / `module-operator.tf` with
`Splat expressions cannot be applied to null sequences` (`local.bastion_images is null`).

**Cause.** The OKE module creates a **bastion** and an **operator** host by default and
fails to resolve their images.

**Fix.** The lab uses a **public** API endpoint, so neither host is needed — they are
already disabled in [`oracle/terraform/main.tf`](./cluster/oracle/terraform/main.tf):
`create_bastion = false`, `create_operator = false`. If you re-enable them, you must supply
their images.

### TS-OKE-03 — OKE: `terraform plan` fails resolving the worker image

> **Default is auto-resolve — leave `worker_image_id` unset.** Current `oci` providers
> (verified on **8.24.0**, 2026-07-22) resolve the OKE node image from `kubernetes_version`
> correctly. `worker_image_id` is an **optional fallback**, not a required input. The two
> symptoms below are (A) older providers that returned an empty image list, and (B) the
> mismatch you get when you *do* pin an OCID that doesn't match your k8s version.

**Symptom A (empty resolution — older providers).** `plan` errors in
`modules/workers/locals.tf`: `Invalid value for "other_sets" parameter: argument must not be
null`, with `var.image_ids is object with 6 attributes`. Changing `kubernetes_version`
doesn't help.

**Cause A.** The module resolves the worker OKE image via a data source whose `sources`
attribute came back **empty on older `oci` provider builds** — so no version-keyed image was
ever found. This is fixed on current providers; if you hit it, upgrade the provider first
(`terraform init -upgrade`) before reaching for the fallback below.

**Symptom B (version mismatch — you pinned an OCID).** `apply` fails creating the node pool:
`409-Conflict, Kubernetes version does not match Kubernetes version of OKE worker node image
(v1.34.2)`.

**Cause B.** `worker_image_id` is set to a node image built for a **different** k8s version
than `kubernetes_version` (e.g. a `v1.34.2` image against a `v1.36.0` cluster). The image
carries its k8s version and OCI rejects the mismatch.

**Fix.**

- **Preferred:** leave `worker_image_id` unset (commented out) and let the module
  auto-resolve the image that matches `kubernetes_version`. This makes the mismatch
  impossible by construction.
- **Only if auto-resolution returns empty on your provider/region:** pass an explicit
  node-image OCID, picking the `OKE-<version>` **x86_64, non-GPU** entry whose version
  **equals** `kubernetes_version`:

```bash
oci ce node-pool-options get --node-pool-option-id all \
  --query 'data.sources' --output table
```
```hcl
# terraform.tfvars
kubernetes_version = "v1.34.2"
worker_image_id    = "ocid1.image.oc1.iad.aaaa..."   # OKE-1.34.2 x86_64 non-GPU (must match)
```

---

### TS-OKE-04 — OKE: `kubectl` times out on the public API endpoint (`i/o timeout`)

**Symptom.** `apply` succeeds and `oci ce cluster create-kubeconfig` merges the config, but
every `kubectl` call hangs ~30s and fails:

```
E… memcache.go:265] couldn't get current server API group list: Get "https://<ip>:6443/api?timeout=32s": dial tcp <ip>:6443: i/o timeout
Unable to connect to the server: dial tcp <ip>:6443: i/o timeout
```

**Cause.** The control plane endpoint is public, but the OKE module's
`control_plane_allowed_cidrs` defaults to `[]` — so its NSG has **no ingress rule** for
TCP 6443 and drops every connection. A public endpoint is not the same as an *open* one.

**Fix.** Allow-list the CIDRs that may reach 6443 via the `control_plane_allowed_cidrs`
input (wired through `main.tf` → the module). The Atlas config defaults it to `["0.0.0.0/0"]`,
so a plain re-apply opens it:

```bash
terraform apply            # adds the 6443 ingress rule to the control-plane NSG
kubectl get nodes          # now reachable
```

To restrict it to your workstation instead of the whole internet, set your public IP in
`terraform.tfvars` and re-apply (update it whenever your IP changes):

```hcl
# terraform.tfvars
control_plane_allowed_cidrs = ["203.0.113.4/32"]   # curl -s ifconfig.me
```

> The endpoint is always behind OCI-signed token auth + TLS, so `0.0.0.0/0` is authenticated,
> not anonymous — but a `/32` is the smaller attack surface for anything beyond a lab.

---

## Platform deployment

### TS-PLATFORM-01 — `permission denied` running a `.sh` script

**Symptom.** Running a helper script fails, e.g.:
```
./deploy/platform/cloudnative-pg/create-db-secrets.sh
zsh: permission denied: ./deploy/platform/cloudnative-pg/create-db-secrets.sh
```

**Cause.** The script's **executable bit** isn't set. Git does track it (mode `100755`), but
it can be lost when the repo is downloaded as a ZIP or unpacked on a filesystem that drops
Unix permissions.

**Fix.** Either run it through the interpreter (works regardless of the bit) —

```bash
bash deploy/platform/cloudnative-pg/create-db-secrets.sh
```

— or set the bit once (then `./…` works). For a single script:

```bash
chmod +x deploy/platform/cloudnative-pg/create-db-secrets.sh
```

For all repo scripts at once (skips the downloaded Terraform modules):

```bash
find . -name '*.sh' -not -path '*/.terraform/*' -exec chmod +x {} +
```

### TS-PLATFORM-02 — Postgres `initdb` pod stuck `Pending` (unbound PVC)

**Symptom.** After Step 3, `kubectl wait … cluster/atlas-pg …` times out and:
```
kubectl get pods -n atlas-data
NAME                      READY   STATUS    ...
atlas-pg-1-initdb-xxxxx   0/1     Pending
kubectl describe pod atlas-pg-1-initdb-xxxxx -n atlas-data
  Warning  FailedScheduling  …  0/3 nodes are available: pod has unbound immediate PersistentVolumeClaims.
```

**Cause.** The PVC can't be provisioned — either the cluster has **no default StorageClass**,
or a manifest pins a `storageClass` **name that doesn't exist on this cloud** (e.g. `oci-bv`
on a Civo cluster).

**Fix.** Check what you have, then make the manifest use a class that exists:

```bash
kubectl get storageclass                 # need one marked (default), e.g. civo-volume on Civo
kubectl get pvc -n atlas-data            # the PVC shows STATUS=Pending and its STORAGECLASS
```

The shipped manifests leave `storageClass` **unset** so they use the cluster's default — if
yours has a default, that just works. If your cluster has **no default**, either mark one:

```bash
kubectl patch storageclass <name> \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

…or set an existing class explicitly in `deploy/platform/cloudnative-pg/cluster.yaml` (and
`strimzi/kafka.yaml`).

> ⚠️ **CloudNativePG retains the PVC when you delete the Cluster.** So `kubectl delete cluster`
> alone is **not enough** — the old PVC (still Pending, still bound to the bad class) survives
> and gets **reused** on re-apply, leaving you stuck on the same pod. You must delete the PVC
> too. A PVC's `storageClass` is immutable, hence the full recreate:

```bash
kubectl delete cluster atlas-pg -n atlas-data
kubectl delete pvc atlas-pg-1 -n atlas-data   # the retained PVC — this is the easy-to-miss step
kubectl get pods,pvc -n atlas-data            # confirm nothing is left
kubectl apply -f deploy/platform/cloudnative-pg/cluster.yaml
kubectl wait --for=condition=Ready cluster/atlas-pg -n atlas-data --timeout=300s
```

> **If you had already applied `databases.yaml`** (Step 3c) against the old cluster, its
> `Database` objects get stuck showing `APPLIED=false` /
> `cluster resource has been deleted, skipping reconciliation` — they don't re-reconcile
> against the recreated cluster on their own. Re-apply them (safe — no DB existed on the
> failed cluster):
> ```bash
> kubectl delete -f deploy/platform/cloudnative-pg/databases.yaml
> kubectl apply  -f deploy/platform/cloudnative-pg/databases.yaml
> kubectl get database -n atlas-data          # APPLIED should flip to true
> ```

### TS-PLATFORM-03 — metrics-server: Metrics API not available

**Symptom.** After installing metrics-server (observability prerequisite), `kubectl top pods`
fails:
```
error: Metrics API not available
```

**Cause.** On managed / k3s clusters (Civo, OKE, …) the kubelet's serving certificate isn't
signed by the cluster CA, so metrics-server can't scrape kubelets over TLS and never
publishes metrics. (It can also simply need ~30–60 s after install to register.)

**Fix.** Tell metrics-server to skip kubelet cert verification, then give it a moment:
```bash
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top pods -n atlas-apps          # give it ~30–60 s to populate
```

Confirm the cause if unsure: `kubectl -n kube-system logs deploy/metrics-server | tail` —
`x509` / certificate errors point at the kubelet-TLS issue.

### TS-PLATFORM-04 — Keycloak host 404s (nginx default page)

**Symptom.** The public Keycloak host answers with a plain nginx 404, and any command that
pipes that response into `jq` fails on the HTML:

```
$ curl -I http://keycloak.<LB-IP>.nip.io/realms/atlas/.well-known/openid-configuration
HTTP/1.1 404 Not Found
Content-Type: text/html
Content-Length: 146

$ TOKEN=$(curl -s .../token ... | jq -r .access_token)
jq: parse error: Invalid numeric literal at line 1, column 7
```

**Cause.** No Ingress rule matches that host, so ingress-nginx serves its default backend.
Two independent reasons, and you can have both:

1. `deploy/platform/keycloak/keycloak-ingress.yaml` was never applied.
2. It *was* applied, but with the literal placeholder still in it. Both
   `keycloak.yaml` (`spec.hostname`) and `keycloak-ingress.yaml` (`spec.rules[].host`) ship
   with `keycloak.<cluster-ip>.nip.io` — `<cluster-ip>` is a placeholder, not a variable
   Kubernetes resolves.

The `jq` error is only a symptom: `jq` is being handed `<html>`, and `<` is not valid JSON.

**Fix.** Substitute in the pipe so the public IP never lands in git, then re-apply both:

```bash
LB=<EXTERNAL-IP>          # ingress-nginx EXTERNAL-IP, Runbook Step 2
sed "s/<cluster-ip>/$LB/g" deploy/platform/keycloak/keycloak.yaml         | kubectl apply -f -
sed "s/<cluster-ip>/$LB/g" deploy/platform/keycloak/keycloak-ingress.yaml | kubectl apply -f -
kubectl -n atlas-system rollout status statefulset/keycloak

# verify: the host must appear with the real IP, and master must answer 200
kubectl get ingress -n atlas-system
curl -sI http://keycloak.$LB.nip.io/realms/master/.well-known/openid-configuration | head -1
```

`deploy/platform/kafka/kafka-ui-ingress.yaml` carries the same placeholder — same fix.

### TS-PLATFORM-05 — `invalid_grant` when requesting a token

**Symptom.** The realm exists and the token endpoint answers, but no token is issued:

```json
{ "error": "invalid_grant", "error_description": "Invalid user credentials" }
```

**Cause.** The realm import creates `atlas-user` and `atlas-admin` **without passwords** —
that is deliberate, so no credential is ever committed. Runbook Step 5b sets them in a
separate step (`set-realm-passwords.sh`). Until that script runs successfully, the users
exist but cannot authenticate.

That the endpoint replies with well-formed JSON is useful information: the realm, the
`atlas-web` client and direct access grants are all working. Only the password is wrong.

**Fix.** Work down this list — the first two cover almost every case:

1. **The script never ran, or ran against a different cluster.** Re-run it; it is idempotent.
   ```bash
   LB=<EXTERNAL-IP> ./deploy/platform/keycloak/set-realm-passwords.sh
   ```
2. **Your shell variable is empty.** `$PW` does not survive a new terminal tab, and an empty
   password produces this exact error. Check before anything else:
   ```bash
   echo "PW=[$PW]"
   ```
3. **You deleted `temp-admin` (Step 5a) and the script cannot authenticate.** It defaults to
   the bootstrap admin. Pass your permanent one:
   ```bash
   KEYCLOAK_ADMIN_USER=<your-admin> KEYCLOAK_ADMIN_PASSWORD=<pw> \
     LB=<EXTERNAL-IP> ./deploy/platform/keycloak/set-realm-passwords.sh
   ```
4. **The users do not exist.** The script says so explicitly. Check the import actually ran:
   ```bash
   kubectl -n atlas-system get keycloakrealmimport atlas-realm \
     -o go-template='{{range .status.conditions}}{{.type}}={{.status}} {{end}}{{"\n"}}'
   ```
   Note that re-applying the manifest will **not** recreate a realm that already exists — see
   the warning in Runbook Step 5b for how to delete and re-import.

Verify with the token request in Runbook Step 5b. A different error means a different
problem: `unauthorized_client` is direct access grants disabled on the client, and
`HTTPS required` is the realm's `sslRequired` not being `none`.

### TS-PLATFORM-06 — Stateful pod stuck `ContainerCreating` with a Bound PVC

**Symptom.** A pod with a persistent volume (`loki-0`, `tempo-0`, `prometheus-…-0`,
`atlas-pg-…`) sits in `ContainerCreating` for tens of minutes. Everything that usually
explains it looks fine: the PVC is **`Bound`**, nodes are `Ready` with plenty of free CPU and
memory, and there are no recent `FailedScheduling` events. `describe pod` shows:

```
Warning  FailedMount  kubelet  MountVolume.MountDevice failed for volume "pvc-…" :
  kubernetes.io/csi: attacher.MountDevice failed to create newCsiDriverClient:
  driver name csi.civo.com not found in the list of registered CSI drivers
Warning  FailedMount  kubelet  MountVolume.MountDevice failed for volume "pvc-…" :
  rpc error: code = NotFound desc = path to volume (/dev/disk/by-id/…) not found
```

**Cause.** The CSI **node** plugin on that node restarted while the pod was being placed
there. Check it — a non-zero restart count whose age matches the stuck pod's age is the
tell:

```bash
kubectl -n kube-system get pods -o wide | grep csi
```

The pod was scheduled while the driver was unregistered (first message), and afterwards the
attachment desynchronised: the control plane records the volume as attached, so the
controller will not re-attach it, while the block device never appeared on the node (second
message). Neither side breaks the tie on its own, so it waits forever.

Note this is **not** the multi-attach case. A `Multi-Attach error for volume … already
exclusively attached to one node` means something different — the volume is genuinely in use
elsewhere, and forcing a detach there risks corruption.

**Fix.** Escalate only as far as needed; stop as soon as the pod goes `Running`.

1. **Restart the node plugin and reschedule the pod.** Cheapest, and usually enough.
   ```bash
   kubectl -n kube-system delete pod <csi-node-pod-on-that-node>
   kubectl -n <ns> delete pod <stuck-pod>
   ```
2. **Delete the stale `VolumeAttachment`.** Safe *in this specific case*: the error says the
   device does not exist on the node, so nothing is mounted and no process is writing.
   ```bash
   kubectl get volumeattachment -o custom-columns=\
   NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName,ATTACHED:.status.attached
   kubectl delete volumeattachment <name>
   kubectl -n <ns> delete pod <stuck-pod>
   ```
3. **Recreate the PVC** — only when the volume holds nothing worth keeping (a Loki or Tempo
   that never started). Never for Postgres, and think twice for a Prometheus that has been
   collecting.
   ```bash
   kubectl -n <ns> delete pvc <pvc-name>
   kubectl -n <ns> delete pod <stuck-pod>
   ```
4. **Steer the pod to a different node.** If the same node keeps failing, its CSI plugin is
   the problem, not the volume:
   ```bash
   kubectl cordon <node>
   kubectl -n <ns> delete pod <stuck-pod>
   kubectl uncordon <node>          # once the pod is Running elsewhere
   ```

**Why it is easy to misdiagnose.** A `Bound` PVC and healthy nodes make this look like slow
image pulls ([TS-APPS-02](#ts-apps-02--pods-stuck-containercreating-or-imagepullbackoff-for-minutes))
or a scheduling problem. The distinguishing signal is `FailedMount` in the pod's events —
always read those before reasoning about capacity.

### TS-PLATFORM-07 — Kafka has no broker pods and no status

**Symptom.** Every service logs what looks like a network problem:

```
Disconnecting from node -1 due to socket connection setup timeout
Bootstrap broker atlas-kafka-bootstrap.atlas-data:9092 (id: -1 rack: null) disconnected
```

It is not the network. There is no broker behind the Service:

```bash
$ kubectl -n atlas-data get endpoints atlas-kafka-bootstrap
NAME                    ENDPOINTS   AGE
atlas-kafka-bootstrap   <none>      26h

$ kubectl -n atlas-data get kafka atlas
NAME    READY   WARNINGS   KAFKA VERSION   METADATA VERSION
atlas                                                          # every column empty
```

Note what is *not* wrong: the `KafkaNodePool` exists with the right replica count, the PVCs
exist, and the operator is `Running`. Only the broker pods are missing — there are none, not
even `Pending`.

**Cause.** The operator aborted reconciliation before creating the pods, and Strimzi's
reconciliation is all-or-nothing: a bad reference anywhere in the `Kafka` CR stops the whole
thing, leaving the Services and PVCs it had already created. The empty status columns are the
tell — a status means the operator got through; no status means it never did.

The CR carries the reason. Read it before anything else:

```bash
kubectl -n atlas-data describe kafka atlas | sed -n '/Status:/,$p'
kubectl -n atlas-data logs deploy/strimzi-cluster-operator --tail=50 | grep -iE "error|invalid"
```

The most common reason is a missing `kafka-metrics` ConfigMap, referenced by
`spec.kafka.metricsConfig` in `strimzi/kafka.yaml`:

```
InvalidConfigurationException: ConfigMap kafka-metrics does not exist
```

**Fix.** Apply the ConfigMap; the operator retries on its own timer (every ~2 min) and
proceeds to create the brokers. Nothing needs deleting.

```bash
kubectl apply -f deploy/platform/strimzi/kafka-metrics-configmap.yaml
kubectl -n atlas-data get pods -l strimzi.io/cluster=atlas -w
kubectl wait --for=condition=Ready kafka/atlas -n atlas-data --timeout=600s
```

The `data-0-atlas-dual-role-*` PVCs sitting in `Pending` are **not** a second problem — the
default StorageClass binds on first consumer, so they stay `Pending` until the broker pods
they belong to exist, then bind normally.

For any other `Reason` in the conditions, fix what it names and wait for the next
reconciliation. The consumer-side timeouts clear on their own once the brokers are up.

### TS-PLATFORM-08 — Keycloak restarts forever, exit code 137

**Symptom.** `keycloak-0` never reaches `1/1`, the restart count climbs steadily, and the log
is always the same two lines — it never gets further:

```
Changes detected in configuration. Updating the server image.
Updating the configuration and installing your custom providers, if any. Please wait.
```

```bash
$ kubectl -n atlas-system describe pod keycloak-0 | grep -A5 "Last State"
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
      Started:      ... 22:42:07
      Finished:     ... 22:52:40      # ~10 minutes, every time
```

**Cause.** On first start — and after any configuration change, such as setting the public
hostname — Keycloak runs a Quarkus augmentation to rebuild its server image. That build is
CPU-bound. The operator's startup probe allows `periodSeconds: 1 × failureThreshold: 600` =
**600 seconds**; when the build does not finish inside it, kubelet SIGKILLs the container
(137, with `Reason: Error` rather than `OOMKilled`). The replacement pod has no persisted
build, so it starts the same augmentation from scratch. Nothing converges.

The ~10½-minute gap between `Started` and `Finished` is the signature: it is the probe budget,
not the workload.

**Fix.** `deploy/platform/keycloak/keycloak.yaml` sets a CPU request precisely to prevent
this — the operator's own defaults specify memory only, leaving CPU unreserved so the pod is
starved under contention. Confirm yours has it:

```bash
kubectl -n atlas-system get keycloak keycloak -o jsonpath='{.spec.resources}' ; echo
```

If it is empty you are running an older manifest — re-apply the current one (Runbook Step 5).

If the request is there and it still loops, the node cannot deliver the CPU. Check node
health ([Runbook Step 0](../DEPLOYMENT-RUNBOOK.md#node-health--run-this-now-and-again-whenever-something-is-inexplicably-stuck))
and move the pod off a degraded node — Keycloak has no PVC of its own (its state lives in
Postgres), so relocating it is cheap:

```bash
kubectl cordon <bad-node>
kubectl -n atlas-system delete pod keycloak-0
kubectl uncordon <bad-node>       # once it is Running elsewhere
```

**Not this.** `Reason: OOMKilled` instead of `Error` is a memory problem, not this one — raise
`spec.resources.limits.memory`. A log that gets past those two lines and then fails is also
something else; read it.

### TS-PLATFORM-09 — `password authentication failed for user "<svc>_user"` across services

**Symptom.** Several services (and Keycloak) crash or log, against their own database:

```
FATAL: password authentication failed for user "booking_user"
FATAL: password authentication failed for user "keycloak_user"
```

It hits many `*_user` roles at once, and it starts after you **re-ran `bootstrap.sh`** (or
`create-db-secrets.sh`) on an existing cluster.

**Cause.** The per-service DB passwords live in Secrets that CloudNativePG uses to set each
managed role's password (`passwordSecret` in `cluster.yaml`) and that the services read via
`envFrom`. An **old** `create-db-secrets.sh` generated a **new random password on every run** and
`kubectl apply`-ed it. But CNPG does **not** reliably re-apply a managed role's password when only
the Secret changed — it stays on the password from when the role was first created. So a re-run
rotates the Secret (and the service env on the next pod start) while the Postgres **role keeps the
old password** → auth fails everywhere at once. (The script is now idempotent — it reuses an
existing Secret's password — so a fresh clone won't do this. This entry is for a cluster already
knocked out of sync.)

**Confirm.** The current Secret's password does not authenticate as the role:

```bash
PW=$(kubectl -n atlas-data get secret booking-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n atlas-data exec atlas-pg-1 -c postgres -- env PGPASSWORD="$PW" \
  psql -h 127.0.0.1 -U booking_user -d booking_db -c 'select 1'   # FATAL: password authentication failed
# CNPG shows it reconciled an OLD secret resourceVersion, far below the Secret's current one:
kubectl -n atlas-data get cluster atlas-pg -o jsonpath='{.status.managedRolesStatus.passwordStatus}'
```

**Fix — realign every role to the Secret it should match, then restart the consumers** so they
re-read the env:

```bash
PAIRS="user_user:user-secret flight_user:flight-secret hotel_user:hotel-secret \
inventory_user:inventory-secret travel_cart_user:travel-cart-secret booking_user:booking-secret \
payment_user:payment-secret search_user:search-secret keycloak_user:keycloak-db-secret"
SQL=""
for p in $PAIRS; do
  role="${p%%:*}"; secret="${p##*:}"
  pw=$(kubectl -n atlas-data get secret "$secret" -o jsonpath='{.data.password}' | base64 -d)
  SQL="${SQL}ALTER ROLE ${role} WITH LOGIN PASSWORD '${pw}';"$'\n'
done
printf '%s' "$SQL" | kubectl -n atlas-data exec -i atlas-pg-1 -c postgres -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1

kubectl -n atlas-apps   rollout restart deploy
kubectl -n atlas-system rollout restart statefulset keycloak
```

Run it under `bash` (the `${p%%:*}` splitting and `$PAIRS` word-splitting need it — `zsh` won't
split an unquoted variable). The passwords are alphanumeric (the generator strips `/+=`), so the
single-quoted `ALTER ROLE` is safe.

### TS-PLATFORM-10 — Tempo CrashLoops: `field metrics_generator not found in ...LegacyOverrides`

**Symptom.** `obs-tempo` never goes Healthy; `tempo-0` is `CrashLoopBackOff` and its log ends with:

```
module failed module=overrides err="… failed to load runtime config: load file: yaml: unmarshal
errors: line 3: field metrics_generator not found in type overrides.LegacyOverrides
        line 7: cannot unmarshal !!str `/conf/o...` into overrides.LegacyOverrides"
```

Every other module (`querier`, `distributor`, …) then fails "because it depends on module
overrides".

**Cause.** The grafana/tempo chart writes the `tempo.overrides` value **verbatim** into the runtime
per-tenant override file (`/conf/overrides.yaml`), which Tempo parses as `map[tenant]LegacyOverrides`
(a tenant-id → legacy-overrides map). `tempo-values.yaml` had a *new-format* block there —

```yaml
tempo:
  overrides:
    defaults: { metrics_generator: { processors: [service-graphs, span-metrics] } }
    per_tenant_override_config: /conf/overrides.yaml
```

— so Tempo reads `defaults` and `per_tenant_override_config` as two "tenants" whose values aren't
valid `LegacyOverrides`, and crashes. The block was also **redundant**: with
`metricsGenerator.enabled: true`, the chart already sets the default
`overrides.metrics_generator_processors: [service-graphs, span-metrics]` in the *main* config.

**Fix.** Remove the `tempo.overrides` block from
[`tempo-values.yaml`](platform/observability/tempo-values.yaml). The chart then renders a harmless
`overrides: {}` runtime file, the processors stay in the main config, and Tempo starts. Confirm
with a local render (no cluster needed):

```bash
helm template tempo grafana/tempo --version 1.18.2 -f deploy/platform/observability/tempo-values.yaml \
  | grep -A2 'overrides.yaml:'          # must show `overrides:` / `{}`, not a defaults block
```

Because Argo owns this from git, the fix reaches a running cluster only once it's on the branch Argo
syncs. To unstick a cluster **now** without waiting for that: pause auto-sync on `obs-tempo`, patch
the live ConfigMap, and restart the pod —

```bash
kubectl -n argocd patch application obs-tempo --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n atlas-observability patch configmap tempo --type merge -p '{"data":{"overrides.yaml":"overrides: {}\n"}}'
kubectl -n atlas-observability delete pod tempo-0
# re-enable auto-sync AFTER the values fix is pushed, so self-heal doesn't revert to the broken config:
#   kubectl -n argocd patch application obs-tempo --type merge \
#     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## Atlas services

### TS-APPS-01 — Four services have no pods after a `helm upgrade`

**Symptom.** `helm upgrade --install` reports success for all eight services, but
`kubectl get pods -n atlas-apps` shows pods for only four. `inventory`, `booking`, `payment`
and `search` have no pods at all — not `Pending`, not `Failed`, simply absent. Their
Deployments exist and report `0/0`.

**Cause.** Those four are exactly the services with `autoscaling.enabled: true`. The chart
deliberately renders them **without** `spec.replicas` so the HPA owns the replica count. An
HPA cannot scale a Deployment **up from 0** — with no pods it has no per-pod metrics to
average — so once something set them to 0, `helm upgrade` never brings them back: the
manifest it applies has no replica count to restore. `deploy/ops/apps/idle.sh` does exactly
that (`kubectl scale deploy --all --replicas=0`).

**Fix.** Use the resume script instead of re-running the Step 6b loop. It re-runs the same
`helm upgrade`, then nudges every CPU-HPA-managed Deployment to its `minReplicas` and
un-pauses the KEDA ScaledObjects:

```bash
./deploy/ops/apps/resume.sh
kubectl -n atlas-apps get deploy,hpa,scaledobject
```

One-off equivalent, if you only need a single service back:

```bash
kubectl -n atlas-apps scale deploy/booking-service --replicas=2
```

### TS-APPS-02 — Pods stuck `ContainerCreating` or `ImagePullBackOff` for minutes

**Symptom.** On a fresh cluster, app pods sit in `ContainerCreating` for 5–15 minutes, some
flipping through `ImagePullBackOff` first. The pod's events show a `Pulling` line with no
`Pulled` for several minutes:

```
Normal  Pulling  16m   kubelet  Pulling image "ghcr.io/atlas-event-lab/atlas-hotel-service:latest"
Normal  Pulled   8m9s  kubelet  Successfully pulled image ... in 7m53.486s (7m53.486s including waiting)
```

**Cause.** Expected on a cold node, not a fault. Each service image is ~265 MB, and kubelet
**serializes image pulls per node** by default — so eight services landing on one node queue
up behind each other. "including waiting" in the event is that queue. A node that has never
run Atlas pulls the whole set before anything starts.

**Fix.** Wait, and confirm progress rather than restarting things:

```bash
kubectl -n atlas-apps get pods -w
kubectl -n atlas-apps describe pod <pod> | tail -15    # look for Pulling -> Pulled
```

Subsequent deploys are fast — the image layers are cached on the node (pulls drop to
milliseconds). Treat it as a real problem only if you see one of these in the events instead:

| Event message | Meaning |
|---|---|
| `denied` / `unauthorized` | The GHCR package is private. Visibility is **per package**, so some services can work while others fail. Make it public, or add an `imagePullSecrets` entry. |
| `manifest unknown` | The tag does not exist — that repo's CI never published `:latest`. |
| `failed to create pod sandbox` | CNI, not the registry. |
| Node reports `DiskPressure` | The node ran out of room unpacking images. |

If pods land on one node while others sit idle, check the node pool is at full size
(`kubectl get nodes`) — `ops/` cluster-down scripts leave it scaled down.

### TS-APPS-03 — `Startup probe failed` warnings while a service boots

**Symptom.** `describe pod` shows a run of warnings during startup, even though the pod ends
up healthy:

```
Warning  Unhealthy  Startup probe failed: dial tcp 10.42.1.32:9090: connect: connection refused
Warning  Unhealthy  Startup probe failed: HTTP probe failed with statuscode: 503
```

**Cause.** Normal JVM startup, and the two messages are different phases: `connection
refused` is before the actuator port is listening at all; `503` is Spring Boot up but
readiness not yet satisfied. The startup probe budget is `periodSeconds: 5 ×
failureThreshold: 30` = **150 s**, and these warnings are simply the attempts inside it.

**Fix.** None needed — check the pod's current state, not its event history:

```bash
kubectl -n atlas-apps get pod <pod> -o jsonpath='{.status.containerStatuses[0].ready}{"\n"}'
```

`true` with `Restart Count: 0` means it started cleanly. It is a real failure only if the pod
goes `CrashLoopBackOff`, or restarts climb — then read the logs, since exceeding the 150 s
budget usually means the service cannot reach Postgres, Kafka, or the issuer.

### TS-APPS-04 — `401` on every authenticated call

**Symptom.** Services are `Running` and a token is issued, but every authenticated request
returns `401`. Nothing appears wrong at deploy time.

A second, louder variant of the same root cause — the issuer host does not resolve at all, so
the service cannot even fetch the OIDC discovery document:

```
ResourceAccessException: I/O error on GET request for
"http://keycloak.<IP>/realms/atlas/.well-known/openid-configuration": keycloak.<IP>
```

Look closely at that host: `keycloak.212.2.242.83` is **not** `keycloak.212.2.242.83.nip.io`.
Without the `nip.io` suffix there is no DNS name to resolve. The issuer must be the full
public host, exactly as Keycloak's `spec.hostname` has it.

**Cause.** The `iss` claim in the token does not match what the services validate. They read
`KEYCLOAK_ISSUER_URI` from the `atlas-issuer` Secret; Keycloak stamps tokens with its own
`spec.hostname`. The two are set in different places, so they drift — most often after the
LoadBalancer IP changes when a cluster is recreated. The comparison is exact, including
scheme and any port.

**Fix.** Compare both sides, then re-align and restart:

```bash
# what the services expect
kubectl -n atlas-apps get secret atlas-issuer \
  -o jsonpath='{.data.KEYCLOAK_ISSUER_URI}' | base64 -d ; echo
# what Keycloak actually stamps
kubectl -n atlas-system get keycloak keycloak -o jsonpath='{.spec.hostname.hostname}' ; echo
# and what a real token carries
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .iss

LB=<EXTERNAL-IP>
kubectl -n atlas-apps delete secret atlas-issuer
kubectl -n atlas-apps create secret generic atlas-issuer \
  --from-literal=KEYCLOAK_ISSUER_URI="http://keycloak.$LB.nip.io/realms/atlas"
kubectl -n atlas-apps rollout restart deploy      # envFrom is read only at startup
```

---

### TS-APPS-05 — KEDA ScaledObject rejected: *workload already managed by an HPA*

**Symptom.** Applying the ScaledObjects (Runbook Step 8, or Argo wave 9) is refused:

```
Error from server (Forbidden): admission webhook "vscaledobject.kb.io" denied the request:
the workload 'payment-service' of type 'apps/v1.Deployment' is already managed by
the hpa 'payment-service'
```

It also surfaces later, from anything that *touches* an existing ScaledObject — most visibly
`ops/apps/idle.sh`, which annotates them to pause KEDA and dies mid-way:

```
scaledobject.keda.sh/wiremock annotated
Error from server (Forbidden): admission webhook "vscaledobject.kb.io" denied the request: ...
```

**Cause.** A Deployment may have **one** autoscaler. KEDA's validating webhook enforces that
and refuses to create or update a ScaledObject whose target is already claimed by a foreign
HPA. The give-away is the HPA's *name*: KEDA names its own `keda-hpa-<scaledobject>`, so a
plain `payment-service` is the chart's CPU HPA, rendered when
`values/payment.yaml` has `autoscaling.enabled: true`.

Left unfixed it is quiet in the worst way: the apply fails for that one file while the rest
succeed, and payment keeps scaling on **CPU** — which ADR-0015 rejected precisely because the
service is I/O-bound, so its CPU barely moves while the `inventory.reserved` lag grows.
Experiments 01 and 04 then measure the wrong autoscaler.

**Fix.** The chart must render neither an HPA nor `spec.replicas` for a KEDA-scaled service.
`values/payment.yaml` carries both flags:

```yaml
autoscaling:
  enabled: false     # no CPU HPA — otherwise the webhook refuses the ScaledObject
keda:
  enabled: true      # also omit spec.replicas — otherwise ArgoCD selfHeal fights KEDA
```

On a cluster that already has the stray HPA, delete it and re-apply. Update the values **first**
if you use GitOps, or ArgoCD's `selfHeal` will simply put the HPA back:

```bash
kubectl -n atlas-apps delete hpa payment-service
kubectl apply -f deploy/platform/keda/payment-scaledobject.yaml
kubectl -n atlas-apps get hpa            # expect keda-hpa-payment-service, and no payment-service
```

If `idle.sh` died part-way, it left the ScaledObjects it *did* reach pinned to zero. Un-pause
them, or wiremock — the fake payment provider — stays at 0 replicas and payment's provider
calls hang:

```bash
kubectl -n atlas-apps annotate scaledobject --all autoscaling.keda.sh/paused-replicas-
```

---

## GitOps (Argo CD)

These apply to the GitOps path ([`argocd/README.md`](./argocd/README.md)). In every case, open the
app in the Argo UI (or `argocd app get <name>`) — the failing resource shows its **Events** and
**Logs** in the drawer.

### TS-ARGO-01 — App OutOfSync or Degraded

**Symptom.** A child app (e.g. `kafka-cluster`, a `*-service`) shows **OutOfSync** or **Degraded**
and the wave doesn't advance.

**Cause.** Usually a downstream dependency isn't ready yet (an earlier wave is still Progressing),
or the underlying resource genuinely failed to reconcile (bad image, missing Secret/ConfigMap,
insufficient node resources). Argo will not advance to wave *N+1* until wave *N* is Synced **and**
Healthy — so one stuck resource holds the line (by design).

**Fix.** Drill in: `argocd app get <name>` (or the UI tree) → find the red resource → read its
Events/Logs. Then treat it as a normal Kubernetes issue:
```bash
argocd app get atlas-root                       # top-level convergence view
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail
kubectl -n <ns> describe <kind>/<name>
```
Missing `atlas-issuer` on the services is the **expected** transient — finish/re-run
`bootstrap.sh`. For genuinely stuck syncs, `argocd app sync <name>` (or **Sync** in the UI) after
fixing the cause; `selfHeal` retries on its own once the cause clears.

### TS-ARGO-02 — CRD-before-CR: `no matches for kind …`

**Symptom.** A wave-3/4/5 app fails to sync with `unable to recognize "...": no matches for kind
"Cluster"/"Kafka"/"Keycloak"/"KafkaTopic" in version "..."`.

**Cause.** The custom resource was applied before its operator's **CRD** exists. In normal
operation the sync-waves prevent this (operators = wave 2, their CRs = wave 3+). It surfaces if an
operator app is itself failing (so its CRDs never install) or if you applied a CR app out of band.

**Fix.** Make the operator healthy first, then re-sync the CR app:
```bash
argocd app get cnpg-operator      # (or strimzi-operator / keycloak-operator / keda-operator)
kubectl get crd | grep -E 'cnpg|strimzi|keycloak|keda'   # confirm the CRDs registered
argocd app sync cnpg-cluster
```

### TS-ARGO-03 — App stuck Progressing on a stateful CR

**Symptom.** `cnpg-cluster`, `kafka-cluster` or `keycloak` sits **Progressing** forever (never goes
Healthy), so the next wave never starts — even though the pods look up.

**Cause.** Two possibilities. (1) The custom health check for that CR
([`install/argocd-cm-health.yaml`](./argocd/install/argocd-cm-health.yaml)) isn't loaded, so Argo
has no health for it. (2) It **is** loaded and the CR genuinely isn't `Ready` yet
(`status.conditions[type=Ready]` is not `True`) — first image pulls + volume provisioning are slow
on a fresh cluster.

**Fix.** Confirm the health customizations are present, then check the CR's real condition:
```bash
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data}' | grep -o 'health\.[a-z.]*_[A-Za-z]*'
# expect: health.postgresql.cnpg.io_Cluster / health.kafka.strimzi.io_Kafka / health.k8s.keycloak.org_Keycloak
kubectl -n atlas-data get cluster/atlas-pg -o jsonpath='{.status.conditions}' | jq
```
If the health keys are missing, re-apply the patch (a `helm upgrade` of Argo CD drops it):
```bash
kubectl -n argocd patch configmap argocd-cm --type merge \
  --patch-file deploy/argocd/install/argocd-cm-health.yaml
kubectl -n argocd rollout restart deploy/argocd-application-controller
```
If the keys are present, the CR is simply still coming up — wait (see the runbook note on slow
first pulls). If it's actually stuck, chase it as a CNPG/Strimzi/Keycloak issue (e.g. a `Pending`
PVC → [TS-PLATFORM-02](#ts-platform-02--postgres-initdb-pod-stuck-pending-unbound-pvc)).

### TS-ARGO-04 — Oversized CRD: ServerSideApply

**Symptom.** An operator/CRD app (Prometheus Operator, Keycloak, Strimzi) fails to sync with
`metadata.annotations: Too long: must have at most 262144 bytes` or
`error validating data ... last-applied-configuration`.

**Cause.** Client-side apply stores the whole object in the `last-applied-configuration`
annotation; the largest CRDs blow past the annotation size limit.

**Fix.** These apps already set `ServerSideApply=true` in their `syncOptions` — if you removed it,
put it back:
```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```
Then re-sync. To force it once from the CLI: `argocd app sync <name> --server-side`.

**The same limit bites plain `kubectl apply`,** not just Argo CD. The CNPG Grafana dashboard
(~253 KB of JSON) is the case you will actually hit:

```
$ kubectl create configmap cnpg-dashboard -n atlas-observability \
    --from-file=cnpg-dashboard.json --dry-run=client -o yaml | kubectl apply -f -
The ConfigMap "cnpg-dashboard" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

Add `--server-side` to the apply — it writes no `last-applied-configuration` annotation:

```bash
... | kubectl apply --server-side -f -
```

Rule of thumb: any single manifest over ~250 KB needs server-side apply, whichever tool is
driving it.

### TS-ARGO-05 — Ingress patch fails with `x509: certificate signed by unknown authority`

**Symptom.** `bootstrap.sh` reaches Phase B, applies the secrets, then dies while patching the
public hostnames:

```
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.nginx.ingress.kubernetes.io": failed to call webhook: Post
"https://ingress-nginx-controller-admission.atlas-system.svc:443/networking/v1/ingresses?timeout=10s":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Any `kubectl apply`/`patch` on an Ingress hits it — Argo can't sync the Keycloak / Kafka-UI /
atlas ingresses either.

**Cause.** ingress-nginx ships a **validating admission webhook**; the API server must trust the
cert that webhook serves. That trust comes from the `caBundle` on the
`ingress-nginx-admission` `ValidatingWebhookConfiguration`, which the chart's
**`ingress-nginx-admission-patch` post-install hook Job** injects. Under Argo CD that Job is a
**PostSync** hook — it only runs after the ingress-nginx Application is Synced + Healthy, which
can land **after** the LoadBalancer IP appears (what Phase B waits on). In that window the
webhook is registered but its `caBundle` is still **empty**, so every Ingress apply is rejected.

**Confirm it:**

```bash
# empty output = the caBundle was never injected (this is the bug)
kubectl get validatingwebhookconfiguration ingress-nginx-admission \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' ; echo
# the -patch Job is missing/incomplete (only -create shows)
kubectl -n atlas-system get jobs | grep admission
```

**Fix — inject the caBundle from the admission Secret** (exactly what the `-patch` hook does;
the CA already exists in the Secret's `ca` key):

```bash
CA=$(kubectl -n atlas-system get secret ingress-nginx-admission -o jsonpath='{.data.ca}')
kubectl patch validatingwebhookconfiguration ingress-nginx-admission --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CA\"}]"

# verify: a server-side dry-run Ingress now passes the webhook
kubectl create ingress t --rule="t.local/=svc:80" --class=nginx --dry-run=server -n atlas-system
```

Then re-run `bootstrap.sh` (idempotent) — the host patches now succeed.

> **Already fixed in the flow.** `bootstrap.sh` calls `ensure_ingress_webhook_ready` before it
> patches any host: it waits for the caBundle and, if the PostSync hook is still lagging,
> injects it from the Secret automatically. You only do the above by hand on an older bootstrap
> or if you patch an Ingress yourself before that step. If you would rather not run the webhook
> at all, set `controller.admissionWebhooks.enabled: false` in
> `deploy/platform/ingress-nginx/values.yaml` (you lose Ingress validation, but the whole race
> disappears).

### TS-ARGO-06 — Kafka never comes up (Strimzi CrashLoops, or the Kafka CR won't apply)

**Symptom.** The `kafka-cluster` app is stuck `OutOfSync` with
`one or more synchronization tasks are not valid`, there is **no Kafka CR** in `atlas-data`, and
anything that needs the broker fails to resolve it:

```
KEDAScalerFailed … dial tcp: lookup atlas-kafka-bootstrap.atlas-data … no such host
```

The Strimzi operator pod is in `CrashLoopBackOff`, and its log ends with:

```
UnrecognizedPropertyException: Unrecognized field "emulationMajor" (class ...VersionInfo)
```

**Cause.** Two version-skew problems, both from an operator pin that is **older than what the
cluster and the repo's own Kafka CR need**:

1. **k8s too new for the operator.** Kubernetes 1.33+ adds `emulationMajor`/`emulationMinor` to
   the `/version` response. The fabric8 client bundled in **Strimzi 0.45.x** can't deserialize it,
   so the operator crashes on startup. Civo only offers 1.33+, so pinning k8s down is **not** an
   escape — the operator has to move.
2. **CR ahead of the CRDs.** `deploy/platform/strimzi/kafka.yaml` uses
   `apiVersion: kafka.strimzi.io/v1` (GA'd in Strimzi 1.0) and `version: 4.3.0`. The 0.45.x chart
   installs CRDs that only serve `v1beta2` and an operator that only knows Kafka ≤ 3.9, so Argo
   can't even apply the CR (`no matches for kind`/invalid task).

**Confirm:**

```bash
kubectl -n atlas-data logs deploy/strimzi-cluster-operator | grep -m1 emulationMajor
kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}'  # only v1beta2 = too old
```

**Fix.** Bump the Strimzi operator to the **1.x** line, matched to the Kafka `version:` in the CR
(1.1.0 ships the `v1` CRDs, supports Kafka 4.3.0, and runs on k8s 1.36). In
[`deploy/argocd/apps/20-strimzi-operator.yaml`](argocd/apps/20-strimzi-operator.yaml):

```yaml
    targetRevision: 1.1.0   # was 0.45.0
```

Because Argo syncs from **origin/main**, commit and push this (see the GitOps note in
`argocd/README.md`) — editing the running Application is reverted by self-heal. Once pushed, Argo
replaces the CRDs (now serving `v1`) and rolls the operator; the Kafka CR then applies and the
brokers come up. Keep the operator's `targetRevision` in step with the Kafka `version:` whenever
either moves — that pairing is the whole bug.

> **Upgrading an existing 0.45.x cluster in place** (not a fresh install) hits one extra snag:
> the 1.x CRDs drop `v1beta2`, but k8s refuses to remove a version still in the CRD's
> `status.storedVersions`, so the sync fails with
> `status.storedVersions[0]: Invalid value: "v1beta2": … must remain in spec.versions until a
> storage migration`. On a lab cluster with **no Kafka data yet** (`kubectl get kafka,kafkatopic
> -A` is empty), just delete the old CRDs and let Argo reinstall the 1.x ones:
> `kubectl get crd -o name | grep strimzi | xargs kubectl delete`. A **fresh** install never
> sees this — it lays down the 1.x CRDs on an empty cluster.

### TS-ARGO-07 — Apps stuck `SYNC=Unknown` with `ComparisonError … terminatingReplicas`

**Symptom.** One or more apps sit at `SYNC=Unknown` (never sync, even though the resources look
fine) and carry a `ComparisonError`:

```
Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from live resource:
.status.terminatingReplicas: field not declared in schema
```

It hits **every app with a Deployment or ReplicaSet** — `redis`, the operators, etc. — so large
parts of the stack never converge (e.g. `strimzi-operator` can't upgrade, so Kafka never comes up).

**Cause.** Kubernetes 1.33 added `.status.terminatingReplicas` to Deployments/ReplicaSets. The
Kubernetes schema **bundled in this Argo CD build (v2.14.9 / chart 7.8.23)** predates it, so Argo's
client-side structured-merge diff can't build a typed value from the live object and bails. Civo
only offers k8s 1.33+, so every cluster here is exposed.

**Fix.** Use **server-side diff** — Argo asks the API server (which knows the field) to compute
the diff. It's enabled for new clusters in
[`argocd-values.yaml`](argocd/install/argocd-values.yaml)
(`configs.params."controller.diff.server.side": "true"`), so a fresh `bootstrap.sh` never sees
this. To turn it on for a cluster that's already up:

```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"controller.diff.server.side":"true"}}'
kubectl -n argocd rollout restart statefulset argocd-application-controller
```

The `ComparisonError` clears within a reconcile and the blocked apps sync. (Alternative: bump the
Argo CD chart to a build whose bundled schema already knows the field.)

### TS-ARGO-08 — Kafka broker PVCs stuck `Terminating`, `kafka-cluster` never Healthy

**Symptom.** The Kafka brokers are `Running` and `kafka/atlas` reports `Ready`, yet the
`kafka-cluster` app never goes Healthy — it sits `Progressing` on the broker PVCs
(`data-0-atlas-dual-role-0/1/2`), which show `STATUS: Terminating` for as long as you watch
(45+ minutes), even though the pods are using them.

```bash
kubectl -n atlas-data get pvc | grep dual-role     # Terminating, but the pods are Running
kubectl -n atlas-data get pvc data-0-atlas-dual-role-0 \
  -o jsonpath='{.metadata.deletionTimestamp} {.metadata.finalizers}'   # a deletionTimestamp + pvc-protection
```

**Cause.** Argo CD's default **resource tracking is by label** (`argocd.argoproj.io/instance`).
Strimzi **copies the Kafka CR's labels onto every child object it creates** — including that
tracking label, onto the dynamically-provisioned broker PVCs. Argo then believes it owns those
PVCs, doesn't find them in git, and (with `prune: true`) **deletes them**. The `pvc-protection`
finalizer keeps each PVC alive while its broker runs, so it hangs in `Terminating` indefinitely —
and if a broker ever restarts, its volume is finalized out from under it. It is **not** a slow
Civo volume (those bind in a couple of minutes) — confirm the `deletionTimestamp` above.

**Fix — switch Argo to annotation-based tracking** (Strimzi copies labels, not annotations, so the
PVCs stop looking Argo-owned). It's set for new clusters in
[`argocd-values.yaml`](argocd/install/argocd-values.yaml)
(`configs.cm."application.resourceTrackingMethod": annotation`), so a fresh `bootstrap.sh` never
hits this. For a cluster already up:

```bash
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'
kubectl -n argocd rollout restart statefulset argocd-application-controller
```

That stops future pruning, but a PVC already carrying a `deletionTimestamp` can't be un-deleted.
On a lab cluster with **no Kafka data**, free and recreate them — Strimzi rebuilds each PVC (now
untracked) and rebinds its broker:

```bash
kubectl -n atlas-data delete pod atlas-dual-role-0 atlas-dual-role-1 atlas-dual-role-2
kubectl -n atlas-data get pvc -w   # the Terminating PVCs vanish, fresh Bound ones replace them
```

The same label-propagation trap applies to any operator that copies labels to children; annotation
tracking is the general fix.
