# Repository guidance

Kubernetes infrastructure for lonctus.com on K3s. Flux CD reconciles `main` from
`clusters/production`; Renovate proposes image and tooling updates via PRs.
Read README.md and DEPLOYMENT.md before changing deployment behavior.

## Commands

- Offline workload preview: `kubectl kustomize .`
- Full validation: `python scripts/validate.py` (install scripts/requirements.txt;
  requires kubectl and Flux CLI).
- Runtime status: `flux get kustomizations --context=<production-context>`.
- Application status: `kubectl --context=<production-context> get pods -n lonctus`.

## Conventions

- Application namespace is `lonctus`; monitoring namespace is `monitoring`.
- Workloads belong to exactly one Flux Kustomization in clusters/production/workloads.yaml.
- Keep placeholder Secrets excluded from Kustomize. Never commit actual credentials.
- Preserve PVC names, namespaces and prune protection during refactors.
- Keep generated Flux components and their version header intact; regenerate with Flux.
- Container image versions live in workload manifests. Avoid an overriding Kustomize
  image tag that would shadow Renovate's changes.
- Custom application images track `latest@sha256:...`; updates require PR review.
- Tile generation is a separate Job, recreated on template changes. Shared tile
  storage must not wait for a consumer before the generator can reconcile.
- Tileserver is intentionally scaled to zero until enabled through Git.
- Clerk issuer/JWKS are under https://clerk.lonctus.com. Protected Services route
  through Envoy on port 8000. Changing a ConfigMap may require a pod rollout.
- Use an explicit production kube context for cluster operations; do not assume
  the developer's current context is production.
