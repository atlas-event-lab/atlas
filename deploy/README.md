# Deploy

Everything needed to run Atlas on a Kubernetes cluster. **New here? Don't read this folder
file by file — follow the guide top to bottom.** This page is just the map.

## The guide (start here)

➡️ **[`DEPLOYMENT-RUNBOOK.md`](../DEPLOYMENT-RUNBOOK.md)** takes you from zero to a running,
observable stack, in order: provision a cluster → install the platform → deploy the services
→ observe → scale. It links out to the pages below at the right moments.

**Two ways to deploy:** **(A) GitOps** — `terraform apply` + one `bootstrap.sh`, watch it converge
in the Argo CD UI → [`argocd/README.md`](./argocd/README.md). **(B)** the manual runbook above. Both
apply the same manifests.

## The path for a new user

1. **Provision a cluster** → [`cluster/README.md`](./cluster/README.md) — Terraform setups for
   **Oracle OKE** and **Civo** (pick one). Skip if you already have a cluster + `kubectl`.
2. **Install the platform and services** — either **GitOps** ([`argocd/README.md`](./argocd/README.md),
   2 commands, self-healing) or the manual [`DEPLOYMENT-RUNBOOK.md`](../DEPLOYMENT-RUNBOOK.md).
3. **Turn compute off when idle** to save trial credit → [`ops/README.md`](./ops/README.md).
4. **Hit an error?** → [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) (cases have IDs like `TS-…`).

## What's in this folder

| Path | What it is |
|------|-----------|
| [`argocd/`](./argocd/README.md) | **GitOps** — Argo CD app-of-apps + sync-waves + `bootstrap.sh`. Deploy the whole stack with 2 commands and watch it converge. |
| [`cluster/`](./cluster/README.md) | **Provision a cluster** with Terraform — options: Oracle OKE, Civo. Each cloud has its own README. |
| [`platform/`](./platform/README.md) | Platform manifests (ingress, CloudNativePG, Strimzi/Kafka, Keycloak, KEDA, observability) + the DB-secret shape. Reference for the runbook steps. |
| [`helm/atlas-service/`](./helm/atlas-service) | The library Helm chart + per-service `values/` for the 9 services. |
| [`ops/`](./ops/README.md) | Day-to-day cost/lifecycle scripts (turn the cluster off when idle), one folder per cloud + a cloud-agnostic `apps/`. |
| [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) | Known errors and fixes, provisioning **and** platform, each with a stable ID. |
