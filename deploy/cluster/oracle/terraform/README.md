# Oracle OKE — Terraform

Provisions the Atlas reference cluster on Oracle Cloud using the **official OKE module**,
which builds the full network stack (VCN, gateways, route tables, and the security rules
OKE requires) plus the cluster and a `3 × E5.Flex (2 OCPU / 16 GB)` worker pool.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [OCI CLI](https://docs.oracle.com/en-us/iaas/private-cloud-appliance/pca/installing-the-oci-cli.htm) configured:
  `oci setup config` (creates `~/.oci/config` with API-key auth — no secrets in code)
- An SSH public key (e.g. `~/.ssh/id_rsa.pub`)

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
