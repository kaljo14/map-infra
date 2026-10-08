# map-infra

Kubernetes manifests for **lonctus.com** on K3s, reconciled by **Flux CD**.
**Renovate** proposes container image updates through GitHub pull requests.

```text
Build and push an image to Docker Hub / GHCR
  → Renovate scans the registry (every 15 minutes, or image-pushed dispatch)
  → GitHub pull request updates the image tag/digest
  → validation passes and you merge to main
  → Flux fetches main and reconciles the cluster
```

Application images track `latest` with immutable digests. Rebuilding `latest`
produces a digest update PR; pushing an unrelated tag does not. Automatic merging
is disabled. A pending PR may be updated with subsequent pushes.

## Services

| Service | Namespace | Endpoint |
| --- | --- | --- |
| Frontend | lonctus | lonctus.com |
| Internal docs | lonctus | docs.lonctus.com (password protected) |
| Places scraper | lonctus | places-scraper.lonctus.com |
| Martin | lonctus | martin.lonctus.com |
| Tileserver | lonctus | tiles.lonctus.com |
| Monitoring stack | monitoring | Existing Grafana / Loki ingress routes |

Traefik handles ingress and cert-manager handles TLS. Envoy sidecars validate
Clerk JWTs and apply role rules for protected services. Clerk issuer and JWKS are
under `https://clerk.lonctus.com`; roles are `admin`, `map-viewer`, `data-viewer`,
and `data-editor`. The tileserver Deployment remains intentionally scaled to zero.

## Repository layout

```text
clusters/production/          Flux entrypoint and reconciliation graph
  flux-system/               Generated Flux controllers and Git source
  workloads.yaml             Namespaces, storage, apps, monitoring, generator
infrastructure/namespaces/   lonctus and monitoring namespaces
apps/                       Application Kustomize bundle
  frontend/, docs/, places-scraper/, martin/, tileserver/
  tileserver/storage/        Retained shared tile PVC
  tileserver/generator/      Image-driven tile generation Job
  monitoring/               Separate monitoring Kustomize bundle
.github/workflows/           Renovate runner and pull request validation
renovate.json                Image, Flux and tooling update policy
scripts/bootstrap-flux.sh    Bootstrap with an explicit production context
scripts/validate.py          Offline graph, schema and resource validation
kustomization.yaml          Combined workload preview
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for the Argo CD handover, GitHub credentials,
image-push trigger, bootstrap, and rollback. Committing configuration alone does
not install Flux or authorize Renovate: complete that setup to activate them.

## Local validation

Install `kubectl`, the Flux CLI version recorded in `gotk-components.yaml`, and
Python 3, then run:

```bash
python3 -m venv /tmp/map-infra-validation-venv
/tmp/map-infra-validation-venv/bin/pip install -r scripts/requirements.txt
/tmp/map-infra-validation-venv/bin/python scripts/validate.py
kubectl kustomize .
```

The root build previews workloads; `clusters/production` is Flux's entrypoint.
GitHub Actions validates both and checks Renovate configuration on every PR.
