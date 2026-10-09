# PostgreSQL, PostGIS and Cloudflare R2 backups

## Current state and activation order

The production information below was supplied from the **Raspberry Pi**, not the
developer machine's kubeconfig:

| Item | Verified value |
| --- | --- |
| Release / namespace | `postgres` / `database` |
| Helm chart | Bitnami `postgresql`, version `18.1.11` |
| Server | PostgreSQL `18.1`, ARM64 |
| Extensions | PostGIS / topology / Tiger `3.6.1`, fuzzystrmatch `1.2` |
| Database sizes | geopulse 1622 MB; places_scraper 243 MB; keycloak 12 MB; postgres 7662 kB |
| Data PVC | `data-postgres-postgresql-0`, 3 GiB, `local-path` |
| Credentials | `postgres-auth-secret`, admin key `postgres-password` |
| Initialization scripts | `postgres-init-scripts` |

**The live PostGIS libraries were installed inside the pod. A replacement pod
will lose them. Do not restart or upgrade production until the permanent image
has been tested and a backup restored successfully.**

The committed HelmRelease and backup CronJob both start suspended. Applying these
manifests registers the configuration without upgrading the database or starting
the schedule. Backups use the existing Service and can be enabled before Helm
adoption. The separate `database-restore` environment is excluded from Flux.

Activate in this order:

1. Create private R2 storage and save credentials offsite.
2. Publish the backup and recovery images; deploy the suspended backup manifests.
3. Initialize the encrypted repository and take a successful manual backup.
4. Restore into a fresh, separate server and check application data.
5. Enable the nightly CronJob.
6. Build/test the permanent PostGIS image, then adopt the existing Helm release.

The code and manifests are implementation artifacts, not evidence that a live
backup has succeeded. Keep the schedule and HelmRelease suspended until their
respective activation checks are complete.

## 1. Create the Cloudflare R2 bucket

In the Cloudflare dashboard:

1. Open **Storage & databases → R2 Object Storage** and enable R2 if prompted.
   Cloudflare may require billing details to enable the subscription.
2. Create a bucket, for example `lonctus-postgres-backups`. Select **Standard**
   storage. Keep public access, `r2.dev` access and custom domains disabled.
3. Open **Manage R2 API tokens** and create an account API token (or user token if
   that is what your account provides). Choose **Object Read & Write** and restrict
   it to this one bucket. Restic needs list/read/write/delete for locks and pruning.
4. Save the **Access Key ID**, **Secret Access Key**, and **S3 API endpoint**. The
   endpoint normally looks like `https://ACCOUNT_ID.r2.cloudflarestorage.com`;
   use the exact endpoint shown, including any jurisdiction-specific hostname.
5. Generate a separate strong restic password and save it in a password manager
   outside the cluster. **Losing this password makes the backups unrecoverable.**

Do not paste credentials into chat or commit them to Git. Do not add expiration
or archive lifecycle rules to restic objects: snapshots share encrypted data
chunks and deleting objects by age can break retained backups. Restic performs
retention itself. An incomplete multipart-upload cleanup rule is separate and
can remain enabled.

R2 Standard currently includes **10 GB-month storage**, 1 million Class A and
10 million Class B operations per month, with free egress. This is an allowance,
not a spending cap. Seven raw copies of ~1.9 GiB would exceed it; compression and
deduplication help but cannot guarantee free storage. Check the R2 usage dashboard
after the first backup and after a week; configure billing notifications and
adjust retention to your budget. Keep some offsite history even when reducing it.
[Cloudflare pricing](https://developers.cloudflare.com/r2/pricing/),
[S3 credentials](https://developers.cloudflare.com/r2/api/tokens/).

## 2. Create the runtime storage Secret

Run the following on the production server, from this repository checkout.
These instructions use Bash, `kubectl`, `jq`, Helm, and Flux. Select and inspect
the **production** context explicitly; the developer machine's default context
is unrelated.

```bash
kubectl config get-contexts
export KUBE_CONTEXT=YOUR_PRODUCTION_CONTEXT
kubectl --context="$KUBE_CONTEXT" get nodes -o wide
install -d -m 700 "$HOME/.config/map-infra/postgres-private"
umask 077
```

Use an editor to create
`$HOME/.config/map-infra/postgres-private/r2.env` with real values, without quotes
or `export` prefixes:

```dotenv
RESTIC_REPOSITORY=s3:https://ACCOUNT_ID.r2.cloudflarestorage.com/lonctus-postgres-backups/postgres
RESTIC_PASSWORD=YOUR_LONG_RANDOM_RESTIC_PASSWORD
AWS_ACCESS_KEY_ID=YOUR_BUCKET_SCOPED_ACCESS_KEY
AWS_SECRET_ACCESS_KEY=YOUR_BUCKET_SCOPED_SECRET_KEY
```

Then create the Secret without printing its contents:

```bash
chmod 600 "$HOME/.config/map-infra/postgres-private/r2.env"
kubectl --context="$KUBE_CONTEXT" -n database create secret generic postgres-backup-storage \
  --from-env-file="$HOME/.config/map-infra/postgres-private/r2.env"
```

The database password is already referenced from `postgres-auth-secret`; do not
rotate or recreate it. The backup account is the existing `postgres` superuser so
all databases, owners, grants, and role password hashes can be captured.

## 3. Publish images and deploy the suspended backup configuration

Merge the reviewed repository changes with both suspension flags still `true`.
In GitHub Actions, run **Build PostgreSQL backup image**. It first runs a disposable
Docker backup/restore test with PostGIS, topology, Tiger, multiple databases,
ownership, grants, and the restore guards. It then publishes AMD64 and ARM64 images.

Copy both immutable image references from the workflow summary into:

- `infrastructure/database/backups/cronjob.yaml`: the backup client image.
- `operations/postgres-restore/server.yaml`: the recovery server image.

Keep the tag **and** `@sha256:...` digest. The placeholders deliberately do not
refer to published images. GHCR packages must be readable by the cluster: either
make these code-only image packages public or provision an `imagePullSecret`
in `database` and `database-restore` and reference it in both Pod specs.

Merge those image pins, then:

```bash
flux reconcile kustomization flux-system --with-source --context="$KUBE_CONTEXT"
flux reconcile kustomization postgres-backups --with-source --context="$KUBE_CONTEXT"
kubectl --context="$KUBE_CONTEXT" -n database get cronjob postgres-backup
```

The backup client uses PostgreSQL **18** tools; it refuses another source major.
The recovery server installs PostGIS libraries into its image during the build.
Its OS packages can contain a newer PostGIS patch release, so check the actual
restored extension versions and application queries during the drill.

The Job needs scratch disk space for a complete logical dump, plus restic working
space. It uses disk-backed `emptyDir`, capped at 18 GiB, with a 20 GiB Pod ephemeral
storage limit. Confirm free space on the node before running it. The restore drill
also creates a separate 6 GiB PVC. Do not run simultaneous manual operations.

## 4. Initialize and run the first backup

This command creates a one-off Job from the CronJob without unsuspending its
schedule. Run it with `OPERATION=init` **once** to initialize the repository.
Then repeat it with `OPERATION=backup` to take the first backup.

```bash
OPERATION=init  # Next: backup. Other operations: snapshots, check, stats.
PG_JOB="postgres-${OPERATION}-$(date +%s)"
kubectl --context="$KUBE_CONTEXT" -n database create job "$PG_JOB" \
  --from=cronjob/postgres-backup --dry-run=client -o json |
  jq --arg operation "$OPERATION" '.spec.template.spec.containers[0].args=[$operation]' |
  kubectl --context="$KUBE_CONTEXT" -n database create -f -
kubectl --context="$KUBE_CONTEXT" -n database get pods -l job-name="$PG_JOB" -w
# Once the Pod is Running, stop the watch with Ctrl-C:
kubectl --context="$KUBE_CONTEXT" -n database logs -f "job/$PG_JOB"
kubectl --context="$KUBE_CONTEXT" -n database get job "$PG_JOB"
```

Require Job `Complete` / `1/1` before proceeding. If it fails, inspect its logs and
`kubectl --context="$KUBE_CONTEXT" -n database describe job "$PG_JOB"`. Do not
reinitialize a repository after a connection/password failure. Failed Jobs do not
retry automatically, and a dump failure cannot reach snapshot upload or pruning.

Run `OPERATION=snapshots` to record the explicit snapshot ID. Run `OPERATION=stats`
to inspect the referenced repository data size; R2's dashboard is the billing
source of truth. `OPERATION=check` reads and verifies all stored data and can take
longer than the metadata check run after each backup.

Each snapshot contains `roles.sql`, one custom-format archive per non-template
database, and `manifest.json` with source identity, extension versions and file
hashes. Dumps are consistent per database; separate databases do not share one
transaction snapshot. Avoid database/role/schema changes during backups. Custom
template databases and tablespace placement are not reproduced; tables restore
to the destination's default tablespace.

## 5. Restore rehearsal or disaster recovery

The default recovery target is a **new server and new volume**. Never mount the
Bitnami production PVC into the official PostgreSQL recovery image: directory
layouts and startup conventions differ.

Generate a bootstrap password into a private file; create a Secret in both
namespaces (the server needs it in `database-restore`, the client in `database`):

```bash
umask 077
openssl rand -hex 32 | tr -d '\n' > "$HOME/.config/map-infra/postgres-private/restore-password"
kubectl --context="$KUBE_CONTEXT" create namespace database-restore
for ns in database database-restore; do
  kubectl --context="$KUBE_CONTEXT" -n "$ns" create secret generic postgres-restore-auth \
    --from-file=password="$HOME/.config/map-infra/postgres-private/restore-password"
done
kubectl --context="$KUBE_CONTEXT" apply -k operations/postgres-restore
kubectl --context="$KUBE_CONTEXT" -n database-restore rollout status statefulset/postgres-restore
```

If the namespace or Secrets already exist, inspect them before reusing them; do not
regenerate a password for a server whose volume was already initialized. The
bootstrap username is `restore_admin`, which must not exist in the source backup.
The NetworkPolicy allows only backup Pods in `database` to connect to this server.

Select a snapshot from `OPERATION=snapshots`, then create a restore Job:

```bash
SNAPSHOT=PASTE_EXPLICIT_SNAPSHOT_ID
RESTORE_HOST=postgres-restore.database-restore.svc.cluster.local
PG_JOB="postgres-restore-$(date +%s)"
kubectl --context="$KUBE_CONTEXT" -n database create job "$PG_JOB" \
  --from=cronjob/postgres-backup --dry-run=client -o json |
  jq --arg snapshot "$SNAPSHOT" --arg host "$RESTORE_HOST" '
    .spec.template.spec.containers[0].args =
      ["restore","--snapshot",$snapshot,"--confirm-target",$host] |
    .spec.template.spec.containers[0].env = [
      {name:"PGHOST",value:$host}, {name:"PGUSER",value:"restore_admin"},
      {name:"PGDATABASE",value:"postgres"},
      {name:"PGPASSWORD",valueFrom:{secretKeyRef:{name:"postgres-restore-auth",key:"password"}}}
    ]' |
  kubectl --context="$KUBE_CONTEXT" -n database create -f -
kubectl --context="$KUBE_CONTEXT" -n database get pods -l job-name="$PG_JOB" -w
# Once Running, Ctrl-C the watch and follow the logs:
kubectl --context="$KUBE_CONTEXT" -n database logs -f "job/$PG_JOB"
kubectl --context="$KUBE_CONTEXT" -n database get job "$PG_JOB"
```

The restore refuses the original PostgreSQL system identifier (even behind a
different hostname), an older server major, missing extension libraries, existing
application databases, user objects, or non-bootstrap roles. It verifies hashes
before importing, restores roles/owners/grants, and runs ANALYZE. It never switches
application endpoints. A failed partial restore must be retried on a **new empty
target**, not with relaxed checks.

Verify spatial libraries and data using the recovery Pod's local socket:

```bash
kubectl --context="$KUBE_CONTEXT" -n database-restore exec postgres-restore-0 -- \
  psql -X -U restore_admin -d geopulse -v ON_ERROR_STOP=1 \
  -c 'SELECT postgis_full_version();' \
  -c 'SELECT extname, extversion FROM pg_extension ORDER BY extname;'
```

Compare key table counts and sample geometries with production, check expected
owners and grants, and exercise representative Martin/scraper queries. Record the
snapshot ID, elapsed recovery time and results. Do this monthly and before upgrades.
Check the `places_scraper` and `keycloak` databases too. Logical consistency alone
does not prove application correctness.

When finished with a disposable drill, remove **only** its resources. This deletes
the drill's recovered data; inspect the exact namespace/PVC before executing:

```bash
kubectl --context="$KUBE_CONTEXT" -n database-restore delete statefulset postgres-restore
kubectl --context="$KUBE_CONTEXT" -n database-restore delete pvc data-postgres-restore-0
kubectl --context="$KUBE_CONTEXT" delete namespace database-restore
kubectl --context="$KUBE_CONTEXT" -n database delete secret postgres-restore-auth
```

In a complete cluster loss, recreate Kubernetes, namespaces, runtime Secrets and
the backup client CronJob configuration from Git/password-manager records. Use
the retained snapshot with this recovery environment, validate it, then configure
application connection Secrets to the replacement service. R2 backups contain
database role credentials but **not** Kubernetes Secret objects, Helm values or
your restic encryption password. Preserve those separately offsite.

## 6. Enable nightly backups and monitoring

After a successful R2 backup and restore rehearsal, change `spec.suspend` to
`false` in `infrastructure/database/backups/cronjob.yaml` and merge. Schedule:
**02:15 UTC every day** (04:15 Sofia winter / 05:15 summer). The maximum duration
is four hours, overlapping scheduled runs are forbidden, and missed starts older
than one hour are skipped. Watch the first scheduled run after enabling.

Retention in `settings.env` keeps the last 7 snapshots plus 7 daily, 4 weekly and
3 monthly points (overlapping rules retain their union). Successful backups run
restic pruning. Reduce retention based on measured R2 usage rather than assuming
1.9 GiB of live databases will always fit in the free allowance.

The namespaced kube-state-metrics instance exposes only Jobs and CronJobs; it has
no Secret access. Prometheus alerts on failed operations, more than 36 hours
without scheduled success, missing schedule metrics and exporter failure. Stale
backup alerts are suppressed while the schedule is deliberately suspended.
Manual Jobs do not update the CronJob's last-success time. Check the CronJob's
suspension flag during maintenance and restore it afterward. Existing Alertmanager
email delivery must already be configured and working.

To verify monitoring, inspect Prometheus's `postgres-backup-metrics` target and
`kube_cronjob_spec_suspend{namespace="database",cronjob="postgres-backup"}`. Confirm
the first scheduled Job updates `kube_cronjob_status_last_successful_time`.

## 7. Make PostGIS permanent and adopt Helm

Run **Build permanent PostgreSQL PostGIS image** in GitHub Actions. Its Dockerfile
uses the exact running ARM64 PostgreSQL 18.1 base digest, compiles PostGIS 3.6.1
against that server, and includes the libraries in the final image. It tests
PostGIS, topology, Tiger, fuzzystrmatch, projection, vector tiles and restart
persistence on a disposable server before publishing. Raster and SFCGAL are not
built because neither is installed in the supplied production inventory.

This build is intentionally separate from backup publication. It requires the
old base image to remain pullable, a Debian-based base with PostgreSQL development
headers, and an ARM64 GitHub runner. Those properties still need confirmation by
the build. If the build cannot fetch the base or its assumptions fail, **leave
the HelmRelease suspended** and keep backups running. Inspect the build error;
do not replace the base with `latest`. The validated separate recovery server is
also a migration path to a maintained image on a new volume.

Before adopting, export the existing Helm configuration privately on the server:

```bash
umask 077
helm --kube-context="$KUBE_CONTEXT" get values postgres -n database --all -o yaml \
  > "$HOME/.config/map-infra/postgres-private/values.yaml"
helm --kube-context="$KUBE_CONTEXT" get manifest postgres -n database \
  > "$HOME/.config/map-infra/postgres-private/manifest.yaml"
helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 18.1.11 \
  --destination "$HOME/.config/map-infra/postgres-private"
kubectl --context="$KUBE_CONTEXT" -n database create secret generic postgres-helm-values \
  --from-file=values.yaml="$HOME/.config/map-infra/postgres-private/values.yaml"
```

The values file can contain credentials; keep it out of Git. Save the chart,
private values, `postgres-auth-secret`, and `postgres-init-scripts` in your offsite
credential/configuration backup. The raw values Secret preserves custom settings
that cannot be inferred from a pod listing; the public HelmRelease overrides
only intentional changes.

Update `infrastructure/database/postgres/release.yaml` with the tested image:

```yaml
metadata:
  annotations:
    database.lonctus.com/postgis-image-verified: "true"
spec:
  # Keep true until render review, image checks and restore drill are complete.
  suspend: true
  values:
    global:
      security:
        # Bitnami's chart needs this vendor-image allowlist exception for our build.
        allowInsecureImages: true
    image:
      registry: ghcr.io
      repository: kaljo14/map-infra-postgres-postgis
      tag: sha-YOUR_BUILD_COMMIT
      digest: sha256:YOUR_TESTED_IMAGE_DIGEST
    auth:
      existingSecret: postgres-auth-secret
```

Merge this into the existing fields; do not replace the whole HelmRelease with
the snippet. Keep release name, namespace, chart version, resource names, PVC
size, mount path and credentials unchanged. Arrange registry pull access first.
Use `helm template` or `helm upgrade --dry-run=server` with the captured values
and these exact overrides, saving output privately. Compare with the captured
manifest; investigate unexpected changes to StatefulSet selectors, volume claims,
Services, initialization scripts or passwords. Do not use `--force` or uninstall
the release to resolve immutable-field errors.

Protect the existing PVC from Flux pruning and its backing PV from automatic
deletion before the handover:

```bash
kubectl --context="$KUBE_CONTEXT" -n database annotate pvc data-postgres-postgresql-0 \
  kustomize.toolkit.fluxcd.io/prune=disabled --overwrite
PG_PV="$(kubectl --context="$KUBE_CONTEXT" -n database get pvc data-postgres-postgresql-0 \
  -o jsonpath='{.spec.volumeName}')"
kubectl --context="$KUBE_CONTEXT" patch pv "$PG_PV" --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Take a fresh backup. Schedule a maintenance window: changing the image replaces
the single PostgreSQL pod and causes downtime. Change the HelmRelease's suspend
flag to `false` in Git only after all checks above pass, merge and reconcile:

```bash
flux reconcile kustomization postgres --with-source --context="$KUBE_CONTEXT"
flux reconcile helmrelease postgres -n database --context="$KUBE_CONTEXT"
kubectl --context="$KUBE_CONTEXT" -n database rollout status statefulset/postgres-postgresql
helm --kube-context="$KUBE_CONTEXT" list -n database
```

Validate `postgis_full_version()` and spatial queries after the rollout, confirm
the same PVC/PV is bound, and take another backup. Flux adopts the release using
the same release/target/storage namespace identity. No automatic failure rollback
or uninstall is configured. Do not delete the HelmRelease: its Helm finalizer can
uninstall the release; Flux prune protection does not protect explicit deletion.

## 8. Future updates

**PostgreSQL patch/minor within major 18:** build a compatible Bitnami-derived
server image containing the matching PostGIS libraries; test a fresh instance
and restore first. Preserve Bitnami startup/data layout while reusing its PVC.
Check extension compatibility and collation changes, take a fresh backup, pin the
new digest and deploy in a maintenance window. Update backup/recovery base patch
versions through their build/test workflow too. Retain known-good image digests.

**Chart upgrade:** separate it from a server upgrade. Review chart release notes,
the private values and fully rendered resources. Keep the server digest pinned.
Rehearse against disposable storage and never let a new chart default choose the
database major. All changes remain reviewed Git commits.

**PostgreSQL major upgrade:** create a separate target image and server/PVC with
compatible PostGIS. Keep source-major backup clients until the source is migrated;
their dumps can be restored into a supported newer server. Rehearse the complete
restore and application tests, stop all writers (scrapers, scheduled tasks and any
remaining Keycloak users), take a final backup, restore into a fresh target and
explicitly switch application connection Secrets. The recovery NetworkPolicy
must be deliberately updated before application traffic is allowed. Keep the old
server isolated for rollback; switching back after new writes requires a data
reconciliation plan. Never upgrade a major by changing the image on the old PVC.

**PostGIS update:** build libraries, test a restored copy, then perform the required
SQL extension upgrade in each affected database according to that version's
release notes. Merely changing the container does not update extension catalogs.

Logical nightly dumps are appropriate for the requested 24-hour recovery window.
If this changes to minutes or database size makes full dumps impractical, plan a
separate migration to an operator with WAL archiving and point-in-time recovery.

## Remaining cluster inventory

The pasted listing contains `personal-website` Deployments in `default` and
`lonctus`, legacy Martin/tileserver Services in `database` and `monitoring`, and
frontend/tileserver Services in `default` without matching local Deployments.
Service selectors cannot select pods in another namespace, so inspect selectors
and EndpointSlices before deciding whether these are deliberate aliases, unused
services or missing workloads. Do not blindly import or delete them.

Use read-only `kubectl --context="$KUBE_CONTEXT" get` commands for Deployments,
Services, Ingresses, PVCs and Helm releases. `kubectl get all` omits many resource
types, including Secrets, PVCs and Ingresses. Pods/ReplicaSets are generated and
should not be copied into Git. Diagnose the failing K3s Traefik install Jobs from
their logs; their cause cannot be inferred from the resource list. Traefik, DNS,
storage provisioning, TLS issuers and cluster configuration need their own
ownership records and disaster-recovery plan.

## References

- [Flux HelmRelease identity, values and failure handling](https://fluxcd.io/flux/components/helm/helmreleases/)
- [PostgreSQL pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)
- [PostgreSQL upgrades](https://www.postgresql.org/docs/current/upgrading.html)
- [PostGIS build requirements](https://postgis.net/docs/postgis_installation.html)
- [PostGIS 3.6.1](https://postgis.net/2025/11/PostGIS-3.6.1/)
- [Pinned PostGIS source checksum recorded by Buildroot](https://lists.buildroot.org/pipermail/buildroot/2026-January/794880.html)
- [restic encrypted S3 repositories](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
- [restic retention](https://restic.readthedocs.io/en/stable/060_forget.html)
