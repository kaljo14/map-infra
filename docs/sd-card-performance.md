# Running the Pi on an SD card

The reported live samples showed 28–57% I/O wait while about 1.1 GiB of RAM
was available. K3s, container images and the application PVCs share `mmcblk0`.
This supports investigating storage contention. It does not establish that the
card is failing or that a specific process caused the API outage.

## Immediate, reversible relief

Temporarily stop the metrics pipeline to check how much it contributes. This
pauses new metrics and Prometheus alert evaluation; Grafana's metrics queries
will fail while VictoriaMetrics is stopped. Application and database deployments
keep running. Existing metrics data stays on its PVCs, subject to the existing
retention policies when services resume.

First prevent Flux from undoing the temporary replica counts:

```bash
flux suspend kustomization flux-system
flux get kustomizations
```

If `monitoring` is listed, suspend it too:

```bash
flux suspend kustomization monitoring
```

If `monitoring` does not exist yet, suspending the parent `flux-system` prevents
it from being created until recovery. If suspension fails because the API is
unreachable, resolve that connection before continuing. Suspension stops future
reconciliations; let any current reconciliation finish before scaling.

```bash
kubectl -n monitoring scale deployment prometheus victoriametrics --replicas=0
kubectl -n monitoring get pods
```

Once those pods have terminated, wait a minute, then measure again:

```bash
vmstat 1 10
kubectl -n flux-system get pods
kubectl -n flux-system get events --sort-by='.lastTimestamp'
```

Compare the live samples after the first `vmstat` line, especially `wa` and `b`.
Load averages take longer to fall. Improvement indicates monitoring contributes
to contention. If there is little improvement, investigate K3s/containerd and
PostgreSQL I/O before stopping additional services. Flux pods remaining in
`ContainerCreating` still need their Events checked independently.

To restore the previous running services:

```bash
kubectl -n monitoring scale deployment prometheus victoriametrics --replicas=1
```

Resume `monitoring` if it existed and you suspended it, then resume the parent:

```bash
flux resume kustomization monitoring
flux resume kustomization flux-system
```

Skip the first command if `monitoring` does not exist. If a bundle was already
suspended before this procedure, preserve its previous state. Flux will enforce
the replica counts from Git once reconciliation resumes.

## Lower ongoing collection cost

The repository now sets Prometheus scraping and alert evaluation to 60 seconds,
up from 30 seconds. With stable target/series counts, this approximately halves
new metric sample ingestion into both Prometheus and VictoriaMetrics. It does not
halve total disk activity: compaction, databases, logs and image extraction continue.
Alert detection is less granular, and short spikes may be missed.

Grafana's data-source interval and provisioned dashboard refreshes also use
60 seconds. Dashboard refresh savings apply while dashboards are open. Deployment
pod-template annotations cause Prometheus and Grafana to restart once when this
change is applied, so their mounted configuration is actually reloaded.

Merge these changes into `main` to deploy through Flux once its controllers are
healthy. If Flux is still unable to start, after pulling the updated `main` on the
server and suspending reconciliation as above, apply just the Prometheus config:

```bash
kubectl apply -f apps/monitoring/prometheus/configmap.yaml
kubectl -n monitoring rollout restart deployment prometheus
```

The config uses a `subPath` mount, so a configuration reload alone would still
read the old file. If Prometheus is scaled to zero, the updated config is loaded
when it is scaled back to one. Let Flux deploy the matching Grafana settings after
the cluster recovers. Keep the changes in Git so they persist.

## Further reductions, if needed

- Use one metrics store: keeping Prometheus with Grafana is the simplest option
  for the existing Prometheus alert rules. Remove Prometheus `remote_write`, point
  Grafana's metrics data source at Prometheus, then disable VictoriaMetrics as
  one coordinated Git change. Stopping only VictoriaMetrics while Prometheus
  remote write remains enabled causes retries. Existing VictoriaMetrics history
  will not automatically appear in Prometheus.
- If centralized logs are dispensable, pause both Promtail and Loki together.
  Kubernetes container logs still exist locally, but centralized log searches and
  ingestion stop. Promtail is a DaemonSet, so `kubectl scale deployment` cannot
  stop it. Plan this as a separate Git change.
- Review retention before shortening it: Prometheus currently retains 15 days
  and VictoriaMetrics 12 months. Shorter retention limits growth but can delete
  older metrics; it is not the first emergency action for I/O wait.
- Run image updates and tile generation one at a time while storage is slow.
  Avoid repeated bootstrap/restart attempts that create additional startup work.

Avoid adding swap on this SD card as a response to these measurements: the
snapshot shows available RAM and the current bottleneck is storage waiting.
Keep database durability settings enabled and retain all PVCs.

References:

- [Prometheus scrape and evaluation intervals](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- [Flux suspension](https://fluxcd.io/flux/components/kustomize/kustomizations/#suspend)
- [K3s storage recommendations](https://docs.k3s.io/installation/requirements#disks)
