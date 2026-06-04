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
- Long-running phases (Docker image build, dependency rollout) are expected to refresh a
  heartbeat in the target lifecycle reporter. Until that lands, streamed action progress,
  subprocess output, and action completion are the current progress indicators.

## Ownership boundary

- **Outer (hostbootstrap)**: substrate detection, host prereqs, base image / project image
  build, container or LaunchDaemon lifecycle, `.data` preservation.
- **Inner (daemon-substrate-test)**: kind create, Helm install of Harbor / Pulsar / MinIO,
  ConfigMap render, Deployment apply, MinIO bucket seeding, edge-port discovery, lifecycle
  phase transitions.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the full boundary statement.

Current implementation note: Phase 6 has landed the `Daemon.Cluster.*` action-plan modules,
the Helm chart render surface, and the packaged harness Dhall configs. Phase 8 Sprint 8.6
adds concrete `kind`, `kubectl`, `helm`, Docker image build, kind image-load, Kubernetes
apply / rollout wait, Pulsar admin, MinIO admin, and edge-port execution. The dependency
charts are deployable local Harbor / Pulsar / MinIO StatefulSets with PVC-backed state, and
the service command runs live worker / orchestrator loops. Apple edge-port forwarding,
host-worker handoff, and a live request -> orchestrator -> host worker -> response smoke
handoff are validated. Full `Ready` cluster reconciliation remains active until Linux CPU
validation closes.

## Bring-up

Apple Silicon (host-native worker via LaunchDaemon; in-cluster reconcilers on host):

```bash
hostbootstrap cluster up                           # outer: build binary, install LaunchDaemon
./.build/daemon-substrate-test cluster up          # inner: reconcile kind cluster
```

Linux CPU (outer container; in-cluster reconcilers inside the container):

```bash
hostbootstrap cluster up                           # outer: build container, run service
# inner runs automatically inside the container
hostbootstrap run daemon-substrate-test cluster up # invoke inner directly if needed
```

`cluster up` reconciles, in order:

1. **Kind cluster**: create if missing; treat an already-existing cluster as a successful
   no-change action; verify the cohort-specific node count is ready
   (Apple Silicon: one worker; Linux CPU: three workers)
2. **Manual storage**: install the `daemon-substrate-manual` StorageClass; provision durable
   PVs into the kind node mount rooted at
   `/daemon-substrate-data/<cohort>/daemon-substrate`, backed by host files under
   `./.data/kind/<cohort>/daemon-substrate/...`
3. **Image build**: build `daemon-substrate-test:local` from the thin project Dockerfile and
   load it directly into the kind cluster
4. **Helm dependencies**: build/refresh Harbor, Pulsar, MinIO chart dependencies and upgrade
   the harness release
5. **Dependency readiness**: wait for Harbor, Pulsar, and MinIO StatefulSets to become ready
6. **Pulsar bootstrap**: run `pulsar-admin` inside the broker pod to create the
   test-harness tenant, namespace, and required topics idempotently
7. **MinIO bootstrap**: run `mc` inside the MinIO sidecar to create the three harness buckets
   (`weights`, `artifacts`, `archives`) and seed the mock weight
   blobs
8. **ConfigMaps**: render `configmap-orchestrator` and `configmap-worker` from the packaged
   chart Dhall files
9. **Orchestrator Deployment**: roll out; wait for readiness
10. **Worker Deployment** (Linux CPU cohort only): roll out two replicas with anti-affinity
11. **Edge port discovery / forwarding**: pick a base port (9090 first; increment on
    conflict); persist `pulsarPort`, `pulsarAdminPort`, and `minioPort` to `edge-port.json`;
    on Apple Silicon, start matching local port-forwards and record their pids

Each phase emits an action result. The target heartbeat / lifecycle report is still tracked by
the full `Ready` gate below; during `cluster up`, the current runner prints each action as it
starts and records no-change results such as `kind cluster already exists`. The current
`cluster status` implementation reports kind clusters and node readiness.

## "Ready" definition

The cluster is `Ready` when **all six** conditions hold:

1. Kind node count matches the cohort topology (Apple Silicon: control plane + one worker;
   Linux CPU: control plane + three workers).
2. The Pulsar admin API is reachable on the chosen edge port.
3. Every MinIO bucket named in `LifecyclePolicy` exists.
4. The orchestrator Deployment is `2/2` Ready (both replicas healthy).
5. The worker is `2/2` Ready on Linux CPU, or the host LaunchDaemon reports `Ready` on
   Apple Silicon.
6. `runReconciler` has completed at least one full tick (audit-topic entry observed for the
   current `LifecyclePolicy` generation).

The target lifecycle status report will surface any failing condition under
`lifecycleDetail`. This is the same definition used by the target
`daemon-substrate-test test integration` preflight (see
[../reference/cli_surface.md § test integration](../reference/cli_surface.md) and
[../development/testing_strategy.md](../development/testing_strategy.md)).

Current implementation caveat: the Apple Silicon inner cluster now satisfies the dependency
rollout, PVC preservation, in-place `cluster up`, reconciler Failover leadership,
host-worker edge-port handoff, and live workflow-handoff portions of this definition, but the
full `Ready` gate is still open until Linux CPU validation runs. `cluster status` is
currently a read-only kind / node status command; lifecycle-detail reporting and
integration-test preflight use the target definition once the Linux CPU gate lands.

## Status

```bash
./.build/daemon-substrate-test cluster status        # Apple
hostbootstrap run daemon-substrate-test cluster status   # Linux
```

Reports the known kind clusters and node readiness through the repo-local kubeconfig. The
target status report also includes:

- current `lifecyclePhase` (one of `Load`, `Prereq`, `Acquire`, `Ready`, `Serve`, `Drain`,
  `Exit`; the seven-phase `Daemon.Lifecycle.LifecyclePhase` defined in
  [../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md](../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md)
  Sprint 3.4 and serialized to the wire by `proto/daemon_substrate/lifecycle.proto`)
- `lifecycleDetail`: free-form descriptor of what the current phase is doing
- `lifecycleHeartbeatAt`: monotonic timestamp of the most recent heartbeat update
- Harbor / Pulsar / MinIO pod readiness summary
- orchestrator and worker Deployment readiness

`cluster status` does not mutate Kubernetes state, repo-local state, or the chosen edge port.

## Heartbeat-driven progress interpretation

Some phases run for minutes (Docker image build on first invocation, dependency rollout,
MinIO seeding). The operator should not interpret long durations as failure. The target
lifecycle reporter refreshes its heartbeat every ~30 seconds while a phase is making
progress; until that reporter lands, subprocess output and action completion are the current
progress indicators.

Typical bring-up durations:

| Phase | First run | Subsequent runs |
|-------|-----------|-----------------|
| Harness image build | 5–10 min | < 30 s (cached layers) |
| Kind cluster create | 1–2 min | 0 (already exists) |
| Dependency rollout | 2–4 min | < 30 s |
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
linearly until an open base port is found. The chosen ports are:

- persisted under `./.build/edge-port.json` (Apple) or `./.data/runtime/edge-port.json` (Linux)
- printed to the operator during bring-up
- read by the host-native Apple worker at startup to find the in-cluster Pulsar / MinIO
  endpoints

The record maps `pulsarPort` to Pulsar broker `6650`, `pulsarAdminPort` to Pulsar admin
`8080`, and `minioPort` to MinIO `9000`. On Apple Silicon, `cluster up` starts detached
`kubectl port-forward` processes for those mappings and writes their pids to
`edge-port.json.pids`; `cluster down` terminates those recorded pids before deleting the
kind cluster. `cluster down` does not delete the edge-port record, so a subsequent `up` keeps
the same base port if it is still available.

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
