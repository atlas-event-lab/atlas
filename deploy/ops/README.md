# Ops — cost & capacity controls

Day-to-day operation of an **already-provisioned** cluster (the cluster itself is created
with Terraform — see [`deploy/cluster/`](../cluster/README.md)). Cost saving here is about
turning worker compute off when idle.

## Folder layout

One folder per cloud (mirrors `deploy/cluster/<cloud>/`), plus a cloud-agnostic `apps/`:

| Path | Cloud | What it does | Saves credits? |
|------|-------|--------------|----------------|
| [`oracle/cluster-down.sh`](./oracle/cluster-down.sh) / [`cluster-up.sh`](./oracle/cluster-up.sh) | **Oracle** (`oci`) | Scale the OKE node pool to **0** / back up | **Yes** — workers terminate |
| [`civo/cluster.sh`](./civo/cluster.sh) `up`/`down` | **Civo** (`terraform`) | Create / destroy the cluster (no "stop" on Civo) | **Yes** — $0 while down |
| [`apps/idle.sh`](./apps/idle.sh) / [`apps/resume.sh`](./apps/resume.sh) | **Any** (`kubectl`/`helm`) | Scale business apps to 0 / restore, keeping the platform up | **No** — nodes stay on |

Each cloud folder takes a gitignored `config.env` (copy its `config.env.example`).

Two separate levers — don't confuse them:

- **On/off cluster** (Oracle `oracle/cluster-*.sh` · Civo `civo/cluster.sh up/down`) is
  the **real credit-saver**: a cloud bills worker nodes for being **RUNNING**, not for how
  many pods they hold. To save money you must terminate/deallocate the workers.
- **App right-sizing** (`apps/idle.sh`) frees memory but keeps nodes powered on, so it saves
  **nothing** — use it when you want the platform (Grafana/Kafka/Keycloak) up with no app load.

## On/off — Oracle (OKE)

```bash
cd oracle
export NODEPOOL_OCID="ocid1.nodepool.oc1..."   # your pool (or set it in config.env)
./cluster-down.sh   # node pool -> 0, workers terminate, compute billing stops
./cluster-up.sh     # node pool -> 3, waits for Ready (~10-15 min cold start)
./cluster-up.sh 4   # or bring it up at a different size
```

Rough compute cost, 3 × (2 OCPU / 16 GB) ≈ **$0.22/h ≈ ~$155/mo at 24/7**. Running only
~4 h/day on weekdays (~80 h/mo) drops it to **~$17/mo**.

**What persists across down/up:** all PVC data (Postgres/Kafka/Keycloak) on OCI Block
Volumes reattaches automatically. **Still billed while down** (small): the LoadBalancer
and the block volumes themselves.

**Do NOT delete the LoadBalancer.** The Keycloak issuer is pinned to its IP
(`<cluster-ip>` via nip.io); a new IP breaks the `iss` all 8 services validate. Ideally
attach a **Reserved Public IP** to the LB so the address is stable across recreations.

**Check the cluster type:** an *Enhanced* OKE cluster bills ~$0.10/h for the control plane
even at 0 nodes (~$73/mo); a *Basic* cluster's control plane is free. Worth confirming.

## On/off — Civo

Civo has **no stop/deallocate** and a cluster needs ≥ 1 node, so the off switch is
destroying the cluster with Terraform (recreates in ~2 min). The cluster is a single fixed
12 vCPU / 48 GB pool (provisioned in [`deploy/cluster/civo/terraform`](../cluster/civo/terraform)).

```bash
cd civo
export CIVO_TOKEN="your-civo-api-key"
./cluster.sh up       # terraform apply   -> cluster live
./cluster.sh down     # terraform destroy -> $0 (PVC data lost unless volumes Retain)
./cluster.sh status   # civo CLI show, or Terraform state
```

## Idle apps but keep the cluster up

```bash
cd apps
./idle.sh        # deletes HPAs + scales atlas-apps deploys to 0 (platform stays up)
./resume.sh      # helm upgrade loop; restores replicas + HPAs, preserves image tags
```

`apps/idle.sh` deletes the HPAs first — otherwise they immediately re-scale the
deployments back up to `minReplicas`. Both are cloud-agnostic (pure `kubectl`/`helm`).

## Baseline replica strategy (already in the chart values)

Lean baseline so the stack fits at idle; HPA scales up under load/experiments:

- **booking / inventory / payment:** HPA `minReplicas: 1` (was 2), `maxReplicas: 4`,
  anti-affinity kept for when it scales past 1. Raise min to 2 during HA/Saga experiments.
- **search:** already `min 1 / max 3`.
- **user / flight / hotel / travel-cart:** `replicaCount: 1`, no HPA.
- **Kafka:** 1 broker baseline; 3 brokers only for replication/DLQ experiments.
- **CNPG:** primary only in dev; add a replica for failover experiments.

Apply after editing values (or let CI/CD do it):

```bash
cd ../helm/atlas-service
for s in booking inventory payment; do
  helm upgrade "$s-service" . -f "values/$s.yaml" --reuse-values \
    --set autoscaling.minReplicas=1 -n atlas-apps
done
```

## Node sizing (why 16 GB, not 24)

Nodes: 3 × `VM.Standard.E5.Flex`, **2 OCPU / 16 GB**. The lean baseline stack
(apps + CNPG + Kafka 1 broker + Keycloak + LGTM) uses **~12-14 GiB**; against
3 × 16 GB ≈ **~42 GiB allocatable** that's ~30%, leaving ~28 GiB for HPA scale-up,
3-broker Kafka experiments, CNPG replica, and Tempo. Even the "everything at once"
worst case (~23-25 GiB) fits. 24 GB would just be idle, paid-for RAM.

> A shape edit in the OCI UI only changes the template for **new** nodes; running nodes
> keep their old size until **recycled**. Verify the live size (not the UI) with:
> ```bash
> kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.capacity.memory
> ```
> Apply the new size by recycling: *Cycle nodes* (Enhanced clusters) or
> `oracle/cluster-down.sh && oracle/cluster-up.sh` (recreates all nodes fresh).

**At 16 GB the binding limit shifts from memory to the pod cap** (3 × 15 = 45; the lean
census already ~42). Raise `max-pods-per-node` to ~30 **during the node recycle** (it's a
node-pool property, needs node replacement either way). It's a scheduling ceiling — costs
no compute — and keeps the pod cap from becoming the next bottleneck.
