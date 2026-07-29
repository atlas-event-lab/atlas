# Oracle OKE — Terraform

Provisions the Atlas reference cluster on Oracle Cloud using the **official OKE module**,
which builds the full network stack (VCN, gateways, route tables, and the security rules
OKE requires) plus the cluster and a `3 × E5.Flex (2 OCPU / 16 GB)` worker pool.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [OCI CLI](https://docs.oracle.com/en-us/iaas/private-cloud-appliance/pca/installing-the-oci-cli.htm) configured:
  `oci setup config` (creates `~/.oci/config` with API-key auth — no secrets in code)
- An SSH public key (e.g. `~/.ssh/id_rsa.pub`)

## The values you must provide (`terraform.tfvars`)

Most inputs have sane defaults; the ones you must set are account-specific IDs (OCIDs) that
OCI assigns to your resources. Here is what each is and how to get it.

### `tenancy_id` — your Oracle Cloud account

Your **tenancy** is the root container of your whole OCI account — you get exactly one when
you sign up, and it doubles as the *root compartment*. Its OCID identifies your account.

- **Console:** profile icon (top-right) → **Tenancy: `<name>`** → copy **OCID**.
- **CLI:** it's already in `~/.oci/config` as the `tenancy=` line (written by `oci setup config`).

### `compartment_id` — where the cluster is created

A **compartment** is a folder inside your tenancy that groups and isolates resources (for
access control, quotas and billing). Terraform creates the VCN, cluster and nodes **inside
this compartment**.

- Simplest for a lab: **use your `tenancy_id`** — that deploys into the root compartment
  (`compartment_id = <tenancy_id>`).
- Dedicated compartment (recommended for real use): **Identity & Security → Compartments**
  → open it → copy **OCID**, or list them:
  ```bash
  oci iam compartment list --query 'data[].{name:name,id:id}' --output table
  ```

### `region` / `home_region`

- `region` — where the cluster runs, e.g. `us-ashburn-1` (Console top bar, or
  `oci iam region-subscription list`).
- `home_region` — the region where your account's **identity** lives (**Administration →
  Tenancy details → Home Region**). On a single-region tenancy it equals `region`. The
  module creates IAM policies there.

### `worker_image_id` — the OS image the nodes boot (optional)

OKE nodes boot from a special **OKE worker image** (Oracle Linux with kubelet/containerd
preinstalled) tied to a Kubernetes version *and* region. **The module resolves it
automatically from `kubernetes_version`** — on current `oci` providers (verified on 8.24.0)
you should leave `worker_image_id` **unset** and let auto-resolution pick the right image.

Only set it as a **fallback** if `terraform plan`/`apply` fails resolving the image on your
provider/region (older providers returned an empty image list — see **TS-OKE-03** in
[`TROUBLESHOOTING.md`](../../../TROUBLESHOOTING.md#ts-oke-03--oke-terraform-plan-fails-resolving-the-worker-image)).
If you do, pick the image whose name matches your `kubernetes_version`, **x86_64, non-GPU**:

```bash
oci ce node-pool-options get --node-pool-option-id all --query 'data.sources' --output table
```

Its region code (`iad` = Ashburn) must match your `region`, and its version **must match
`kubernetes_version`** — a mismatched image OCID makes `apply` fail with a `409-Conflict`
(see TS-OKE-03).

### `control_plane_allowed_cidrs` — who can reach the API endpoint

The cluster's Kubernetes API endpoint is **public**, but the OKE module opens **no** ingress
to it by default — so `kubectl` would time out (`dial tcp …:6443: i/o timeout`) even with a
valid kubeconfig. This variable is the allow-list for TCP 6443.

- **Default `["0.0.0.0/0"]`** — reachable from any IP (still protected by OCI-signed token
  auth + TLS). Works out of the box; no action needed.
- **Restrict to your machine (recommended for anything beyond a throwaway lab):** set your
  public IP as a `/32` in `terraform.tfvars` and re-apply. If your IP changes (dynamic home
  connection), update it and `terraform apply` again:
  ```bash
  curl -s ifconfig.me      # your current public IP
  ```
  ```hcl
  # terraform.tfvars
  control_plane_allowed_cidrs = ["203.0.113.4/32"]
  ```

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in YOUR OCIDs, region, ssh key path
terraform init
terraform plan                                 # review
terraform apply                                # ~10-15 min (network + cluster + nodes)

# point kubectl at it:
oci ce cluster create-kubeconfig \
  --cluster-id "$(terraform output -raw cluster_id)" \
  --file ~/.kube/config --region <your-region> --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
kubectl get nodes
```

> If `kubectl get nodes` hangs and ends in `dial tcp …:6443: i/o timeout`, the API
> endpoint is not open to your IP — see `control_plane_allowed_cidrs` above and
> **TS-OKE-04** in [`deploy/TROUBLESHOOTING.md`](../../../TROUBLESHOOTING.md#ts-oke-04--oke-kubectl-times-out-on-the-public-api-endpoint-io-timeout).

## Provider / module versions

Uses `oci ~> 8.0` (the OKE module requires `>= 8.19.0`) and the OKE module `~> 5.2`. This
combo passes `terraform init` + `terraform validate` (config-level inputs are correct).
The exact provider versions are pinned in `.terraform.lock.hcl` — **commit it**.

> `validate` checks the config and input names, not live values. `terraform plan` (with
> your OCI auth) is the first check of value-level inputs (region, availability domains,
> `worker_pools` fields, image selection). Common `init`/`plan` errors and their fixes —
> **TS-OKE-01** (provider version), **TS-OKE-02** (bastion/operator), **TS-OKE-03** (worker
> image) — are in
> [`deploy/TROUBLESHOOTING.md`](../../../TROUBLESHOOTING.md#ts-oke-01--oke-terraform-init-provider-version-conflict).

## Cost control

Scale the worker pool to 0 when idle (the real credit-saver) with
[`deploy/ops/oracle/cluster-down.sh` / `cluster-up.sh`](../../../ops/oracle) — set `NODEPOOL_OCID` from:

```bash
terraform output worker_pool_ids
```

To remove **everything**: `terraform destroy`.

## Notes

- **1 OCPU = 2 vCPU** on `E5.Flex` (x86), so `2 OCPU / 16 GB × 3` = **12 vCPU / 48 GB**.
- `cni_type = "npn"` = VCN-native pod networking (matches the original). Use `"flannel"`
  for an overlay that conserves VCN IPs.
- **Pin `kubernetes_version`** for a reproducible cluster.
