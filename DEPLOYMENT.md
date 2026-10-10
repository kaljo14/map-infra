# Flux CD deployment and Renovate image updates

## Fresh Flux installation on Ubuntu

Use this path when there is no working GitOps installation to migrate. Flux
bootstrap installs its own controllers; an existing Flux installation is not
required. The Argo CD handover below is optional and only applies if the old
`map-infra` Application still exists, including an Application from a failed setup.

1. Ensure this repository's Flux configuration is pushed and merged into `main`.
   If an old Argo Application still watches `main`, detach it using section 2
   before merging. A failed installation does not necessarily remove its controller.
2. SSH into the Ubuntu server and install the command-line tools:

   ```bash
   sudo apt-get update
   sudo apt-get install -y curl git jq
   ```

   If this server has **no K3s installation**, install a single-node K3s server:

   ```bash
   curl -fsSL https://get.k3s.io -o /tmp/install-k3s.sh
   sudo sh /tmp/install-k3s.sh
   ```

   An existing K3s cluster can be used directly. Configure access for your user:

   ```bash
   mkdir -p "$HOME/.kube"
   sudo install -m 600 -o "$(id -u)" -g "$(id -g)" \
     /etc/rancher/k3s/k3s.yaml "$HOME/.kube/map-infra.yaml"
   export KUBECONFIG="$HOME/.kube/map-infra.yaml"
   export KUBE_CONTEXT="$(kubectl config current-context)"
   kubectl --context="$KUBE_CONTEXT" get nodes -o wide
   ```

3. Clone the configuration (or pull `main` in your existing checkout), then install
   the same Flux CLI version as the committed controllers:

   ```bash
   git clone --branch main https://github.com/kaljo14/map-infra.git
   cd map-infra
   flux_version=$(sed -n 's/^# Flux Version: v//p' \
     clusters/production/flux-system/gotk-components.yaml)
   curl -fsSL https://fluxcd.io/install.sh -o /tmp/install-flux.sh
   sudo env FLUX_VERSION="$flux_version" bash /tmp/install-flux.sh
   flux check --pre --context="$KUBE_CONTEXT"
   ```

   Resolve failed preflight checks before continuing. A fresh Flux install still
   needs the application prerequisites in section 1: PostgreSQL, runtime secrets,
   Traefik, Cloudflare Tunnel routing, and DNS. These are not installed
   by Flux bootstrap. The tile-generator Job is retired and is no longer deployed.

4. Create namespaces and provision the runtime secrets described in section 1:

   ```bash
   kubectl --context="$KUBE_CONTEXT" apply -k infrastructure/namespaces
   ```

5. Create a GitHub bootstrap token scoped to `kaljo14/map-infra` with Contents and
   Administration read/write access, and enter it at the terminal prompt:

   ```bash
   read -rsp 'GitHub bootstrap token: ' GITHUB_TOKEN
   echo
   export GITHUB_TOKEN
   bash scripts/bootstrap-flux.sh "$KUBE_CONTEXT"
   unset GITHUB_TOKEN
   ```

   This installs Flux and starts reconciling the application manifests from `main`.
   If the script reports an old Argo Application, perform the optional cleanup in
   section 2 and rerun this command.

6. Verify the installation, then enable Renovate using section 4:

   ```bash
   flux check --context="$KUBE_CONTEXT"
   flux get sources git --context="$KUBE_CONTEXT"
   flux get kustomizations --context="$KUBE_CONTEXT"
   kubectl --context="$KUBE_CONTEXT" -n lonctus get pods,pvc
   kubectl --context="$KUBE_CONTEXT" -n monitoring get pods,pvc
   ```

   Renovate runs in GitHub Actions and requires the `RENOVATE_TOKEN` repository
   secret. It does not need to be installed on Ubuntu. Run its workflow manually
   once to verify registry access and pull request creation.

## What is managed

Flux reads `kaljo14/map-infra`, branch `main`, path `clusters/production`. It polls
Git every minute. Workload reconciliation corrects drift every five minutes
(ten minutes for namespaces, tile storage, and the generator), and also runs when
new Git revisions arrive. Renovate opens PRs; merging a PR approves deployment.

Seven bundles include two staged database bundles and one empty cleanup bundle:

| Bundle | Depends on | Purpose |
| --- | --- | --- |
| namespaces | — | lonctus, monitoring and database |
| postgres | namespaces | Existing Helm release adoption; initially suspended |
| postgres-backups | namespaces | R2 backup CronJob (initially suspended) and Job metrics |
| tile-storage | namespaces | Create the retained tile PVC |
| map-apps | tile-storage | Frontend, docs, scraper, Martin, tileserver |
| monitoring | namespaces | Prometheus, Grafana, Loki, Promtail, VictoriaMetrics, exporters, Alertmanager |
| tile-generator | — | Empty cleanup bundle: prune the retired generator Job |

Tile storage uses `wait: false`: K3s local-path provisioning can wait for a consumer
before binding the PVC. The tileserver remains scaled to zero, so the retained PVC
may have no active consumer.

The generator bundle now has `resources: []` and `prune: true`. On reconciliation,
Flux removes the previously managed `lonctus/grid-tile-generator` Job and Kubernetes
removes its dependent Pods (including names such as `grid-tile-generator-24pph`).
The bundle is retained because deleting it with `deletionPolicy: Orphan` would
leave the Job behind. Its `job.yaml` is an inactive reference, excluded from both
Kustomize builds and Renovate. `tiles-pvc` remains managed separately and protected.

After merging this change to `main`, reconcile and verify on the production cluster:

```bash
flux reconcile kustomization flux-system --with-source --context="$KUBE_CONTEXT"
flux reconcile kustomization tile-generator --with-source --context="$KUBE_CONTEXT"
kubectl --context="$KUBE_CONTEXT" -n lonctus get jobs,pods -l job-name=grid-tile-generator
kubectl --context="$KUBE_CONTEXT" -n lonctus get job grid-tile-generator --ignore-not-found
kubectl --context="$KUBE_CONTEXT" -n lonctus get pvc tiles-pvc
```

The generator queries should return no resources; the PVC should still exist.
Once the cleanup bundle has reconciled and its inventory is empty on every cluster,
it can be removed in a later Git change.

Namespaces and PVCs are protected from pruning. Workloads have `deletionPolicy:
Orphan`, so deleting a Flux Kustomization retains its workloads; removing a workload
from a live bundle still prunes it, except protected resources. Back up persistent
data before the handover. Argo CD's pruning is separate from Flux's protection.

## 1. Prepare the production cluster

Install `kubectl`, Flux CLI (matching the version in
`clusters/production/flux-system/gotk-components.yaml`), and `jq`. Select the real
production context explicitly; a local kind context is not the production cluster.

```bash
export KUBE_CONTEXT=your-production-context
kubectl --context="$KUBE_CONTEXT" get nodes
flux check --pre --context="$KUBE_CONTEXT"
```

The preflight checks whether your Kubernetes version supports this Flux release.
Upgrade K3s first if it fails. Traefik, Cloudflare Tunnel routing, and the storage
provisioner are prerequisites. The existing PostgreSQL release
has a staged adoption configuration; follow [PostgreSQL and R2 setup](docs/postgresql.md)
before enabling it. Its manually installed PostGIS must first be baked into a
tested image. Backup activation is independent of database adoption.

Preserve existing secrets. For a fresh cluster, create namespaces with
`kubectl --context="$KUBE_CONTEXT" apply -k infrastructure/namespaces`, then provision:

| Namespace | Secret | Required keys |
| --- | --- | --- |
| lonctus | places-scraper-secret | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, POSTGRES_CONN_STRING |
| lonctus | scraper-gg-secret | GOOGLE_PLACES_API_KEY |
| monitoring | alertmanager-smtp | smtp-password |

`secret-placeholder.yaml` files are examples, excluded from every bundle. Supply
real values out of band; do not commit them. The frontend Clerk publishable key is
a build-time setting, not a runtime Secret. Private container registries also
require Kubernetes image pull credentials; Renovate's registry credentials do not
provide credentials to cluster nodes.

For a fresh installation, create missing secrets from local files outside the Git
checkout. Make a private directory first:

```bash
install -d -m 700 "$HOME/.config/map-infra"
```

Use your editor to create these files with real values, one `KEY=value` per line
(without shell `export` prefixes):

- `places.env`: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, and
  `POSTGRES_CONN_STRING`. The connection string must reach your provisioned database.
- `scraper.env`: `GOOGLE_PLACES_API_KEY`.
- `smtp.env`: `smtp-password`.

Then create the missing secrets:

```bash
chmod 600 "$HOME/.config/map-infra/places.env" \
  "$HOME/.config/map-infra/scraper.env" "$HOME/.config/map-infra/smtp.env"
kubectl --context="$KUBE_CONTEXT" -n lonctus create secret generic places-scraper-secret \
  --from-env-file="$HOME/.config/map-infra/places.env"
kubectl --context="$KUBE_CONTEXT" -n lonctus create secret generic scraper-gg-secret \
  --from-env-file="$HOME/.config/map-infra/scraper.env"
kubectl --context="$KUBE_CONTEXT" -n monitoring create secret generic alertmanager-smtp \
  --from-env-file="$HOME/.config/map-infra/smtp.env"
```

Skip creation for secrets that already exist with valid values.

## 2. Optional: hand over from an existing Argo CD Application

Do this **before merging the migration to main**, while the old Argo Application
still points at the old tree. Save its configuration, turn off automatic sync, then
orphan it without deleting workloads:

```bash
kubectl --context="$KUBE_CONTEXT" -n argocd get application map-infra -o json |
  jq '{apiVersion,kind,metadata:{name:.metadata.name,namespace:.metadata.namespace},spec}' \
  > /tmp/map-infra-argocd.json
kubectl --context="$KUBE_CONTEXT" -n argocd patch application map-infra \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Wait for any active Argo operation to finish (or terminate it in Argo CD). If a
parent Application or ApplicationSet creates `map-infra`, remove that parent entry
without cascading deletion first, so it cannot recreate the Application.

```bash
kubectl --context="$KUBE_CONTEXT" -n argocd patch application map-infra \
  --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl --context="$KUBE_CONTEXT" -n argocd delete application map-infra
```

Removing the resource finalizer is the documented non-cascading Argo deletion
procedure. Do not delete the namespaces, PVCs, or workloads. The application
continues running while its GitOps controller is handed over. A new installation
with no Argo Application skips this section.

Merge the migration into `main` and pull that revision locally. The root build
preserves all existing workload names; application namespace transformers also
place the formerly implicit Services and scraper Ingress in `lonctus`.

## 3. Bootstrap Flux

Load `GITHUB_TOKEN` from your credential manager. Bootstrap needs access to write
repository contents and add a deploy key. For an existing repository, a GitHub
fine-grained PAT needs Contents and Administration read/write and Metadata read.
The bootstrap token is separate from Renovate's token.

```bash
bash scripts/bootstrap-flux.sh "$KUBE_CONTEXT"
unset GITHUB_TOKEN
```

The script checks prerequisites and refuses to proceed if the old `map-infra`
Application still exists. Bootstrap commits its source configuration to `main`,
installs the committed Flux release, and registers a read-only SSH deploy key.
Allow that bootstrap commit through repository branch rules if required. Keep the
`gotk-components.yaml` generated header: Renovate uses it to update Flux as a unit.

```bash
flux get sources git --context="$KUBE_CONTEXT"
flux get kustomizations --context="$KUBE_CONTEXT"
kubectl --context="$KUBE_CONTEXT" -n lonctus get pods,svc,ingress,pvc
kubectl --context="$KUBE_CONTEXT" -n monitoring get pods,pvc
```

All seven Kustomizations, including the empty generator cleanup bundle, should become Ready.
The PostgreSQL HelmRelease and backup CronJob remain suspended until their runbook
activation steps are completed; these bundles intentionally use `wait: false`.
The tileserver Deployment remains at `replicas: 0`. Keep Argo CD installed
if it manages other applications. This repository only replaces its own Application.

## 4. Enable Renovate in GitHub

This repository runs Renovate in GitHub Actions, on a fifteen-minute schedule, with
manual and `repository_dispatch` triggers. The runner discovers `map-infra`,
`my-map`, and `geoapi` under `kaljo14` when its token can access them. The local
`neofyis-geopulse` checkout corresponds to `geoapi`. Each repository needs its own
`renovate.json`; repositories without one get a configuration PR first. Merge that
PR before expecting dependency updates. Do not also enable a hosted Renovate
installation for these repositories: use one runner to avoid competing PRs.

The runner scans only these repositories under `kaljo14`: `map-infra`, `my-map`, and `geoapi` (the local `neofyis-geopulse`
checkout). Each repository needs its own `renovate.json`; repositories without
one get a configuration PR first. Merge that PR before expecting dependency
updates.


In **Settings → Secrets and variables → Actions**, create `RENOVATE_TOKEN`. Use a
bot account PAT with access to every target repository, including private ones. The account must be able to push branches and create PRs there. A classic PAT needs `repo` and `workflow`;
for a fine-grained PAT, follow Renovate's permissions reference linked below
(Contents, Pull requests, Issues, Commit statuses, and Workflows read/write;
Dependabot alerts read; Members read when applicable to an organization).

The default workflow `GITHUB_TOKEN` is not used as the Renovate credential, so
Renovate's pull requests can trigger the validation workflow.

For private Docker Hub images or authenticated registry access, also set
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` with pull access. These credentials stay
in GitHub Secrets and are passed to Renovate through host rules.

Enable Actions, then run **Actions → Renovate → Run workflow** on `main`. Check the
workflow log for the discovered repository list and verify that the Dependency
Dashboard and dependency PRs appear in each configured repository. Missing
credentials produce an explicit workflow error. Scheduled runs require the workflow
on the default branch; ensure the repository default is `main`. GitHub can delay scheduled jobs
and disable schedules in inactive public repositories, so the dispatch trigger is
useful for image builds.

Frontend, docs, and scraper accept stable `MAJOR.MINOR.PATCH` image versions.
Renovate pins digests and proposes subsequent version upgrades. Existing `latest`
references retain their legacy digest tracking until the first semantic release
is adopted using section 5. Other images keep their existing version policies;
the retired tile-generator manifest is excluded from Renovate. Envoy sidecars update together. Major third-party upgrades require
approval in the Dependency Dashboard. Automatic merge is disabled.

Use branch protection/rulesets to require **manifests** and **renovate-config**
checks on `main`, plus your desired review approval. Flux deploys anything merged
to `main`; the repository configuration alone does not enforce GitHub branch rules.

## 5. Semantic releases and image-push notifications

The frontend, docs, and GeoPulse producer workflows publish semantic image tags:

| Producer | Git tag example | Image tag example |
| --- | --- | --- |
| `my-map` | `v1.2.3` | `kaljo14/my-map:1.2.3` |
| `docs` | `v1.2.3` | `kaljo14/docs:1.2.3` |
| `geoapi` (local `neofyis-geopulse`) | `v1.2.3` | `kaljo14/places-scraper:1.2.3` |

Version sequences are independent. Push a new stable `vMAJOR.MINOR.PATCH` tag
from the intended release commit after the workflow changes are on `main`.
Main-branch pushes run checks but no longer update `latest`. The stable release
path rejects prereleases, build metadata, and leading zeroes. Never move a release
tag to different source; use a new version for corrections.

### Adopt the first semantic release

Keep existing deployments until each producer has successfully published a real
version. Then run the adoption command from this checkout with the actual version:

```bash
python3 scripts/adopt-release.py frontend 1.2.3
python3 scripts/adopt-release.py docs 1.2.3
python3 scripts/adopt-release.py places-scraper 1.2.3
```

These are independent examples, not required matching version numbers. The command
uses Docker Buildx registry inspection (log in first for private images), requires
AMD64 and ARM64 manifests, and writes `image:version@sha256:digest`. Registry
failures leave the file unchanged. Review and merge each manifest diff to `main`.
Renovate then proposes later stable releases and digest changes; Flux deploys
merged updates. A temporary rule keeps legacy `latest` references on digest
tracking until adoption; a notification does not migrate those references.

The retired `grid-tile-generator` is no longer deployed or tracked for image updates.

For prompt detection, add this step **after the successful image push** in each
producer repository's GitHub Actions workflow. Create `MAP_INFRA_DISPATCH_TOKEN`
in that repository, scoped to `kaljo14/map-infra` with Contents write access:

```yaml
- name: Notify map-infra about the new image
  env:
    GH_TOKEN: ${{ secrets.MAP_INFRA_DISPATCH_TOKEN }}
  run: |
    gh api --method POST repos/kaljo14/map-infra/dispatches \
      -f event_type=image-pushed
```

This requests a fresh registry scan; the workflow does not trust an image tag or
shell command from the event payload. The frontend, docs, and GeoPulse workflows include this step, conditionally
enabled when `MAP_INFRA_DISPATCH_TOKEN` is set. The schedule remains a fallback
if a notification is missed. Multiple pushes before a scan/merge can be combined
into one open PR for the most recent digest; this is not one PR per push.

## Docs site at docs.lonctus.com

The `kaljo14/docs` repository builds the internal docs image for AMD64 and ARM64.
Set its Actions secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` with push access
to `kaljo14/docs`; optionally set `MAP_INFRA_DISPATCH_TOKEN` as described above.
Create the Docker Hub repository first. Prefer a private repository because the
image contains the internal documentation; app sign-in does not protect
files downloaded directly from a public registry.

Before merging `apps/docs` into `main`:

1. Push a stable release tag in docs and verify its semantic image was published.
   Run `python3 scripts/adopt-release.py docs <version>` to select it before merging.
2. Route `docs.lonctus.com` through Cloudflare Tunnel to Traefik's HTTP NodePort.
   Cloudflare handles public TLS; the tunnel and DNS are managed outside this
   repository. Verify the tunnel can reach Traefik over IPv4.
3. Configure `docs.lonctus.com` under the same Clerk production root domain as
   the frontend, and set the docs repository variable `CLERK_PUBLISHABLE_KEY` to
   that instance's publishable key before building the docs image. Provision the
   runtime `docs-clerk` Secret in `lonctus` with that same publishable key and its
   matching secret key. Read values interactively to keep them out of shell history:

   ```bash
   printf 'Clerk publishable key: '
   read -r -s DOCS_CLERK_PUBLISHABLE_KEY
   echo
   printf 'Clerk secret key: '
   read -r -s DOCS_CLERK_SECRET_KEY
   echo
   kubectl --context="$KUBE_CONTEXT" -n lonctus create secret generic docs-clerk \
     --from-literal=NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY="$DOCS_CLERK_PUBLISHABLE_KEY" \
     --from-literal=CLERK_SECRET_KEY="$DOCS_CLERK_SECRET_KEY" \
     --dry-run=client -o yaml | kubectl --context="$KUBE_CONTEXT" apply -f -
   unset DOCS_CLERK_PUBLISHABLE_KEY DOCS_CLERK_SECRET_KEY
   ```

4. If the image is private, configure `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
   in map-infra for Renovate's read access, and create a cluster pull secret from
   a private Docker config file with pull-only credentials:

   ```bash
   kubectl --context="$KUBE_CONTEXT" -n lonctus create secret generic docs-registry \
     --type=kubernetes.io/dockerconfigjson \
     --from-file=.dockerconfigjson="$HOME/.config/map-infra/docs-docker-config.json"
   ```

   Add `imagePullSecrets: [{name: docs-registry}]` under the docs Deployment's
   `spec.template.spec` before merging. Omit it for a public image. Registry and
   Clerk credentials must never be committed to Git.

Flux's existing `map-apps` bundle includes `apps/docs`. The adoption command
pins the first semantic release to its verified digest. Renovate proposes later
version/digest updates; merge those PRs to deploy them.

For an existing BasicAuth deployment, roll out the Clerk-protected docs image
while the BasicAuth Middleware is still active. Verify sign-in on that image,
then apply the ingress change that removes the Middleware. This avoids an
interval where the old image is reachable without authentication.

After merging, check the rollout and ingress:

```bash
flux reconcile kustomization map-apps --with-source --context="$KUBE_CONTEXT"
kubectl --context="$KUBE_CONTEXT" -n lonctus rollout status deployment/docs
kubectl --context="$KUBE_CONTEXT" -n lonctus get ingress docs
curl -I https://docs.lonctus.com/            # Expect a redirect to /sign-in
curl -I https://docs.lonctus.com/api/search  # Expect 401 without a session
```

Open `https://docs.lonctus.com/` in a browser and verify that Clerk sign-in
returns to the requested docs page. After the Clerk-protected image is serving
successfully and the old Middleware is pruned, remove the old secret:

```bash
kubectl --context="$KUBE_CONTEXT" -n lonctus delete secret docs-basic-auth --ignore-not-found
```

## Operations and rollback

Change manifests in Git and merge a PR. To reconcile immediately:

```bash
flux reconcile source git flux-system --context="$KUBE_CONTEXT"
flux reconcile kustomization map-apps --with-source --context="$KUBE_CONTEXT"
flux get kustomizations --context="$KUBE_CONTEXT"
flux logs --level=error --context="$KUBE_CONTEXT"
```

Revert a merged image PR to roll back to its previous digest. Keep old digests in
your registry so they remain pullable. The retired generator is not rerun by image updates; reverting an image cannot
restore previous PVC data. ConfigMaps retain their existing names and
mount behavior; services that load configuration only at startup need a rollout
when configuration changes (for example, change a pod-template annotation in Git).

To return to Argo, first suspend `flux-system` and every workload Kustomization,
then revert the migration in Git and reapply `/tmp/map-infra-argocd.json`. Restore
one controller at a time. Do not delete Flux Kustomizations as a shortcut while
the parent is active, because the parent can recreate them.

## References

- [K3s installation](https://docs.k3s.io/quick-start)
- [K3s cluster access](https://docs.k3s.io/cluster-access)
- [Flux CLI installation](https://fluxcd.io/flux/installation/)
- [Flux GitHub bootstrap](https://fluxcd.io/flux/installation/bootstrap/github/)
- [Flux reconciliation, health and pruning](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [Argo CD non-cascading Application deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/)
- [Renovate Docker digest updates](https://docs.renovatebot.com/docker/)
- [Renovate GitHub token permissions](https://docs.renovatebot.com/modules/platform/github/)
- [Renovate GitHub Action](https://github.com/renovatebot/github-action)
