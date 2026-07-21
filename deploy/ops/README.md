# Ops — cost & capacity controls

Two separate levers. They solve **different** problems — don't confuse them.

| Lever | Saves credits? | Frees memory? | Use when |
|-------|----------------|---------------|----------|
| **On/off cluster** (`cluster-down.sh` / `cluster-up.sh`) | **Yes** — stops worker compute billing | Yes (nodes gone) | You're done for the day/session |
| **App right-sizing** (HPA min 1) + `apps-idle.sh` | **No** — nodes stay powered on | Yes | You want platform up (Grafana/Kafka) but no app load |

Key fact: OCI bills worker nodes for being **RUNNING**, not for how many pods they hold.
Scaling replicas is a *capacity/stability* tool, never a cost tool. To save credits you
must terminate the workers — that's what `cluster-down.sh` does (node pool → 0).

## On/off (the real saver)

```bash
./cluster-down.sh     # node pool -> 0, workers terminate, compute billing stops
./cluster-up.sh       # node pool -> 3, waits for Ready (~10-15 min cold start)
./cluster-up.sh 4     # or bring it up at a different size
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

## Idle apps but keep the cluster up

```bash
./apps-idle.sh        # deletes HPAs + scales atlas-apps deploys to 0 (platform stays up)
./apps-resume.sh      # helm upgrade loop; restores replicas + HPAs, preserves image tags
```

`apps-idle.sh` deletes the HPAs first — otherwise they immediately re-scale the
deployments back up to `minReplicas`.

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
cd ../../atlas-gitops/charts/atlas-service
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
> `./cluster-down.sh && ./cluster-up.sh` (recreates all nodes fresh).

**At 16 GB the binding limit shifts from memory to the pod cap** (3 × 15 = 45; the lean
census already ~42). Raise `max-pods-per-node` to ~30 **during the node recycle** (it's a
node-pool property, needs node replacement either way). It's a scheduling ceiling — costs
no compute — and keeps the pod cap from becoming the next bottleneck.
