# AGENTS.md

GitOps repo: Kubernetes manifests for lonctus.com on K3s. Flux CD reconciles branch
`main` from `clusters/production`; Renovate opens image PRs. Deeper docs: README.md
(overview), DEPLOYMENT.md (install, rollback, operations), docs/postgresql.md
(database runbook — required before any PostgreSQL change). CLAUDE.md mirrors the
short version of these rules; keep them in sync.

## Commands

- Offline preview: `kubectl kustomize .` (root `kustomization.yaml` is preview only;
  Flux never reads it).
- Full validation — this is what CI runs, in this order:

  ```bash
  python3 -m venv /tmp/map-infra-validation-venv
  /tmp/map-infra-validation-venv/bin/pip install -r scripts/requirements.txt
  /tmp/map-infra-validation-venv/bin/python scripts/validate.py
  /tmp/map-infra-validation-venv/bin/python -m unittest discover -s scripts -p 'test_*.py'
  bash -n scripts/bootstrap-flux.sh backup/backup.sh backup/integration.sh postgres/smoke-test.sh
  shellcheck backup/backup.sh backup/integration.sh postgres/smoke-test.sh
  ```

  Renovate config is validated separately: `renovate-config-validator --strict renovate.json`
  (CI runs it inside the pinned Renovate container).
- `scripts/validate.py` needs `kubectl` **and** `flux` on PATH (it shells out to
  `flux build kustomization --dry-run`). Use the Flux CLI version from the
  `# Flux Version:` header in `clusters/production/flux-system/gotk-components.yaml`.
- Docker-based tests (no cluster, disposable containers):
  `docker build -t map-infra-backup:test backup` +
  `docker build -t map-infra-restore:test -f backup/restore.Dockerfile backup`,
  then `bash backup/integration.sh`.
- Cluster commands must pass `--context=<production-context>` explicitly; never
  assume the current context is production.
- Bootstrap: `bash scripts/bootstrap-flux.sh <production-kube-context>` (needs
  `GITHUB_TOKEN`; refuses if an Argo CD `map-infra` Application still exists).

## Validation rules you will otherwise break

`scripts/validate.py` is the source of truth — all of these are hard assertions:

- Every resource must be rendered by **exactly one** Flux Kustomization listed in
  `clusters/production/workloads.yaml` (dependsOn graph must be acyclic and known).
- The root preview (`kubectl kustomize .`) must render **exactly** the union of all
  Flux bundles. Adding a resource to one side only fails validation.
- No plaintext `Secret` may enter any reconciled bundle (placeholders are applied
  manually and stay out of `kustomization.yaml` `resources`).
- `Namespace` and `PersistentVolumeClaim` objects must carry the annotation
  `kustomize.toolkit.fluxcd.io/prune: disabled`. Preserve PVC names/namespaces.
- Every namespaced resource must live in a Namespace declared in the same preview.
- The `postgres` HelmRelease must keep: `releaseName: postgres`, target/storage
  namespace `database`, an `sha256:` image digest, `prune: disabled`, and
  `upgrade.remediation.retries: 0`. It may not be unsuspended until the
  `database.lonctus.com/postgis-image-verified: "true"` annotation is set and the
  image is no longer `bitnami/postgresql`.
- The `postgres-backups` CronJob must stay `suspend: true` while its image tag
  contains `adoption-required`.
- All YAML under `apps/`, `infrastructure/`, `clusters/`, `operations/` and
  `.github/workflows/` must parse, even files excluded from bundles.

## Image and Renovate conventions

- Image versions live in the workload manifests. Never add a Kustomize `images:`
  tag override — it shadows Renovate's edits.
- Custom app images (`kaljo14/my-map`, `kaljo14/docs`, `kaljo14/places-scraper`)
  use `latest@sha256:...` until a real release is adopted with
  `python3 scripts/adopt-release.py <app> <version>` (requires `docker buildx`;
  enforces linux/amd64 + linux/arm64). Result goes through a PR.
- Renovate's `kubernetes` manager only scans `apps/` and `infrastructure/`;
  `flux` scans `clusters/` and `infrastructure/`. Images under `operations/` or
  elsewhere are not auto-updated.
- `infrastructure/database/postgres/**` and `postgres/**` updates are disabled in
  `renovate.json` — database changes follow docs/postgresql.md only.
- CI reads the committed Flux version from `gotk-components.yaml`; regenerate that
  file with Flux, never hand-edit it.

## Intentional states — do not "fix" without a design decision

- Tileserver Deployment is deliberately scaled to zero; `tiles-pvc` must survive
  without a consumer (bundle `tile-storage` uses `wait: false`).
- `apps/tileserver/generator` is an intentionally **empty** bundle
  (`resources: []`) so Flux prunes the retired generator Job; `job.yaml` is an
  inactive reference excluded from Kustomize and Renovate.
- Namespaces and PVCs are protected from pruning; workloads use
  `deletionPolicy: Orphan`.
- `operations/postgres-restore` is excluded from Flux and the root preview
  (manual recovery environment only).
- Protected services (martin, places-scraper, tileserver) front the app with an
  Envoy sidecar on port 8000; Clerk issuer/JWKS are `https://clerk.lonctus.com`,
  roles: `admin`, `map-viewer`, `data-viewer`, `data-editor`. ConfigMap/config-file
  changes need a pod rollout to take effect.

## Testing notes

- Python unit tests live next to the code: `scripts/test_adopt_release.py`
  (run via `unittest discover`, not pytest).
- `backup/integration.sh` and `postgres/smoke-test.sh` are Docker-only and touch
  nothing in Kubernetes; CI runs them inside the image-build workflows
  (`.github/workflows/postgres-*-image.yaml`, manual `workflow_dispatch`).
- No application test suite lives here — this repo only validates manifests.
