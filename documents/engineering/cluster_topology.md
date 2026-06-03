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
  the harness cluster has at least two worker nodes so the harness can exercise N>1.
- The kubeconfig lives at `./.build/daemon-substrate.kubeconfig` (Apple) or
  `./.data/runtime/daemon-substrate.kubeconfig` (Linux outer container).

## In-cluster components

`daemon-substrate-test cluster up` brings up a kind cluster with these workloads:

| Workload | Type | Notes |
|----------|------|-------|
| Harbor | StatefulSet (chart dependency) | image registry; the harness pushes `daemon-substrate-test:local` here so cluster pods can pull it |
| Apache Pulsar | StatefulSet (chart dependency) | workflow SSoT; minimal single-broker config for the harness |
| MinIO | StatefulSet (chart dependency) | static blob SSoT; minimal single-node config |
| `daemon-substrate-test-orchestrator` | Deployment | the orchestrator role; `replicas: 2`; **no** anti-affinity; reads `daemon-substrate-orchestrator.dhall` from a mounted ConfigMap; egress-permitted (the only in-cluster workload that may reach the WAN) |
| `daemon-substrate-test-worker` (Linux CPU cohort only) | Deployment | the worker role; `replicas: 2`; required pod anti-affinity on `kubernetes.io/hostname`; reads `daemon-substrate-worker.dhall` from a mounted ConfigMap |

The kind cluster is configured with three worker nodes (one control plane + three workers) so
the Linux CPU cohort can exercise two Worker pods on distinct nodes.

### Why orchestrator is multi-replica with no anti-affinity

The orchestrator is **horizontally scalable, not hardware-bound**. Replica cardinality is
bounded by Pulsar's `Shared` subscription semantics — all replicas attach to the fan-in
subscription with the same name, and Pulsar's at-most-one-active-consumer-per-message
guarantee prevents work duplication. Two replicas survive a single-pod failure without
queue stall; the operator can scale up further by raising `orchestrator.replicas` in
chart values. No anti-affinity rule is required because two orchestrator pods on the same
node duplicate no expensive resources (no GPU, no large weight cache, no exclusive
device handles).

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
  ./.build/daemon-substrate-worker.dhall` directly on the host, outside the cluster, under a
  system-scope LaunchDaemon installed by `hostbootstrap`.
- The host worker connects to in-cluster Pulsar and MinIO via the kind cluster's published
  edge port (chosen by `chooseEdgePort` starting at 9090, persisted to
  `./.build/edge-port.json`).

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

The ConfigMaps are rendered from the staged Dhall files under `./.build/conf/cluster/` (or
`./.data/runtime/conf/cluster/` on Linux); `daemon-substrate-test cluster up` re-renders them
on every bring-up so config changes apply immediately.

## kubeconfig paths

| Substrate | Path |
|-----------|------|
| Apple Silicon (host-native) | `./.build/daemon-substrate.kubeconfig` |
| Linux CPU (outer container) | `./.data/runtime/daemon-substrate.kubeconfig` |

Neither path mutates the operator's `~/.kube/config`. The repo-local kubeconfig is the only
authoritative handle to the harness cluster.

## Edge port discovery

`daemon-substrate-test cluster up` attempts to bind port 9090 first; on conflict it increments
linearly until an open port is found, records the chosen port under
`./.build/edge-port.json` (or `./.data/runtime/edge-port.json` on Linux), and prints the
chosen port. The host-native Apple worker reads this file at startup to find the in-cluster
Pulsar / MinIO endpoints.

## Outer container shape

The outer container that hosts `daemon-substrate-test` on the Linux CPU cohort is built from
the [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image
(`docker.io/tuee22/hostbootstrap:basecontainer-cpu-*`). The project Dockerfile
(`docker/linux-substrate.Dockerfile`) is intentionally thin: `FROM ${BASE_IMAGE}` plus the
project's own build steps. Every heavy toolchain layer (GHC 9.12, Cabal, `kubectl`, `helm`,
`kind`, `protoc`, `ormolu`, `hlint`, warm Haskell store) lives in the base.

See [hostbootstrap_integration.md](hostbootstrap_integration.md) for the full integration
shape and the `hostbootstrap.dhall` that declares the per-substrate model.

## Cross-references

- What runs on Pulsar topics: [pulsar_topics.md](pulsar_topics.md)
- What runs on MinIO buckets: [minio_buckets.md](minio_buckets.md)
- hostbootstrap integration: [hostbootstrap_integration.md](hostbootstrap_integration.md)
- Operator workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
