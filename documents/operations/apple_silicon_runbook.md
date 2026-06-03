# Apple Silicon Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../development/local_dev.md](../development/local_dev.md)

> **Purpose**: Apple Silicon host-native operator workflow for the `daemon-substrate-test`
> harness — prerequisites, bring-up, the on-host worker daemon lifecycle, and recovery
> guidance.

## TL;DR

- Apple Silicon is the supported host-native cohort. The `daemon-substrate-test` binary builds
  and runs directly on macOS arm64; no Docker container layer.
- The kind cluster (Harbor, Pulsar, MinIO, orchestrator) runs inside Colima.
- The worker daemon runs as `./.build/daemon-substrate-test service --role worker` *outside*
  the cluster on the host, where it could theoretically reach Apple Metal (the mock engine
  does not).
- `./.build/` carries the compiled binary, the staged Dhall, the kubeconfig, and the edge-port
  record.

## Prerequisites

Minimal pre-existing host state:

- macOS on Apple Silicon (arm64)
- Homebrew installed (the bootstrap script will refuse to run without it)
- `ghcup` installed and on `$PATH`

The bootstrap script installs / verifies:

- GHC 9.14.1 via ghcup
- Cabal 3.16.1.0 via ghcup
- `protoc` via Homebrew
- Colima via Homebrew (the only supported Docker environment on Apple Silicon)
- Kind via Homebrew
- `kubectl` via Homebrew
- `helm` via Homebrew

## Bring-up

```bash
./bootstrap/apple-silicon.sh up
```

This is a restartable prerequisite reconciler. It:

1. Verifies / installs the prerequisites above
2. Builds `./.build/daemon-substrate-test` from source via `cabal install --installdir=./.build`
3. Stages Dhall configs under `./.build/`
4. Delegates to `./.build/daemon-substrate-test cluster up` for cluster lifecycle
5. After cluster `Ready`, prompts the operator to start the host worker (or starts it
   automatically depending on harness mode)

Subsequent bring-ups skip prerequisite verification when the active checkpoints match:

```bash
./.build/daemon-substrate-test cluster up
./.build/daemon-substrate-test service --role worker --config ./.build/daemon-substrate-worker.dhall
```

## On-host worker daemon

The worker is a long-running foreground process on Apple. Recommended invocation:

```bash
./.build/daemon-substrate-test service \
    --role worker \
    --config ./.build/daemon-substrate-worker.dhall
```

The worker:

- reads its Dhall config (Pulsar endpoint, MinIO endpoint, cohort tag, cache directory)
- discovers the in-cluster Pulsar / MinIO endpoints via the edge port in
  `./.build/edge-port.json`
- subscribes to `test.batch.apple-silicon` in `Shared` mode
- writes its local cache to `./.cache/daemon-substrate-worker/`
- logs to stdout / stderr

There is no daemonization wrapper. Operators may use `launchd` or `tmux` to keep the worker
running across terminal sessions; the harness itself does not provide one.

### Stopping the worker

`Ctrl+C` is the supported stop signal. The worker traps SIGINT / SIGTERM, finishes the
in-flight request, drains its subscription cleanly, and exits.

## Teardown

```bash
./.build/daemon-substrate-test cluster down
```

Preserves `./.build/`, `./.data/`, the worker's `./.cache/`, and installed Homebrew /
ghcup-managed prerequisites. Removing those is outside lifecycle teardown.

To stop only the host worker without tearing down the cluster, `Ctrl+C` the worker process.

## Recovery from common failures

### Cluster pods stuck in `Pending`

The kind cluster is configured for three worker nodes plus one control-plane; if the operator
manually altered the kind config, two-worker replicas may be unschedulable. Check with:

```bash
KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get nodes
```

If fewer than three worker nodes are present, `daemon-substrate-test cluster down` + `cluster
up` re-creates the cluster with the supported topology.

### Edge port collision

Another process took 9090. The bring-up flow handles this automatically by incrementing.
Check `./.build/edge-port.json` for the actually-chosen port; restart the host worker so it
reads the updated value.

### Host worker cannot reach in-cluster Pulsar

Check the edge port is reachable: `curl http://localhost:<port>/admin/v2/clusters`. If the
port is closed but the cluster says it is `Ready`, kind's port mapping is the likely
culprit; `cluster down` + `cluster up` re-establishes it.

### Colima not running

`colima status` reports the runtime state. `colima start` if stopped. The bootstrap script
ensures Colima is running on first invocation but does not babysit it.

## What this runbook does not cover

- Real ML workloads — the mock engine on the host performs no Metal work. Apple Metal
  validation lives in consumer projects (`infernix`) that bring real engines.
- Multiple host workers on the same Apple machine — the harness assumes one worker per host.
- Networking between two Apple hosts — the harness is single-host.

## Cross-references

- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Linux equivalent: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
