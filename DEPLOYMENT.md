# Flux CD deployment and Renovate image updates

## What is managed

Flux reads `kaljo14/map-infra`, branch `main`, path `clusters/production`. It polls
Git every minute. Workload reconciliation corrects drift every five minutes
(ten minutes for namespaces, tile storage, and the generator), and also runs when
new Git revisions arrive. Renovate opens PRs; merging a PR approves deployment.

Five Flux Kustomizations own the existing stack:

| Bundle | Depends on | Purpose |
| --- | --- | --- |
| namespaces | — | lonctus and monitoring |
| tile-storage | namespaces | Create the retained tile PVC |
| map-apps | tile-storage | Frontend, scraper, Martin, tileserver |
| monitoring | namespaces | Prometheus, Grafana, Loki, Promtail, VictoriaMetrics, exporters, Alertmanager |
| tile-generator | tile-storage | Run the tile generation Job |

Tile storage uses `wait: false`: K3s local-path provisioning can wait for a consumer
before binding the PVC. Requiring Bound before creating the generator would deadlock.
The Job has a resource-level force annotation so an image change recreates its
immutable pod template. A merged generator update runs generation again and can
change data in `tiles-pvc`. No TTL is set on the completed Job, so Flux does not
recreate it on each reconciliation.

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
Upgrade K3s first if it fails. Traefik, cert-manager, the ingress ClusterIssuer,
the storage provisioner, and the external PostgreSQL database are prerequisites;
the original repository did not install them.

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

## 2. Hand over from Argo CD

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

All five workload bundles should become Ready. The generator may take up to thirty
minutes; the tileserver Deployment remains at `replicas: 0`. Keep Argo CD installed
if it manages other applications. This repository only replaces its own Application.

## 4. Enable Renovate in GitHub

This repository runs Renovate in GitHub Actions, on a fifteen-minute schedule, with
manual and `repository_dispatch` triggers. Do not also enable a hosted Renovate
installation for this repository: use one runner to avoid competing PRs.

In **Settings → Secrets and variables → Actions**, create `RENOVATE_TOKEN`. Use a
bot account PAT with repository access. A classic PAT needs `repo` and `workflow`;
for a fine-grained PAT, follow Renovate's permissions reference linked below
(Contents, Pull requests, Issues, Commit statuses, and Workflows read/write;
Dependabot alerts read; Members read when applicable to an organization).

The default workflow `GITHUB_TOKEN` is not used as the Renovate credential, so
Renovate's pull requests can trigger the validation workflow.

For private Docker Hub images or authenticated registry access, also set
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` with pull access. These credentials stay
in GitHub Secrets and are passed to Renovate through host rules.

Enable Actions, then run **Actions → Renovate → Run workflow** on `main`. Verify
that the Dependency Dashboard and image PRs appear. Missing credentials produce
an explicit workflow error. Scheduled runs require the workflow on the default
branch; ensure the repository default is `main`. GitHub can delay scheduled jobs
and disable schedules in inactive public repositories, so the dispatch trigger is
useful for image builds.

The frontend and scraper retain their previous digests and now explicitly track
`latest`. Other images initially retain their existing tags; Renovate's first PRs
pin those tags to digests. Merge those initial pinning PRs to make all container
pulls reproducible. Until then, a mutable tag can still change on a pod restart.
Envoy sidecars update together. Major third-party upgrades require approval in the
Dependency Dashboard; ordinary image digest PRs do not. Automatic merge is disabled.

Use branch protection/rulesets to require **manifests** and **renovate-config**
checks on `main`, plus your desired review approval. Flux deploys anything merged
to `main`; the repository configuration alone does not enforce GitHub branch rules.

## 5. Trigger Renovate after an image push

The application images currently track these Docker Hub tags:

- `kaljo14/my-map:latest`
- `kaljo14/places-scraper:latest`
- `kaljo14/grid-tile-generator:latest`

A successful build must push the tracked tag. A new digest behind that tag opens
or updates a PR on the next scan. Pushing only a SHA tag or an unrelated release
tag does not move `latest` and therefore does not trigger an update for it. To
switch to semantic release tags, change the image tag and the `allowedVersions`
rule together.

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
shell command from the event payload. Producer repositories are outside this
repository and must receive the step themselves. The schedule remains a fallback
if a notification is missed. Multiple pushes before a scan/merge can be combined
into one open PR for the most recent digest; this is not one PR per push.

## Operations and rollback

Change manifests in Git and merge a PR. To reconcile immediately:

```bash
flux reconcile source git flux-system --context="$KUBE_CONTEXT"
flux reconcile kustomization map-apps --with-source --context="$KUBE_CONTEXT"
flux get kustomizations --context="$KUBE_CONTEXT"
flux logs --level=error --context="$KUBE_CONTEXT"
```

Revert a merged image PR to roll back to its previous digest. Keep old digests in
your registry so they remain pullable. Reverting a generator image reruns the Job;
it does not restore previous PVC data. ConfigMaps retain their existing names and
mount behavior; services that load configuration only at startup need a rollout
when configuration changes (for example, change a pod-template annotation in Git).

To return to Argo, first suspend `flux-system` and every workload Kustomization,
then revert the migration in Git and reapply `/tmp/map-infra-argocd.json`. Restore
one controller at a time. Do not delete Flux Kustomizations as a shortcut while
the parent is active, because the parent can recreate them.

## References

- [Flux GitHub bootstrap](https://fluxcd.io/flux/installation/bootstrap/github/)
- [Flux reconciliation, health and pruning](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [Argo CD non-cascading Application deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/)
- [Renovate Docker digest updates](https://docs.renovatebot.com/docker/)
- [Renovate GitHub token permissions](https://docs.renovatebot.com/modules/platform/github/)
- [Renovate GitHub Action](https://github.com/renovatebot/github-action)
