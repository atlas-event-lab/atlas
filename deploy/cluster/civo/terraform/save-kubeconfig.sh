#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Save the cluster's kubeconfig to a file — RELIABLY.
#
# `terraform output -raw kubeconfig` is flaky: the civo/civo provider frequently returns the
# kubeconfig EMPTY right after `apply` (and a refresh does not repopulate it). That is the #1
# "empty kubeconfig" papercut (TS-CIVO-01). This script tries Terraform first and, if that
# comes back empty, falls back to the Civo CLI — which fetches from the API and always works.
#
# Usage (from this folder, after `terraform apply`):
#   ./save-kubeconfig.sh                       # -> OVERWRITES ~/.kube/config (kubectl's default)
#   ./save-kubeconfig.sh /path/to/kubeconfig   # custom destination
#   kubectl get nodes                          # works in ANY shell, no `export KUBECONFIG` needed
#
# By default this OVERWRITES ~/.kube/config — the file kubectl reads with no env var — so kubectl
# just works globally, no per-shell `export`. Civo clusters here are ephemeral and unique: a recreate
# invalidates the previous one, so replacing the whole default config (not merging) is intentional.
# The prior config is backed up to ~/.kube/config.bak first. NOTE: this also drops any other contexts
# in that file (e.g. Oracle OKE / minikube); recover them from the .bak, or pass a custom destination.
#
# Requires: terraform; the Civo CLI only if the Terraform output is empty (the common case).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-$HOME/.kube/config}"

valid() { grep -q '^[[:space:]]*server:' <<<"${1:-}"; }   # a real kubeconfig has a `server:` line

kc="$(terraform output -raw kubeconfig 2>/dev/null || true)"
if ! valid "$kc"; then
  echo ">> terraform output kubeconfig was empty (known civo provider quirk) — using the Civo CLI." >&2
  if ! command -v civo >/dev/null 2>&1; then
    echo "ERROR: kubeconfig empty AND the civo CLI is not installed. Install it" >&2
    echo "       (https://www.civo.com/docs/overview/civo-cli), or see TROUBLESHOOTING TS-CIVO-01." >&2
    exit 1
  fi
  cn="$(terraform output -raw cluster_name 2>/dev/null || echo atlas-civo)"
  # The Civo CLI region is case-SENSITIVE and lowercase (nyc1), even though tfvars accepts NYC1.
  region="$(grep -E '^[[:space:]]*region' terraform.tfvars 2>/dev/null \
            | sed -E 's/.*=[[:space:]]*"?([A-Za-z0-9]+)"?.*/\1/' | tr '[:upper:]' '[:lower:]')"
  kc="$(civo kubernetes config "$cn" --region "${region:-nyc1}" 2>/dev/null || true)"
fi

if ! valid "$kc"; then
  echo "ERROR: could not obtain a valid kubeconfig from Terraform or the Civo CLI." >&2
  echo "       Is the cluster ACTIVE? (civo kubernetes list --region <r>). See TS-CIVO-01." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
# Back up the previous config before overwriting (rolling single backup; recoverable if needed).
[ -f "$DEST" ] && cp -f "$DEST" "$DEST.bak" && echo ">> backed up previous config to $DEST.bak"
printf '%s\n' "$kc" > "$DEST"
chmod 600 "$DEST"                                  # holds the client private key — keep it private
echo ">> kubeconfig saved to $DEST"
echo ">> next:  kubectl get nodes    # works in any shell, no 'export KUBECONFIG' needed"
