# Cluster Bootstrap Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../engineering/cluster_topology.md](../engineering/cluster_topology.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../development/testing_strategy.md](../development/testing_strategy.md)

> **Purpose**: Operator-facing reference for cluster lifecycle — the outer
> `hostbootstrap cluster ...` entry, the inner `daemon-substrate-test cluster ...`
> reconcilers, and the lifecycle phases the operator should expect to see.

## TL;DR

- `hostbootstrap cluster up` is the outer entry. It detects the host, selects the matching
  substrate entry in `hostbootstrap.dhall`, builds the project artifact, and forwards
  `daemon-substrate-test cluster up`.
- The declared target map is Apple Silicon `HostDaemon`, Linux CPU `Container`, Linux GPU
  `Container` with the CUDA-flavored base image.
- `hostbootstrap cluster down` forwards `cluster down`; `hostbootstrap cluster delete`
  forwards `cluster delete`.
- For `HostDaemon`, run `hostbootstrap daemon run` as a separate foreground process after
  `cluster up`, and terminate it before `cluster down` / `cluster delete`.
- `hostbootstrap` does not install launchd/systemd units and does not create Docker containers
  that restart after reboot. Run `hostbootstrap cluster up` after each reboot.
- `--force-target <apple-silicon|linux-cpu|linux-gpu>` lets one physical host exercise any
  declared hostbootstrap target for validation. It is separate from the inner 3x3 integration
  matrix.
- `./.data/` is preserved by outer lifecycle commands.

## Ownership Boundary

- **Outer (`hostbootstrap`)**: substrate detection, host prereq checks, base image selection,
  project image or native-binary build, one-shot container run, host-binary invocation,
  foreground `HostDaemon` invocation through `hostbootstrap daemon run`, and
  `cluster up/down/delete` forwarding.
- **Inner (`daemon-substrate-test`)**: kind create, Helm install of Harbor / Pulsar / MinIO,
  ConfigMap render, Deployment apply, MinIO bucket seeding, edge-port discovery, lifecycle phase
  transitions, and readiness checks.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the full boundary statement.

## Target Matrix

| Target | Normal host | Model | Worker placement |
|--------|-------------|-------|------------------|
| `apple-silicon` | macOS arm64 | `HostDaemon` | host-native worker process |
| `linux-cpu` | Ubuntu/Linux without NVIDIA runtime | `Container` | single in-cluster worker Deployment |
| `linux-gpu` | Ubuntu/Linux with NVIDIA runtime | `Container` | single in-cluster worker Deployment |

Use `--force-target` on `build`, `run`, and `cluster ...` commands when validating another
target on the current host.

## Bring-up

Normal detected-host bring-up:

```bash
hostbootstrap doctor
hostbootstrap cluster up
```

On the AppleSilicon `HostDaemon` target, start the host worker in a second terminal, service
manager, or test-harness process after the cluster is up:

```bash
hostbootstrap daemon run
```

Forced target bring-up:

```bash
hostbootstrap cluster up --force-target apple-silicon
hostbootstrap cluster up --force-target linux-cpu
hostbootstrap cluster up --force-target linux-gpu
```

The inner `cluster up` reconciles, in order:

1. **Kind cluster**: create if missing; treat an existing cluster as a successful no-change
   action; verify the model-specific node topology.
2. **Manual storage**: install the `daemon-substrate-manual` StorageClass and provision durable
   PVs backed by `./.data/kind/...`.
3. **Image publication**: reuse or build the harness artifact as needed, deploy Harbor, and
   upload the harness image into the fresh cluster's Harbor registry.
4. **Helm dependencies**: build or refresh Harbor, Pulsar, and MinIO chart dependencies.
5. **Dependency readiness**: wait for Harbor, Pulsar, and MinIO StatefulSets to become ready.
6. **Pulsar bootstrap**: create the harness tenant, namespace, and topics idempotently.
7. **MinIO bootstrap**: create the harness buckets and seed mock blobs.
8. **ConfigMaps**: render orchestrator and worker Dhall ConfigMaps.
9. **Orchestrator Deployment**: roll out and wait for readiness.
10. **Worker**: roll out one in-cluster worker for `Container` / `HostBinary`, or use one
    caller-owned foreground `hostbootstrap daemon run` process for `HostDaemon`.
11. **Edge port discovery / forwarding**: pick and persist Pulsar, Pulsar admin, and MinIO edge
    ports; host-native paths use those records to reach in-cluster services.

## Ready Definition

The cluster is `Ready` when these conditions hold:

1. Kind node count matches the selected model topology.
2. Pulsar admin is reachable on the chosen edge port.
3. Every MinIO bucket named in `LifecyclePolicy` exists.
4. The orchestrator Deployment is `2/2` Ready.
5. The worker is Ready: one in-cluster worker for `Container` / `HostBinary`, one host-native
   process for `HostDaemon`.
6. `runReconciler` has completed at least one full tick.

`daemon-substrate-test test integration` uses this readiness contract inside each of its nine
model/workflow cases, creating and tearing down a fresh cluster per case. See
[../reference/cli_surface.md](../reference/cli_surface.md) and
[../development/testing_strategy.md](../development/testing_strategy.md).

## Status

Use the outer `run` path for the selected target:

```bash
hostbootstrap run cluster status
hostbootstrap run --force-target linux-gpu cluster status
```

For direct inner debugging, the harness still accepts `--model`:

```bash
./.build/daemon-substrate-test cluster status --model host-daemon
./.build/daemon-substrate-test cluster status --model host-binary
hostbootstrap run cluster status --model container
```

`cluster status` does not mutate Kubernetes state, repo-local state, or the chosen edge port.

## Teardown

```bash
hostbootstrap cluster down
hostbootstrap cluster delete
```

`cluster down` reconciles cluster absence while preserving repo-local durable state. `cluster
delete` is the thorough inner teardown path and still preserves `./.data/`.

Preserved state:

- `./.data/` — durable cluster state and PV-backing files
- installed host prerequisites
- local Docker layer cache

For `HostDaemon`, stop the foreground `hostbootstrap daemon run` process before running
`cluster down` or `cluster delete`. hostbootstrap does not track a PID file or stop that process
for you.

## Reboot Policy

No `hostbootstrap` lifecycle artifact is intended to survive reboot as an automatically
restarted service. Docker invocations are one-shot and host daemon processes are caller-owned
foreground processes. After reboot:

```bash
hostbootstrap cluster up
hostbootstrap daemon run  # HostDaemon target only
```

Operators who want boot-time automation can create their own launchd/systemd unit outside
`hostbootstrap`; that unit should supervise `hostbootstrap daemon run` directly.

## Kubeconfig

The repo-local kubeconfig is the only authoritative handle to the harness cluster:

| Execution model | Path |
|-----------------|------|
| `host-binary` / `host-daemon` | `./.build/daemon-substrate.kubeconfig` |
| `container` | `./.data/runtime/daemon-substrate.kubeconfig` |

Neither path mutates the operator's global kubeconfig. To use `kubectl` directly:

```bash
kubectl --kubeconfig ./.build/daemon-substrate.kubeconfig get pods -A
hostbootstrap run kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig get pods -A
```

## Cross-references

- Apple runbook: [apple_silicon_runbook.md](apple_silicon_runbook.md)
- Linux CPU runbook: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Testing strategy: [../development/testing_strategy.md](../development/testing_strategy.md)
