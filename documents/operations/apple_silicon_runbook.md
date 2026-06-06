# Apple Silicon Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Apple Silicon operator workflow for the `daemon-substrate-test` harness —
> prerequisites, the per-project Colima VM and resource budget, native host-GHC build, bring-up,
> the host worker process lifecycle, and recovery guidance.

## TL;DR

- On Apple Silicon the binary is built **natively on the host** (a Linux ELF cannot exec on
  macOS). The Python bootstrapper runs `ensure ghc` (via Homebrew/ghcup) and `ensure docker`.
- `ensure docker` provisions a **per-project Colima VM** sized to the `resources {cpu, memory,
  storage}` budget in the skeletal `hostbootstrap.dhall`. That VM is the Docker runtime for kind.
- `hostbootstrap cluster up` reads the skeletal `hostbootstrap.dhall`, builds
  `./.build/daemon-substrate-test`, and runs the inner `cluster up`. `./.build/` always holds a
  host-runnable binary.
- Under the host-daemon model the worker runs as a host-native process outside the cluster; the
  harness owns it during a test case. For manual debugging the operator runs it directly.
- `hostbootstrap` installs no launchd units. After reboot, run `hostbootstrap cluster up` again.
- The kind cluster, Harbor, Pulsar, MinIO, and orchestrator run inside the Colima VM's Docker
  runtime; the host worker runs outside the cluster on macOS.

## Prerequisites

Minimal pre-existing host state:

- macOS on Apple Silicon
- passwordless `sudo`
- Xcode Command Line Tools
- Homebrew

The Python bootstrapper reaches a fail-fast minimum and then reconciles the rest:

```bash
hostbootstrap ensure ghc      # ghcup-provided ghc-9.12.4 via Homebrew
hostbootstrap ensure docker   # provision per-project Colima VM sized to the budget
```

`ensure ghc` is required because Apple host-native builds use ghcup-provided `ghc-9.12.4` and
Cabal. `ensure tart` is build-only (Swift/Metal) and is not a runtime.

## Resource budget and Colima VM

`ensure docker` provisions a **per-project Colima VM** sized to the `resources` record in the
skeletal `hostbootstrap.dhall`. Nothing outside the project competes for that VM's cores,
memory, or storage, so the harness's kind cluster is bounded by the budget without cordoning
individual nodes (the Linux path uses kind node cordoning instead). See
[../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

## Bring-up

```bash
hostbootstrap ensure ghc
hostbootstrap ensure docker
hostbootstrap cluster up
```

On Apple Silicon, `cluster up`:

1. Reads the skeletal `hostbootstrap.dhall` and verifies the resource budget against the Colima
   VM.
2. Builds `./.build/daemon-substrate-test` natively on the host (host-GHC).
3. Runs `./.build/daemon-substrate-test cluster up`, which generates the project Dhall and
   reconciles the cluster.
4. Returns without supervising the worker process.

The inner reconciler rolls out Harbor / Pulsar / MinIO, PVC-backed storage, the orchestrator
Deployment, and edge-port forwarding. The host worker reads the edge-port record and subscribes
to the host work topic.

## Host Worker

The worker:

- reads its generated `worker.dhall`
- discovers Pulsar / Pulsar admin / MinIO endpoints from the profile's edge-port record
- subscribes to the host work topic in `Shared` mode
- writes its local cache to `./.cache/daemon-substrate-worker/`
- logs to the foreground stdout/stderr stream owned by the invoking process

During a `host-daemon` integration case the harness starts and owns this process for the
duration of the case. For manual debugging:

```bash
./.build/daemon-substrate-test service --role worker --config <generated-worker.dhall>
```

## Teardown

```bash
hostbootstrap cluster down
hostbootstrap cluster delete
```

Preserved state:

- `./.data/`
- `./.build/` artifacts (the host-runnable binary)
- `./.cache/daemon-substrate-worker/`
- installed Homebrew / ghcup-managed prerequisites and the Colima VM

## Reboot Policy

`hostbootstrap` intentionally does not install launchd units. A reboot stops the repo-local host
process and pauses the Colima VM. Bring the harness back with:

```bash
hostbootstrap cluster up
```

Operators who want automatic boot-time startup can create their own launchd unit outside
`hostbootstrap`.

## Recovery From Common Failures

### Cluster pods stuck in `Pending`

Under the host-daemon model the worker is not scheduled as an in-cluster Deployment. Check nodes:

```bash
kubectl --kubeconfig ./.build/daemon-substrate.kubeconfig get nodes
```

If topology is wrong, run `hostbootstrap cluster down` followed by `hostbootstrap cluster up`.

### Edge port collision

Bring-up increments from the default base port until it finds an available range. Check the
profile's edge-port record for the chosen ports and rerun `hostbootstrap cluster up`.

### Host worker cannot reach Pulsar

Check the Pulsar admin edge port in the edge-port record. If the port is closed but dependency
pods are Ready, rerun `hostbootstrap cluster up` to refresh edge-port forwarding, then restart the
worker process.

### Colima VM not running or under-resourced

Rerun `hostbootstrap ensure docker` to reconcile the per-project Colima VM to the resource budget,
then `hostbootstrap cluster up`. `hostbootstrap` reports a budget shortfall before bring-up.

## What This Runbook Does Not Cover

- Real ML workloads; the mock engine performs no Metal work.
- Multiple host workers on the same Apple machine.
- Networking between multiple Apple hosts.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Linux equivalent: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
