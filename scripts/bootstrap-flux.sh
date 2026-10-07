#!/usr/bin/env bash
set -euo pipefail

# The production context is mandatory; never silently use the local dev cluster.
context="${1:?Usage: bash scripts/bootstrap-flux.sh <production-kube-context>}"
: "${GITHUB_TOKEN:?Export GITHUB_TOKEN for Flux bootstrap (see DEPLOYMENT.md)}"
command -v flux >/dev/null
command -v kubectl >/dev/null

flux check --pre --context="$context"

# Refuse to let two controllers reconcile the same workloads.
api_resources="$(kubectl --context="$context" api-resources -o name)"
if grep -qx 'applications.argoproj.io' <<< "$api_resources"; then
  argo_application="$(kubectl --context="$context" -n argocd get applications.argoproj.io map-infra --ignore-not-found -o name)"
  if [[ -n "$argo_application" ]]; then
    echo 'Orphan the Argo CD map-infra Application first; follow DEPLOYMENT.md.' >&2
    exit 1
  fi
fi

# Use the exact Flux release reviewed in Git, including Renovate upgrades.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flux_version="$(sed -n 's/^# Flux Version: //p' "$repo_root/clusters/production/flux-system/gotk-components.yaml")"
[[ "$flux_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]

flux bootstrap github \
  --context="$context" \
  --owner=kaljo14 \
  --repository=map-infra \
  --personal \
  --branch=main \
  --path=clusters/production \
  --version="$flux_version" \
  --read-write-key=false

flux get kustomizations --context="$context"
