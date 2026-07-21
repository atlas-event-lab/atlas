# Phase 7 prep — runbook

Prep the cluster for the scalability / resilience experiments (deployment-roadmap §Phase 7).
Three tasks. Tasks 1–2 are automated by [`phase7-prep.sh`](./phase7-prep.sh); task 3 is a
manual OCI node-pool change (it recycles nodes and needs your OCIDs).

Run tasks 1–2:

```bash
DRY_RUN=1 ./deploy/scripts/phase7-prep.sh   # preview, changes nothing
./deploy/scripts/phase7-prep.sh             # apply
```

---

## 1. Restore HPA on inventory / search

During the Postgres incident these two were pinned to `replica=1` with no HPA. The gitops
values (`atlas-gitops/charts/atlas-service/values/{inventory,search}.yaml`) already carry
`autoscaling.enabled: true`, so the fix is just to redeploy them. The script reuses the
**current live image tag**, so only the HPA is restored — the running image doesn't change.

**Verify (green = ready):**

```bash
kubectl -n atlas-apps get hpa inventory-service search-service
```

- `TARGETS` shows a real number (e.g. `12%/70%`), not `<unknown>` — `<unknown>` means
  metrics-server isn't feeding the HPA; fix that before load testing.
- `REPLICAS` ≥ `MINPODS`. Baseline is `min 1` (lean); raise to `min 2` only for the
  HA/Saga experiment window.

---

## 2. PgBouncer Pooler

Manifest: [`deploy/platform/cloudnative-pg/pooler.yaml`](../platform/cloudnative-pg/pooler.yaml).
One `rw` pooler in `transaction` mode fronts the primary and, via passthrough, serves **all**
service databases. It's the fix for the artificial `max_connections: 200` bottleneck under
load — PgBouncer multiplexes many app transactions over ≤ ~108 real server connections.

**Verify:**

```bash
kubectl -n atlas-data get pooler atlas-pg-pooler-rw -o wide     # status.phase -> active
kubectl -n atlas-data get pods -l cnpg.io/poolerName=atlas-pg-pooler-rw   # 2 Running
kubectl -n atlas-data get svc atlas-pg-pooler-rw                # ClusterIP :5432
```

Metrics land in Prometheus as `cnpg_pgbouncer_*` (watch `cnpg_pgbouncer_pools_cl_waiting`
and `_maxwait` during experiments — rising = pool too small).

### Activation — cut services over to the pooler

Applying the manifest doesn't reroute traffic; services still hit `atlas-pg-rw` directly.
To actually pool, repoint each service's `DB_URL` from the cluster's `rw` service to the
pooler service, and **disable server-side prepared statements** (`transaction` mode requires
it):

```
# before
jdbc:postgresql://atlas-pg-rw.atlas-data:5432/search_db
# after
jdbc:postgresql://atlas-pg-pooler-rw.atlas-data:5432/search_db?prepareThreshold=0
```

Do it per service in `atlas-gitops/charts/atlas-service/values/<svc>.yaml` (the `config.DB_URL`
key), then redeploy. **Canary with `search`** (highest read traffic, CQRS read side, no Saga
writes) — validate the happy path, watch `cnpg_pgbouncer_*`, then roll booking / inventory /
payment. Keycloak keeps its direct connection; don't route it through the pooler.

> If you'd rather keep prepared statements, drop `?prepareThreshold=0` and instead set
> `max_prepared_statements: "100"` in the Pooler's `pgbouncer.parameters` (PgBouncer ≥1.21).
> `prepareThreshold=0` is the simpler, lower-risk default for the MVP.

---

## 3. Raise max-pods-per-node to ~30  (manual — OCI node pool)

The baseline pod census already grazes the 45-pod cap (3×15); experiments exceed it
(deployment-roadmap §10.5). Raising the cap costs no compute — it's a scheduling ceiling —
but it's a **node-pool property**, so OKE replaces the nodes to apply it. Do it during the
same window as any memory bump.

This is **not** in the script: it needs your compartment/cluster/node-pool OCIDs and it
recycles nodes. Two ways:

**A — OCI CLI**

```bash
# find the node pool
oci ce node-pool list --compartment-id <COMPARTMENT_OCID> \
  --cluster-id <CLUSTER_OCID> --query 'data[].{name:name,id:id}' --output table

# raise the per-node pod limit (triggers a rolling node replacement)
oci ce node-pool update --node-pool-id <NODE_POOL_OCID> \
  --node-pool-pod-network-option-details '{"podSubnetIds":["<POD_SUBNET_OCID>"],"maxPodsPerNode":30}'
```

**B — OCI Console:** Console → Kubernetes Clusters (OKE) → *your cluster* → Node pools →
*pool* → Edit → **Maximum pods per node = 30** → Save → cycle nodes.

**Bound by the CNI:**
- **VCN-native pod networking** (OKE default) — pods take IPs from the pod subnet and are
  capped by the VNICs the shape supports. A 2-OCPU `E5.Flex` has a limited VNIC count, so
  confirm the pod subnet has free IPs and that 30 is reachable for the shape.
- **Flannel overlay** — no VCN-IP pressure; you can go up to the k8s ceiling (110) freely.

**Verify after nodes rejoin:**

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,MAXPODS:.status.allocatable.pods
```

Each node should report ~30 allocatable pods.
