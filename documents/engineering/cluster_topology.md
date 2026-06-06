# Cluster Topology (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [pulsar_topics.md](pulsar_topics.md), [minio_buckets.md](minio_buckets.md), [hostbootstrap_integration.md](hostbootstrap_integration.md), [dhall_generation.md](dhall_generation.md), [test_isolation.md](test_isolation.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)

> **Purpose**: Describe what each harness cluster deploys, how `ClusterProfile` distinguishes a
> production cluster from the nine test clusters, how `.test_data/<case>` isolation and
> `dst-test-<model>-<archetype>` naming work, and how the per-project resource budget cordons
> kind nodes.

## TL;DR

- A **`ClusterProfile`** selects every name and path: `ProductionProfile`
  (`./.data`, fixed name `daemon-substrate-<cohort>`) vs `TestProfile`
  (`./.test_data/<case>`, test-scoped name `dst-test-<model>-<archetype>`). See
  [test_isolation.md](test_isolation.md).
- One `daemon-substrate-test test integration` invocation creates and tears down **nine**
  isolated `dst-test-*` clusters — one per model × archetype case — recursively invoking
  `hostbootstrap` per case.
- Each cluster carries Harbor, Pulsar, MinIO, the coordinator/orchestrator Deployment, and the
  worker. The worker is **cardinality-one** for every case: one worker owns the resources of the
  whole node.
- The coordinator/orchestrator Deployment runs with two replicas.
- Kind nodes are **resource-cordoned to the per-project budget** (`resources {cpu, memory}` from
  the skeletal `hostbootstrap.dhall`) on Linux; on Apple the per-project Colima VM is sized to
  that same budget. See [hostbootstrap_integration.md](hostbootstrap_integration.md).

## Current Status

This document describes the **target** test-harness topology. The `hostbootstrap-core`
inversion, the `ClusterProfile` split, `./.test_data` isolation, the nine-cluster runner, and
per-project resource cordoning are tracked as `Blocked`/`Planned` work in
[`../../DEVELOPMENT_PLAN/phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md`](../../DEVELOPMENT_PLAN/phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md)
(with the cluster-bring-up groundwork in
[`../../DEVELOPMENT_PLAN/phase-6-cluster-bringup-tree.md`](../../DEVELOPMENT_PLAN/phase-6-cluster-bringup-tree.md)).
The current repository still uses a single fixed cluster name and a `.data`-only data root; the
duplicate name/host-path derivations and the readiness-only integration stanza are recorded in
[`../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## Cluster naming and data roots

`ClusterProfile` is the only input to cluster-name and host-path derivation, centralized so no
two code paths compute a name differently:

| Profile | Cluster name | Data root | Kind data mount |
|---------|--------------|-----------|-----------------|
| `ProductionProfile` | `daemon-substrate-<cohort>` | `./.data` | `./.data/kind/<cohort>/daemon-substrate` |
| `TestProfile` | `dst-test-<model>-<archetype>` | `./.test_data/<case>` | `./.test_data/<case>/kind/daemon-substrate` |

The generated per-case test Dhall carries the `TestProfile` name and path for its case; see
[dhall_generation.md](dhall_generation.md). Teardown only ever targets `dst-test-`-prefixed
clusters and only reconciles `./.test_data/<case>/` workspaces, so production `.data` and any
production cluster are never touched. See [test_isolation.md](test_isolation.md).

## Resource cordoning

The per-project resource budget (`resources {cpu, memory, storage}` in the skeletal
`hostbootstrap.dhall`) bounds every harness cluster:

- **Linux** — `hostbootstrap-core` cordons kind node resources to the declared CPU/memory so the
  in-cluster workloads stay inside the project's slice of the host.
- **Apple** — Docker for kind runs inside the per-project Colima VM, which is sized to the same
  budget; the cluster is bounded by the VM rather than by per-node cordoning.

Because the worker owns the resources of its node, the budget is what makes one-worker-per-case a
meaningful test of node-resource ownership.

## In-cluster components

Each `dst-test-*` cluster (and a `ProductionProfile` cluster) brings up these workloads:

| Workload | Type | Notes |
|----------|------|-------|
| Harbor | StatefulSet (chart dependency) | local registry dependency; each fresh cluster deploys it and receives the harness image for that case |
| Apache Pulsar | StatefulSet (chart dependency) | workflow SSoT; minimal single-broker config; advertises the in-cluster service name for broker lookups; fixed BookKeeper port for PVC-backed standalone state |
| MinIO | StatefulSet (chart dependency) | static blob SSoT; minimal single-node config with an `mc` sidecar for bucket creation and seed upload |
| `daemon-substrate-test-orchestrator` | Deployment | coordinator/orchestrator role; `replicas: 2`; **no** anti-affinity; reads `orchestrator.dhall` from a mounted ConfigMap; egress-permitted (the only in-cluster workload that may reach the WAN) |
| `daemon-substrate-test-worker` (in-cluster worker models) | Deployment | worker role; `replicas: 1`; owns the resources of the whole node; reads `worker.dhall` from a mounted ConfigMap |

Harbor, Pulsar, and MinIO use PVCs bound to manual PVs whose host paths are rooted under the
profile's kind data mount.

### Why orchestrator is multi-replica with no anti-affinity

The orchestrator is **horizontally scalable, not hardware-bound**. Replica cardinality is
bounded by Pulsar's `Shared` subscription semantics — all replicas attach to the fan-in
subscription with the same name, and Pulsar's at-most-one-active-consumer-per-message guarantee
prevents work duplication. Two replicas survive a single-pod failure without queue stall; the
operator can scale up by raising `orchestrator.replicas`. No anti-affinity rule is required
because two orchestrator pods on the same node duplicate no expensive resources (no GPU, no large
weight cache, no exclusive device handles).

Each orchestrator pod also runs `Daemon.Reconciler.runReconciler` as a concurrent thread
alongside `Daemon.Orchestrator.runOrchestrator`. The reconciler is **leader-elected** via a
Pulsar Failover subscription on a dedicated control topic — only one orchestrator pod's
reconciler thread is active at a time, even though every pod's `runOrchestrator` thread runs
concurrently for fan-in / fan-out work. See
[`../architecture/lifecycle_policy.md`](../architecture/lifecycle_policy.md).

### WAN egress

The orchestrator pods are the only in-cluster workloads permitted to reach external networks
(HuggingFace, Civitai, etc.). A NetworkPolicy stanza in the chart restricts egress for the worker
Deployment, MinIO, Pulsar, and Harbor pods to in-cluster targets only; orchestrator pods carry an
`egress-permitted: "true"` label that the policy uses to allow external traffic. This keeps WAN
access concentrated on the daemon that needs it for model-weight hydration.

## Worker placement by execution model

The 3x3 matrix exercises three execution models. Worker placement follows the model; the worker
is always cardinality-one:

- **`Container` / `HostBinary`** — the worker runs in the cluster as the `replicas: 1` Deployment
  above.
- **`HostDaemon`** — the worker runs as a host-native process outside the cluster; the cluster
  side runs Harbor, Pulsar, MinIO, and the orchestrator. The host worker connects to in-cluster
  Pulsar and MinIO via the cluster's published edge ports and reads the persisted edge-port
  record at startup.

## Chart layout

```
chart/
├── Chart.yaml                # dependencies: harbor, pulsar, minio
├── values.yaml               # default values; overridden per case
├── values/
│   └── ...                   # per-case overrides (e.g. worker disabled in-cluster for host-daemon)
└── templates/
    ├── deployment-orchestrator.yaml
    ├── deployment-worker.yaml
    ├── configmap-orchestrator.yaml
    ├── configmap-worker.yaml
    └── service-*.yaml
```

The `worker.enabled` boolean controls whether the worker Deployment template renders; it is
disabled for the host-daemon model where the worker runs on the host.

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

This guarantees at most one worker pod per node. The harness requests `replicas: 1` because one
worker owns the resources of the whole node. The integration suite asserts that no second worker
is scheduled for the same matrix case.

## ConfigMap layout

The orchestrator and worker each read their generated Dhall config from a mounted ConfigMap:

- `configmap-orchestrator` → mounted at `/etc/daemon-substrate/orchestrator.dhall`
- `configmap-worker` → mounted at `/etc/daemon-substrate/worker.dhall`
- both role ConfigMaps also mount `live.dhall` and `lifecycle-policy.dhall`

The ConfigMaps are rendered from the binary-generated project Dhall (see
[dhall_generation.md](dhall_generation.md)) at Helm render time.

## kubeconfig paths

Each cluster's kubeconfig lives inside its profile data root, never in the operator's
`~/.kube/config`:

| Profile | kubeconfig |
|---------|------------|
| `ProductionProfile` | `./.data/runtime/daemon-substrate.kubeconfig` (container) or `./.build/daemon-substrate.kubeconfig` (host-native) |
| `TestProfile` | `./.test_data/<case>/daemon-substrate.kubeconfig` |

On Linux the kubeconfig is exported with kind's internal endpoint because the command runs inside
the project container; the container is attached to Docker's `kind` network before Kubernetes
resources are applied.

## Edge port discovery

`cluster up` binds an edge base port (starting at 9090, incrementing on conflict), records the
chosen ports beside the profile's runtime record, and maps:

- `pulsarPort`: base port → Pulsar broker `6650`
- `pulsarAdminPort`: base port + 1 → Pulsar admin `8080`
- `minioPort`: base port + 2 → MinIO `9000`

For host-native worker placement, `cluster up` starts detached `kubectl port-forward` processes
for those ports and records their pids beside the edge-port record; `cluster down` stops the
recorded pids. The host worker reads the record at startup and rewrites its endpoints to
`127.0.0.1`.

## Cross-references

- Test-isolation invariants: [test_isolation.md](test_isolation.md)
- Per-case Dhall generation: [dhall_generation.md](dhall_generation.md)
- What runs on Pulsar topics: [pulsar_topics.md](pulsar_topics.md)
- What runs on MinIO buckets: [minio_buckets.md](minio_buckets.md)
- hostbootstrap integration: [hostbootstrap_integration.md](hostbootstrap_integration.md)
- Operator workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
