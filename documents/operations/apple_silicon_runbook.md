# Apple Silicon Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Apple Silicon host-native operator workflow for the `daemon-substrate-test`
> harness — prerequisites, bring-up, the on-host worker daemon lifecycle, and recovery
> guidance.

## TL;DR

- Apple Silicon is the supported host-native cohort. The `daemon-substrate-test` binary builds
  and runs directly on macOS arm64; no Docker container layer for the worker.
- The substrate is brought up by `hostbootstrap cluster up`, which builds the binary via
  `cabal install` and installs a system-scope LaunchDaemon (per the `HostDaemon` model
  declared in `hostbootstrap.dhall`).
- The kind cluster (Harbor, Pulsar, MinIO, orchestrator) runs inside Colima.
- The worker daemon runs as `./.build/daemon-substrate-test service --role worker` *outside*
  the cluster on the host, under the LaunchDaemon `hostbootstrap` installed.
- `./.build/` carries the compiled binary, the staged Dhall, the kubeconfig, and the edge-port
  record.

## Prerequisites

Minimal pre-existing host state:

- macOS on Apple Silicon (arm64)
- Python 3.12 (system Python is fine) with `hostbootstrap` installed (see
  [../development/local_dev.md](../development/local_dev.md))
- Homebrew installed (`hostbootstrap doctor` will refuse to run without it)
- `ghcup` installed and on `$PATH`

`hostbootstrap doctor` installs / verifies:

- GHC 9.12 via ghcup
- Cabal (paired with the GHC pin) via ghcup
- `protoc` via Homebrew
- Colima via Homebrew (the only supported Docker environment on Apple Silicon)
- Kind, `kubectl`, `helm` via Homebrew

These match the prereqs the `HostDaemon` model's `H.HostReqs` declares for this repository.

## Bring-up

```bash
hostbootstrap doctor              # one-time: install prereqs
hostbootstrap cluster up          # build binary, install LaunchDaemon
./.build/daemon-substrate-test cluster up  # inner kind-cluster reconciler
```

`hostbootstrap cluster up` is a restartable reconciler. On Apple Silicon it:

1. Builds `./.build/daemon-substrate-test` from source via the `cabal install` command
   declared in `hostbootstrap.dhall`'s `H.Build`
2. Installs the LaunchDaemon at `/Library/LaunchDaemons/com.hostbootstrap.daemon-substrate.plist`
   that runs `./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall`
3. Leaves in-cluster reconciliation to the inner `./.build/daemon-substrate-test cluster up`
   command. The inner reconciler now rolls out the dependency StatefulSets, PVC-backed
   storage, Pulsar / MinIO admin setup, orchestrator Deployment, and reconciler Failover
   leadership. It also starts managed localhost forwards for Pulsar, Pulsar admin, and
   MinIO; the host worker has been validated through a live request -> orchestrator -> host
   worker -> response smoke handoff. Full `Ready` validation remains active until Linux CPU
   cohort validation runs.

Subsequent bring-ups skip prerequisite verification when the active checkpoints match. The
LaunchDaemon starts the worker before any user logs in — supporting headless remote SSH.

To inspect:

```bash
launchctl list | grep daemon-substrate
launchctl print system/com.hostbootstrap.daemon-substrate
```

## On-host worker daemon

The worker runs under the LaunchDaemon as a long-running process. Recommended invocation for
foreground debugging (with the LaunchDaemon stopped):

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.hostbootstrap.daemon-substrate.plist
./.build/daemon-substrate-test service \
    --role worker \
    --config dhall/worker.dhall
```

The worker:

- reads its Dhall config (Pulsar endpoint, MinIO endpoint, cohort tag, cache directory)
- discovers the in-cluster Pulsar / Pulsar admin / MinIO endpoints via
  `./.build/edge-port.json`, whose `pulsarPort`, `pulsarAdminPort`, and `minioPort` fields
  map to managed localhost port-forwards
- subscribes to `test.batch.apple-silicon` in `Shared` mode
- writes its local cache to `./.cache/daemon-substrate-worker/`
- logs to stdout / stderr; LaunchDaemon-launched logs reach `os_log`

### Stopping the worker

`hostbootstrap cluster down` removes the LaunchDaemon cleanly. Foreground operator runs stop
on `Ctrl+C`; the worker traps SIGINT / SIGTERM, finishes the in-flight request, drains its
subscription cleanly, and exits.

## Teardown

```bash
hostbootstrap cluster down                    # remove LaunchDaemon
./.build/daemon-substrate-test cluster down   # inner kind-cluster teardown
```

Preserves `./.data/`, `./.build/`, the worker's `./.cache/`, and installed Homebrew /
ghcup-managed prerequisites. `hostbootstrap cluster delete` performs a thorough teardown but
still preserves `./.data/`.

## Recovery from common failures

### Cluster pods stuck in `Pending`

The Apple Silicon kind cluster is configured for one worker node plus one control-plane
because the Worker runs on the host, not as an in-cluster Deployment. Check with:

```bash
KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get nodes
```

If the node count does not match that topology, `daemon-substrate-test cluster down` +
`cluster up` re-creates the cluster with the supported topology.

### Edge port collision

Another process took 9090. The bring-up flow handles this automatically by incrementing.
Check `./.build/edge-port.json` for the actually-chosen port; restart the worker LaunchDaemon
so it reads the updated value:

```bash
sudo launchctl kickstart -k system/com.hostbootstrap.daemon-substrate
```

### Host worker cannot reach in-cluster Pulsar

Check the Pulsar admin edge port is reachable:
`curl http://localhost:<pulsarAdminPort>/admin/v2/clusters`. If the port is closed but
dependency pods are Ready, rerun `daemon-substrate-test cluster up` to recreate the managed
port-forwards, or `daemon-substrate-test cluster down` + `cluster up` to recreate the kind
cluster too.

### Colima not running

`colima status` reports the runtime state. `colima start` if stopped. `hostbootstrap doctor`
ensures Colima is running on first invocation but does not babysit it.

### LaunchDaemon failed to load

`sudo launchctl print system/com.hostbootstrap.daemon-substrate` reports the failure reason.
Common causes: missing binary at the declared path (re-run `hostbootstrap cluster up`),
permissions on `./.build/` (LaunchDaemons run as root; ensure the binary is readable).

## What this runbook does not cover

- Real ML workloads — the mock engine on the host performs no Metal work. Apple Metal
  validation lives in consumer projects (`infernix`) that bring real engines.
- Multiple host workers on the same Apple machine — the harness assumes one worker per host.
- Networking between two Apple hosts — the harness is single-host.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Linux equivalent: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
