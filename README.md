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

Frontend, docs, and GeoPulse releases publish stable `MAJOR.MINOR.PATCH` image
tags. Renovate updates versioned images and pins their digests; automatic merging
is disabled. Existing `latest` references are retained until a real published
release is adopted with `python3 scripts/adopt-release.py <app> <version>`.
The tile-generator Job is retired; its empty Flux bundle removes existing generator Jobs and Pods while retaining tile storage.
See the semantic-release migration in [DEPLOYMENT.md](DEPLOYMENT.md).

## Services

| Service | Namespace | Endpoint |
| --- | --- | --- |
| Frontend | lonctus | lonctus.com |
| Internal docs | lonctus | docs.lonctus.com (Clerk sign-in) |
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
  workloads.yaml             Namespaces, storage, apps, monitoring, generator cleanup
infrastructure/namespaces/   lonctus and monitoring namespaces
apps/                       Application Kustomize bundle
  frontend/, docs/, places-scraper/, martin/, tileserver/
  tileserver/storage/        Retained shared tile PVC
  tileserver/generator/      Empty cleanup bundle; inactive Job reference
  monitoring/               Separate monitoring Kustomize bundle
.github/workflows/           Renovate runner and pull request validation
renovate.json                Image, Flux and tooling update policy
scripts/bootstrap-flux.sh    Bootstrap with an explicit production context
scripts/validate.py          Offline graph, schema and resource validation
kustomization.yaml          Combined workload preview
```

Start with [Fresh Flux installation on Ubuntu](DEPLOYMENT.md#fresh-flux-installation-on-ubuntu).
The guide also covers runtime secrets, GitHub credentials, the image-push trigger,
and optional Argo CD cleanup. Committing configuration alone does
not install Flux or authorize Renovate: complete that setup to activate them.

## Local validation

For an overloaded Raspberry Pi using SD storage, see
[SD-card performance](docs/sd-card-performance.md) for reduced collection settings
and a reversible procedure to pause metrics ingestion.

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
