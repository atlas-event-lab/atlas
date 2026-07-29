# Platform manifests — reference

This folder holds the in-cluster platform: operators' custom resources, values files, and
supporting manifests. Everything stateful (Postgres, Kafka, Keycloak) runs **inside the
cluster** for portability (roadmap §0) — only the node pool and the LoadBalancer are
vendor-specific.

> **This is a reference, not the procedure.** To actually install the platform, follow the
> ordered steps in **[`DEPLOYMENT-RUNBOOK.md`](../../DEPLOYMENT-RUNBOOK.md)** — it applies
> these manifests in the right order with the right waits. This page just says *what each
> manifest is* and captures the manifest-level details (DB secret shape, open inputs) the
> runbook points back to.

Namespaces: `atlas-system` (ingress, Keycloak), `atlas-data` (Postgres, Kafka),
`atlas-apps` (the 9 services + wiremock).

## What each manifest is

| Path | What it is | Installed in |
|------|-----------|--------------|
| [`00-namespaces.yaml`](./00-namespaces.yaml) | The three namespaces | Runbook §1 |
| [`ingress-nginx/values.yaml`](./ingress-nginx) | ingress-nginx Helm values (single public LB) | Runbook §2 |
| [`cloudnative-pg/`](./cloudnative-pg) | CNPG `cluster.yaml`, `databases.yaml`, and `create-db-secrets.sh` | Runbook §3 |
| [`strimzi/`](./strimzi) | Kafka CR (`kafka.yaml`), `topics.yaml`, metrics & rebalance | Runbook §4 |
| [`keycloak/`](./keycloak) | Keycloak CR, `realm-import.yaml`, ingress | Runbook §5 |
| [`apps/`](./apps) | `wiremock.yaml` (fake payment provider), `atlas-ingress.yaml` (edge routing), deployer RBAC | Runbook §6 |
| [`observability/`](./observability) | kube-prometheus-stack / Loki / Tempo / Alloy values + Atlas dashboards | Runbook §7 |
| [`keda/`](./keda) | KEDA `ScaledObject`s (Kafka-lag driven) for the load experiments | Runbook §8 |

Also here (supporting/optional): `kafka/` (Kafka-UI), `node-tuning/` (inotify limits for
nodes), `redis/`, `booking-secret.sealed.yaml` (a sample SealedSecret).

## DB secret shape (referenced from the runbook)

Each service gets **one `kubernetes.io/basic-auth` Secret with four keys**, so the same
secret serves both CloudNativePG (the DB role) and the app:

| key | consumed by |
|-----|-------------|
| `username` / `password` | CloudNativePG role (`managed.roles[].passwordSecret`) |
| `DB_USERNAME` / `DB_PASSWORD` | the service (Helm `envSecret` → `envFrom`) |

`username` and `DB_USERNAME` MUST equal the role name (e.g. `booking_user`). Two ways to
create them (see the runbook's **Secrets** section for when to use which):

- **Manual bootstrap (to get running):** [`cloudnative-pg/create-db-secrets.sh`](./cloudnative-pg/create-db-secrets.sh)
  creates all secrets with random passwords, in the right namespaces. Nothing is committed.
- **GitOps (later):** seal the same secret and commit the `SealedSecret` (needs the
  sealed-secrets controller + `kubeseal`):
  ```bash
  kubectl create secret generic booking-secret -n atlas-data \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=booking_user --from-literal=password='<pw>' \
    --from-literal=DB_USERNAME=booking_user --from-literal=DB_PASSWORD='<pw>' \
    --dry-run=client -o yaml | kubeseal -o yaml > booking-secret.sealed.yaml
  ```

> The app pods run in `atlas-apps`, so the app-facing secret must also exist there —
> replicate it into both namespaces or keep a separate app secret in `atlas-apps`.

## Open inputs (decide before/while applying)

- `storageClass` — the manifests leave it **unset** and use the cluster's **default** class
  (confirm one is marked `(default)` via `kubectl get storageclass`). To pin a specific
  class, uncomment `storageClass` in `cloudnative-pg/cluster.yaml`, `strimzi/kafka.yaml`, and
  the `observability/*-values.yaml` files.
- Object-storage bucket + creds for Postgres backups (commented in `cluster.yaml`).
- Keycloak public hostname for the realm issuer (Runbook §5 / the `atlas-issuer` secret).
- CloudNativePG version ≥ 1.24 for the `Database` CRD.
