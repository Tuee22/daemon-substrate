# Cluster Topology (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [pulsar_topics.md](pulsar_topics.md), [minio_buckets.md](minio_buckets.md), [hostbootstrap_integration.md](hostbootstrap_integration.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)

> **Purpose**: Describe what `daemon-substrate-test cluster up` deploys, where each component
> runs by execution model, and how the chart parameterizes the in-cluster vs host-native worker
> split.

## Current Status

The substrate-keyed `hostbootstrap.dhall` and the host-native worker under the `HostDaemon`
model are implemented. Worker placement is keyed by execution model: `container` and
`host-binary` run the worker Deployment in the kind cluster, while `host-daemon` expects the
worker to run as a caller-owned foreground host process.

Phase 6 is reopened to correct the older two-worker test topology. The target topology has
exactly one worker for each matrix case, because that worker owns the resources of the whole
node. Phase 8 is reopened so `daemon-substrate-test test integration` creates and tears down a
fresh cluster for each of the nine model/workflow cases.

## TL;DR

- Each integration matrix case creates a fresh kind cluster carrying Harbor, Pulsar, MinIO, the
  coordinator/orchestrator Deployment, and, for `container` / `host-binary`, the worker
  Deployment.
- Under `host-daemon`, the worker runs as a host-native process outside the cluster; the
  cluster side runs everything else.
- The coordinator/orchestrator Deployment runs with two replicas. The worker is cardinality-one
  for every case, regardless of whether it runs in-cluster or as a host daemon.
- Harbor is deployed for every fresh cluster and receives the harness image for that case. The
  host/project artifact may be reused, but the in-cluster registry deployment and image upload
  are case-local.
- The kubeconfig lives at `./.data/runtime/daemon-substrate.kubeconfig` for `container` and
  `./.build/daemon-substrate.kubeconfig` for host-native models.

## Implementation Details

Phase 6 Sprint 6.1 implements the `Daemon.Cluster.*` Haskell plan-generation modules. They
produce deterministic bring-up, status, and teardown action plans for kind, manual storage,
Helm releases, harness image publication, Pulsar namespace/topic setup, MinIO bucket seeding,
orchestrator/worker workload resources, and edge-port persistence.

Phase 6 Sprint 6.2 implements `chart/`: default values, per-cohort values, orchestrator and
worker Deployments, ConfigMaps, Services, a restrictive egress NetworkPolicy that excludes
egress-permitted orchestrator pods, and deployable local Harbor / Pulsar / MinIO dependency
charts.

Phase 6 Sprint 6.3 implements the harness Dhall files. The root `dhall/` files decode through
the library config decoders, and the chart packages the same role, live, and lifecycle policy
files under `chart/files/` for ConfigMap mounting.

Phase 8 Sprint 8.6 implements the live `daemon-substrate-test cluster ...` interpreter:
concrete `kind`, `kubectl`, `helm`, Docker image build/publication, Kubernetes apply /
rollout wait, Pulsar admin, MinIO admin, and edge-port actions execute against absolute tool
paths. The dependency charts are deployable local StatefulSets with readiness / startup
probes, and Harbor / Pulsar / MinIO attach PVCs backed by the repo-local kind data mount. The
current runner still uses direct kind image-load for publication; reopened Phase 6 replaces
that with Harbor upload as the supported target.

Apple Silicon live bring-up now reaches Running dependency pods and `2/2` orchestrator pods,
binds the Harbor / Pulsar / MinIO PVCs, preserves MinIO / Pulsar data across a
`cluster down && cluster up` cycle, handles in-place `cluster up` over an existing kind
cluster, advertises Pulsar lookup results through the in-cluster
`daemon-substrate-test-pulsar` service, and exposes one named active native consumer for the
reconciler Failover subscription. The Apple host worker reads the persisted edge-port record,
connects through managed Pulsar / Pulsar admin / MinIO localhost forwards, and has completed
a live request -> orchestrator -> host worker -> response smoke handoff.

Linux live bring-up is validated through `hostbootstrap cluster up` using the one-shot project
container handoff. The container joins Docker's `kind` network, exports kind's internal
kubeconfig, waits for node readiness, deploys the same dependency StatefulSets, rolls out the
coordinator/orchestrator Deployment, and keeps the retained Harbor / Pulsar / MinIO PVCs bound
across consecutive `cluster down && cluster up` cycles. Reopened Phase 6/8 work changes the
worker side from the current two-replica readiness shape to the target single-worker
model/workflow matrix shape.

## In-cluster components

`daemon-substrate-test cluster up` brings up a kind cluster with these workloads:

| Workload | Type | Notes |
|----------|------|-------|
| Harbor | StatefulSet (chart dependency) | local registry dependency; target integration deploys it and uploads the harness image for every matrix case |
| Apache Pulsar | StatefulSet (chart dependency) | workflow SSoT; minimal single-broker config for the harness; advertises the in-cluster service name for broker lookups and uses a fixed BookKeeper port for PVC-backed standalone state |
| MinIO | StatefulSet (chart dependency) | static blob SSoT; minimal single-node config with an `mc` sidecar for bucket creation and seed object upload |
| `daemon-substrate-test-orchestrator` | Deployment | the coordinator/orchestrator role; `replicas: 2`; **no** anti-affinity; reads `orchestrator.dhall` from a mounted ConfigMap; egress-permitted (the only in-cluster workload that may reach the WAN) |
| `daemon-substrate-test-worker` (in-cluster worker models only) | Deployment | the worker role; `replicas: 1`; owns the resources of the whole node; reads `worker.dhall` from a mounted ConfigMap |

The in-cluster worker topology schedules exactly one worker pod. The host-native worker
topology starts exactly one worker process outside the cluster under the caller-owned
foreground `hostbootstrap daemon run` process.

Harbor, Pulsar, and MinIO use PVCs bound to manual PVs. The kind nodes mount the host path
`./.data/kind/<cohort>/daemon-substrate` at
`/daemon-substrate-data/<cohort>/daemon-substrate`; PV host paths are rooted under that
in-node path.

### Why orchestrator is multi-replica with no anti-affinity

The orchestrator is **horizontally scalable, not hardware-bound**. Replica cardinality is
bounded by Pulsar's `Shared` subscription semantics — all replicas attach to the fan-in
subscription with the same name, and Pulsar's at-most-one-active-consumer-per-message
guarantee prevents work duplication. Two replicas survive a single-pod failure without
queue stall; the operator can scale up further by raising `orchestrator.replicas` in
chart values. No anti-affinity rule is required because two orchestrator pods on the same
node duplicate no expensive resources (no GPU, no large weight cache, no exclusive
device handles).

Each orchestrator pod also runs `Daemon.Reconciler.runReconciler` as a concurrent thread
alongside `Daemon.Orchestrator.runOrchestrator`. The reconciler is **leader-elected** via a
Pulsar Failover subscription on a dedicated control topic — only one orchestrator pod's
reconciler thread is active at a time, even though every pod's `runOrchestrator` thread runs
concurrently for fan-in / fan-out work. See
[`../architecture/lifecycle_policy.md`](../architecture/lifecycle_policy.md).

### WAN egress

The orchestrator pods are the only in-cluster workloads permitted to reach external
networks (HuggingFace, Civitai, etc.). A NetworkPolicy stanza in the chart restricts
egress for the worker Deployment, MinIO, Pulsar, and Harbor pods to in-cluster targets
only; orchestrator pods carry an `egress-permitted: "true"` label that the policy uses
to allow external traffic. This keeps WAN access concentrated on the daemon that needs
it for model-weight hydration.

## Host-native worker (`HostDaemon` model)

When the operator runs `hostbootstrap cluster up` for the `AppleSilicon` target (detected or
selected with `--force-target apple-silicon`; see
[hostbootstrap_integration.md](hostbootstrap_integration.md)), the `HostDaemon` declaration
places the worker on the host. The worker starts only when the caller runs
`hostbootstrap daemon run` as a foreground process:

- Harbor, Pulsar, MinIO, and the orchestrator Deployment all run in the kind cluster as above.
- The worker daemon runs as `./.build/daemon-substrate-test service --role worker --config
  dhall/worker.dhall` directly on the host, outside the cluster. `hostbootstrap cluster ...`
  does not start or stop it; the invoking shell, service manager, or test harness owns that
  foreground process.
- The host worker connects to in-cluster Pulsar and MinIO via the kind cluster's published
  edge ports (chosen by `chooseEdgePort` starting at 9090, persisted to
  `./.build/edge-port.json`). The record carries `pulsarPort`, `pulsarAdminPort`, and
  `minioPort`; `cluster up` starts matching local `kubectl port-forward` processes and
  `cluster down` stops the recorded pids.

Under the `Container` and `HostBinary` models there is no host-native worker; the worker runs
in the cluster as the Deployment above.

## Chart layout

```
chart/
├── Chart.yaml                # dependencies: harbor, pulsar, minio
├── values.yaml               # default values; overridden per cohort
├── values/
│   ├── apple-silicon.yaml    # cohort-specific overrides (worker disabled in-cluster)
│   └── linux-cpu.yaml        # cohort-specific overrides (worker enabled, replicas: 1)
└── templates/
    ├── deployment-orchestrator.yaml
    ├── deployment-worker.yaml
    ├── configmap-orchestrator.yaml
    ├── configmap-worker.yaml
    └── service-*.yaml
```

The `worker.enabled` boolean in `values.yaml` (default `true`, overridden to `false` for the
`apple-silicon` cohort) controls whether the worker Deployment template renders.

## Anti-affinity contract

The in-cluster worker Deployment carries the substrate-mandated rule:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: daemon-substrate-test-worker
        topologyKey: kubernetes.io/hostname
```

This guarantees at most one worker pod per node. The target harness requests `replicas: 1`
because one worker owns the resources of the whole node. The integration suite must assert that
no second worker is scheduled for the same matrix case.

## ConfigMap layout

The orchestrator and worker each read their Dhall config from a mounted ConfigMap:

- `configmap-orchestrator` → mounted at `/etc/daemon-substrate/orchestrator.dhall`
- `configmap-worker` → mounted at `/etc/daemon-substrate/worker.dhall`
- both role ConfigMaps also mount `live.dhall` and `lifecycle-policy.dhall`

The ConfigMaps are rendered from `chart/files/{orchestrator,worker,live,lifecycle-policy}.dhall`
at Helm render time. The chart values still allow role-specific Dhall overrides, but the
packaged harness files are the default source mounted into live pods.

## kubeconfig paths

| Execution model | Path |
|-----------------|------|
| `container` | `./.data/runtime/daemon-substrate.kubeconfig` |
| `host-binary` | `./.build/daemon-substrate.kubeconfig` |
| `host-daemon` | `./.build/daemon-substrate.kubeconfig` |

Neither path mutates the operator's `~/.kube/config`. The repo-local kubeconfig is the only
authoritative handle to the harness cluster. On Linux the kubeconfig is exported with
kind's internal endpoint because the command runs inside the outer container; the container
is attached to Docker's `kind` network before Kubernetes resources are applied. Container
model `test integration` and `test all` runs perform the same network attachment before
Cabal delegation so the live readiness suite can use that internal kubeconfig.

## Edge port discovery

`daemon-substrate-test cluster up` attempts to bind port 9090 first; on conflict it increments
linearly until an open base port is found, records the chosen ports under
`./.build/edge-port.json` (or `./.data/runtime/edge-port.json` on Linux), and prints the
chosen base port. The record maps:

- `pulsarPort`: base port -> Pulsar broker `6650`
- `pulsarAdminPort`: base port + 1 -> Pulsar admin `8080`
- `minioPort`: base port + 2 -> MinIO `9000`

On Apple Silicon, `cluster up` starts detached `kubectl port-forward` processes for those
ports and records their pids beside the edge-port record. `cluster down` stops the recorded
pid set before deleting the kind cluster. The host-native Apple worker reads the record at
startup and rewrites its Pulsar / Pulsar admin / MinIO endpoints to `127.0.0.1`.

## Outer container shape

The outer container that hosts `daemon-substrate-test` under the `Container` model is built
from the selected [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image: CPU
for Linux CPU and CUDA-flavored for Linux GPU. The project
Dockerfile (`docker/Dockerfile`) is intentionally thin: `FROM ${BASE_IMAGE}`
plus the project's own build steps, a tini-wrapped `ENTRYPOINT`, and a
`RUN daemon-substrate-test check-code` build gate. Every heavy toolchain layer
(`ghc-9.12.4`, Cabal, `kubectl`, `helm`, `kind`,
`protoc`, `ormolu`, `hlint`, warm Haskell store) lives in the base; the warm-store
`cabal.project.freeze` import applies to this container build only. The Dockerfile has no
default `CMD`; `hostbootstrap` forwards `cluster up/down/delete` to the entrypoint as one-shot
container commands.

See [hostbootstrap_integration.md](hostbootstrap_integration.md) for the full integration
shape and the `hostbootstrap.dhall` substrate map.

## Cross-references

- What runs on Pulsar topics: [pulsar_topics.md](pulsar_topics.md)
- What runs on MinIO buckets: [minio_buckets.md](minio_buckets.md)
- hostbootstrap integration: [hostbootstrap_integration.md](hostbootstrap_integration.md)
- Operator workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
