# Cluster Topology (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [pulsar_topics.md](pulsar_topics.md), [minio_buckets.md](minio_buckets.md), [hostbootstrap_integration.md](hostbootstrap_integration.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)

> **Purpose**: Describe what `daemon-substrate-test cluster up` deploys, where each component
> runs by cohort, and how the chart parameterizes the Apple Silicon vs Linux CPU split.

## TL;DR

- A single kind cluster carries Harbor, Pulsar, MinIO, the orchestrator Deployment, and (on
  Linux CPU) the worker Deployment.
- On Apple Silicon, the worker runs as a host-native daemon outside the cluster; the cluster
  side runs everything else.
- Pod anti-affinity on `kubernetes.io/hostname` keeps Worker pods one-per-node (Linux CPU);
  the Linux harness cluster has three worker nodes so the harness can exercise N>1. The
  Apple Silicon harness cluster uses one worker node because the Worker runs as a host
  daemon, not an in-cluster Deployment.
- The kubeconfig lives at `./.build/daemon-substrate.kubeconfig` (Apple) or
  `./.data/runtime/daemon-substrate.kubeconfig` (Linux outer container).

## Current Status

Phase 6 Sprint 6.1 implements the `Daemon.Cluster.*` Haskell plan-generation modules. They
produce deterministic bring-up, status, and teardown action plans for kind, manual storage,
Helm releases, local harness image build / kind image-load, Pulsar namespace/topic setup,
MinIO bucket seeding, orchestrator/worker workload resources, and edge-port persistence.

Phase 6 Sprint 6.2 implements `chart/`: default values, per-cohort values, orchestrator and
worker Deployments, ConfigMaps, Services, a restrictive egress NetworkPolicy that excludes
egress-permitted orchestrator pods, and deployable local Harbor / Pulsar / MinIO dependency
charts.

Phase 6 Sprint 6.3 implements the harness Dhall files. The root `dhall/` files decode through
the library config decoders, and the chart packages the same role, live, and lifecycle policy
files under `chart/files/` for ConfigMap mounting.

Phase 8 Sprint 8.6 implements the live `daemon-substrate-test cluster ...` interpreter:
concrete `kind`, `kubectl`, `helm`, Docker image build, kind image-load, Kubernetes apply /
rollout wait, Pulsar admin, MinIO admin, and edge-port actions execute against absolute tool
paths. The dependency charts are deployable local StatefulSets with readiness / startup
probes, and Harbor / Pulsar / MinIO attach PVCs backed by the repo-local kind data mount.

Apple Silicon live bring-up now reaches Running dependency pods and `2/2` orchestrator pods,
binds the Harbor / Pulsar / MinIO PVCs, preserves MinIO / Pulsar data across a
`cluster down && cluster up` cycle, handles in-place `cluster up` over an existing kind
cluster, advertises Pulsar lookup results through the in-cluster
`daemon-substrate-test-pulsar` service, and exposes one named active native consumer for the
reconciler Failover subscription. The Apple host worker reads the persisted edge-port record,
connects through managed Pulsar / Pulsar admin / MinIO localhost forwards, and has completed
a live request -> orchestrator -> host worker -> response smoke handoff.

Linux live bring-up is validated through `hostbootstrap cluster up` from the service
container. The container joins Docker's `kind` network, exports kind's internal kubeconfig,
waits for node readiness, deploys the same dependency StatefulSets, rolls out the
orchestrator Deployment plus the two-replica worker Deployment, and keeps the retained
Harbor / Pulsar / MinIO PVCs bound across consecutive `cluster down && cluster up` cycles.

## In-cluster components

`daemon-substrate-test cluster up` brings up a kind cluster with these workloads:

| Workload | Type | Notes |
|----------|------|-------|
| Harbor | StatefulSet (chart dependency) | local registry dependency; current harness builds `daemon-substrate-test:local` and loads it directly into kind before Helm rollout |
| Apache Pulsar | StatefulSet (chart dependency) | workflow SSoT; minimal single-broker config for the harness; advertises the in-cluster service name for broker lookups and uses a fixed BookKeeper port for PVC-backed standalone state |
| MinIO | StatefulSet (chart dependency) | static blob SSoT; minimal single-node config with an `mc` sidecar for bucket creation and seed object upload |
| `daemon-substrate-test-orchestrator` | Deployment | the orchestrator role; `replicas: 2`; **no** anti-affinity; reads `orchestrator.dhall` from a mounted ConfigMap; egress-permitted (the only in-cluster workload that may reach the WAN) |
| `daemon-substrate-test-worker` (Linux CPU cohort only) | Deployment | the worker role; `replicas: 2`; required pod anti-affinity on `kubernetes.io/hostname`; reads `worker.dhall` from a mounted ConfigMap |

The Linux CPU kind cluster is configured with three worker nodes (one control plane + three
workers) so it can exercise two Worker pods on distinct nodes. The Apple Silicon kind
cluster uses one worker node because its Worker process runs outside the cluster under the
hostbootstrap LaunchDaemon.

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

## Host-native components (Apple cohort only)

When the operator runs `hostbootstrap cluster up` on Apple Silicon (per the `HostDaemon` model
in `hostbootstrap.dhall`; see [hostbootstrap_integration.md](hostbootstrap_integration.md)):

- Harbor, Pulsar, MinIO, and the orchestrator Deployment all run in the kind cluster as above.
- The worker daemon runs as `./.build/daemon-substrate-test service --role worker --config
  dhall/worker.dhall` directly on the host, outside the cluster, under a system-scope
  LaunchDaemon installed by `hostbootstrap`.
- The host worker connects to in-cluster Pulsar and MinIO via the kind cluster's published
  edge ports (chosen by `chooseEdgePort` starting at 9090, persisted to
  `./.build/edge-port.json`). The record carries `pulsarPort`, `pulsarAdminPort`, and
  `minioPort`; `cluster up` starts matching local `kubectl port-forward` processes and
  `cluster down` stops the recorded pids.

There is no Linux equivalent for the host-worker pattern. On Linux, the worker always runs in
the cluster.

## Chart layout

```
chart/
├── Chart.yaml                # dependencies: harbor, pulsar, minio
├── values.yaml               # default values; overridden per cohort
├── values/
│   ├── apple-silicon.yaml    # cohort-specific overrides (worker disabled in-cluster)
│   └── linux-cpu.yaml        # cohort-specific overrides (worker enabled, replicas: 2)
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

The Linux CPU worker Deployment carries the substrate-mandated rule:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: daemon-substrate-test-worker
        topologyKey: kubernetes.io/hostname
```

This guarantees at most one worker pod per node. The harness intentionally requests
`replicas: 2` on a three-worker-node cluster so the scheduler can place both pods. A third
replica would remain `Pending` — the harness asserts this behavior in the integration suite.

## ConfigMap layout

The orchestrator and worker each read their Dhall config from a mounted ConfigMap:

- `configmap-orchestrator` → mounted at `/etc/daemon-substrate/orchestrator.dhall`
- `configmap-worker` → mounted at `/etc/daemon-substrate/worker.dhall`
- both role ConfigMaps also mount `live.dhall` and `lifecycle-policy.dhall`

The ConfigMaps are rendered from `chart/files/{orchestrator,worker,live,lifecycle-policy}.dhall`
at Helm render time. The chart values still allow role-specific Dhall overrides, but the
packaged harness files are the default source mounted into live pods.

## kubeconfig paths

| Substrate | Path |
|-----------|------|
| Apple Silicon (host-native, one kind worker node) | `./.build/daemon-substrate.kubeconfig` |
| Linux CPU (outer container) | `./.data/runtime/daemon-substrate.kubeconfig` |

Neither path mutates the operator's `~/.kube/config`. The repo-local kubeconfig is the only
authoritative handle to the harness cluster. On Linux the kubeconfig is exported with
kind's internal endpoint because the command runs inside the outer container; the container
is attached to Docker's `kind` network before Kubernetes resources are applied.

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

The outer container that hosts `daemon-substrate-test` on the Linux CPU cohort is built from
the [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image
(`docker.io/tuee22/hostbootstrap:basecontainer-cpu-*`). The project Dockerfile
(`docker/linux-substrate.Dockerfile`) is intentionally thin: `FROM ${BASE_IMAGE}` plus the
project's own build steps. Every heavy toolchain layer (GHC 9.12, Cabal, `kubectl`, `helm`,
`kind`, `protoc`, `ormolu`, `hlint`, warm Haskell store) lives in the base. The service
container runs `daemon-substrate-test cluster up && sleep infinity`, so a successful
reconciliation does not trigger hostbootstrap's restart policy to loop the bring-up command.

See [hostbootstrap_integration.md](hostbootstrap_integration.md) for the full integration
shape and the `hostbootstrap.dhall` that declares the per-substrate model.

## Cross-references

- What runs on Pulsar topics: [pulsar_topics.md](pulsar_topics.md)
- What runs on MinIO buckets: [minio_buckets.md](minio_buckets.md)
- hostbootstrap integration: [hostbootstrap_integration.md](hostbootstrap_integration.md)
- Operator workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
