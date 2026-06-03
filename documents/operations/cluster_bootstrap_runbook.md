# Cluster Bootstrap Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../engineering/cluster_topology.md](../engineering/cluster_topology.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../development/testing_strategy.md](../development/testing_strategy.md)

> **Purpose**: Operator-facing reference for cluster lifecycle — the outer
> `hostbootstrap cluster ...` entry, the inner `daemon-substrate-test cluster ...`
> reconcilers, and the lifecycle phases the operator should expect to see during each.

## TL;DR

- `hostbootstrap cluster up` is the outer entry on both cohorts. It builds the project
  artifact (binary on Apple, container on Linux) and launches the appropriate model.
- `daemon-substrate-test cluster up` is the inner reconciler that reconciles the kind cluster
  + Harbor / Pulsar / MinIO / orchestrator topology. It runs inside the project container on
  Linux and on the host on Apple.
- Both commands are idempotent. Safe to re-run.
- `cluster down` (outer or inner) preserves `./.data/` and `./.build/` so the next `up` is
  fast.
- Long-running phases (Docker image build, Harbor publication) refresh a heartbeat roughly
  every 30 seconds. Wall-clock duration alone is not failure; heartbeat staleness is.

## Ownership boundary

- **Outer (hostbootstrap)**: substrate detection, host prereqs, base image / project image
  build, container or LaunchDaemon lifecycle, `.data` preservation.
- **Inner (daemon-substrate-test)**: kind create, Helm install of Harbor / Pulsar / MinIO,
  ConfigMap render, Deployment apply, MinIO bucket seeding, edge-port discovery, lifecycle
  phase transitions.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the full boundary statement.

## Bring-up

Apple Silicon (host-native worker via LaunchDaemon; in-cluster reconcilers on host):

```bash
hostbootstrap cluster up                           # outer: build binary, install LaunchDaemon
./.build/daemon-substrate-test cluster up          # inner: reconcile kind cluster (auto-invoked)
```

Linux CPU (outer container; in-cluster reconcilers inside the container):

```bash
hostbootstrap cluster up                           # outer: build container, run service
# inner runs automatically inside the container
hostbootstrap run daemon-substrate-test cluster up # invoke inner directly if needed
```

`cluster up` reconciles, in order:

1. **Kind cluster**: create if missing; verify control-plane + three worker nodes are ready
2. **Manual storage**: install the `daemon-substrate-manual` StorageClass; provision durable
   PVs into `./.data/kind/<cohort>/<namespace>/<release>/...`
3. **Helm dependencies**: build/refresh Harbor, Pulsar, MinIO chart dependencies
4. **Harbor bootstrap**: bring up Harbor, wait for its TLS cert, push
   `daemon-substrate-test:local` to it
5. **Pulsar bootstrap**: bring up Pulsar broker; create the test-harness namespace; verify
   topics auto-create on first publish
6. **MinIO bootstrap**: bring up MinIO; create the two harness buckets; seed mock weight
   blobs
7. **ConfigMaps**: render `configmap-orchestrator` and `configmap-worker` from staged Dhall
8. **Orchestrator Deployment**: roll out; wait for readiness
9. **Worker Deployment** (Linux CPU cohort only): roll out two replicas with anti-affinity
10. **Edge port discovery**: pick port (9090 first; increment on conflict); persist to
    `edge-port.json`; print to operator

Each phase emits a heartbeat. `cluster status` displays the current phase, the heartbeat
timestamp, and any per-phase detail.

## Status

```bash
./.build/daemon-substrate-test cluster status        # Apple
hostbootstrap run daemon-substrate-test cluster status   # Linux
```

Reports:

- current `lifecyclePhase` (one of `Bootstrap`, `AcquireClients`, `ProbeClients`, `Ready`,
  `Draining`, `Exit`)
- `lifecycleDetail`: free-form descriptor of what the current phase is doing
- `lifecycleHeartbeatAt`: monotonic timestamp of the most recent heartbeat update
- cluster node readiness summary
- Harbor / Pulsar / MinIO pod readiness summary
- orchestrator and worker Deployment readiness

`cluster status` does not mutate Kubernetes state, repo-local state, or the chosen edge port.

## Heartbeat-driven progress interpretation

Some phases run for minutes (Docker image build on first invocation, Harbor's TLS cert
issuance, MinIO seeding). The operator should not interpret long durations as failure. The
heartbeat refreshes every ~30 seconds while the phase is making progress; only a stalled
heartbeat (no update for several minutes) is a failure signal.

Typical bring-up durations:

| Phase | First run | Subsequent runs |
|-------|-----------|-----------------|
| Docker image build (Linux only) | 5–10 min | < 30 s (cached layers) |
| Kind cluster create | 1–2 min | 0 (already exists) |
| Harbor bootstrap | 2–4 min | < 30 s |
| Pulsar bootstrap | 1–2 min | < 30 s |
| MinIO bootstrap + seed | < 30 s | < 10 s |
| Workload deployment | < 30 s | < 10 s |

## Teardown

```bash
hostbootstrap cluster down                           # both cohorts (outer)
./.build/daemon-substrate-test cluster down          # Apple, inner only
hostbootstrap run daemon-substrate-test cluster down # Linux, inner only
```

Tears down the Kind cluster and all in-cluster resources. Preserves:

- `./.data/` — durable cluster state (PV-backing files); `hostbootstrap` never deletes this
- `./.build/` — compiled binary (Apple), staged Dhall, kubeconfig, edge-port record
- the project container image (Linux only; rebuilt only by `hostbootstrap cluster up
  --build-base` or `cluster delete` then `up`)
- installed host prerequisites

A subsequent `cluster up` reuses the preserved state and is significantly faster than the
first bring-up. `hostbootstrap cluster delete` performs a thorough teardown (cluster +
derived state) but still preserves `./.data/`.

## Edge port

`daemon-substrate-test cluster up` tries to bind port 9090 first; on conflict it increments
linearly until an open port is found. The chosen port is:

- persisted under `./.build/edge-port.json` (Apple) or `./.data/runtime/edge-port.json` (Linux)
- printed to the operator during bring-up
- read by the host-native Apple worker at startup to find the in-cluster Pulsar / MinIO
  endpoints

`cluster down` does not delete the edge-port record, so a subsequent `up` keeps the same port
if it is still available.

## Kubeconfig

The repo-local kubeconfig is the only authoritative handle to the harness cluster:

| Substrate | Path |
|-----------|------|
| Apple Silicon | `./.build/daemon-substrate.kubeconfig` |
| Linux CPU | `./.data/runtime/daemon-substrate.kubeconfig` |

Neither path mutates the operator's `~/.kube/config`. To use `kubectl` directly:

```bash
KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get pods -A   # Apple
hostbootstrap run kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig get pods -A   # Linux
```

## Cross-references

- What gets deployed: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Apple-specific operator workflow: [apple_silicon_runbook.md](apple_silicon_runbook.md)
- Linux-specific operator workflow: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- Testing strategy: [../development/testing_strategy.md](../development/testing_strategy.md)
