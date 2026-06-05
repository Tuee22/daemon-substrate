# Apple Silicon Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [linux_cpu_runbook.md](linux_cpu_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Apple Silicon host-native operator workflow for the `daemon-substrate-test`
> harness — prerequisites, bring-up, the host worker foreground daemon lifecycle, and recovery
> guidance.

## TL;DR

- Apple Silicon selects the `AppleSilicon` entry in `hostbootstrap.dhall`, which uses the
  `HostDaemon` model.
- `hostbootstrap cluster up` builds `./.build/daemon-substrate-test`, forwards
  `daemon-substrate-test cluster up`, and exits.
- `hostbootstrap daemon run` runs
  `daemon-substrate-test service --role worker --config dhall/worker.dhall` as a foreground
  process. The caller owns logs, restart, and termination.
- Stop the foreground daemon process before `hostbootstrap cluster down` or
  `hostbootstrap cluster delete`.
- `hostbootstrap` does not install launchd units. After reboot, run `hostbootstrap cluster up`
  again and restart `hostbootstrap daemon run`.
- The kind cluster, Harbor, Pulsar, MinIO, and orchestrator run inside the local Docker runtime;
  the worker runs outside the cluster on macOS.

## Prerequisites

Minimal pre-existing host state:

- macOS on Apple Silicon
- Homebrew
- `pipx` with `hostbootstrap` installed via `pipx`
- `ghcup`

`hostbootstrap doctor` verifies the host and reports missing prerequisites. Apple host-native
builds use ghcup-provided `ghc-9.12.4` and Cabal. The Docker runtime and Kubernetes tools are
used for the kind cluster and are validated by `hostbootstrap`.

## Bring-up

```bash
hostbootstrap doctor
hostbootstrap cluster up
hostbootstrap daemon run
```

For single-machine matrix validation from another host:

```bash
hostbootstrap cluster up --force-target apple-silicon
```

On Apple Silicon, `cluster up`:

1. Builds `./.build/daemon-substrate-test` with the templated hostbootstrap Cabal command.
2. Runs `./.build/daemon-substrate-test cluster up`.
3. Returns without starting or supervising the worker daemon.

Run `hostbootstrap daemon run` after `cluster up` to start the host worker in the foreground.
Use a second terminal for local development, or a launchd/systemd unit if you want supervision.

The inner reconciler rolls out Harbor / Pulsar / MinIO, PVC-backed storage, the orchestrator
Deployment, and edge-port forwarding. The host worker reads the edge-port record and subscribes
to the Apple Silicon harness work topic.

## Host Worker

The worker:

- reads `dhall/worker.dhall`
- discovers Pulsar / Pulsar admin / MinIO endpoints from `./.build/edge-port.json`
- subscribes to `test.batch.apple-silicon` in `Shared` mode
- writes its local cache to `./.cache/daemon-substrate-worker/`
- logs to the foreground stdout/stderr stream owned by the invoking shell or supervisor

For direct inner debugging, use the same foreground process shape without hostbootstrap:

```bash
hostbootstrap cluster down
./.build/daemon-substrate-test cluster up --model host-daemon
./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall
```

## Teardown

```bash
# Stop the foreground hostbootstrap daemon run process with Ctrl-C or supervisor termination.
hostbootstrap cluster down
hostbootstrap cluster delete
```

Preserved state:

- `./.data/`
- `./.build/` artifacts that remain useful for debugging
- `./.cache/daemon-substrate-worker/`
- installed Homebrew / ghcup-managed prerequisites

## Reboot Policy

`hostbootstrap` intentionally does not install launchd units. A reboot stops the repo-local host
daemon process and any Docker runtime state that is not otherwise managed by the operator. Bring
the harness back with:

```bash
hostbootstrap cluster up
hostbootstrap daemon run
```

Operators who want automatic boot-time startup can create their own launchd unit outside
`hostbootstrap`; that unit should supervise `hostbootstrap daemon run` directly.

## Recovery From Common Failures

### Cluster pods stuck in `Pending`

The Apple Silicon harness topology uses a host-native worker, so the worker is not scheduled as
an in-cluster Deployment. Check nodes with:

```bash
kubectl --kubeconfig ./.build/daemon-substrate.kubeconfig get nodes
```

If topology is wrong, run `hostbootstrap cluster down` followed by `hostbootstrap cluster up`.

### Edge port collision

The bring-up flow increments from the default base port until it finds an available range. Check
`./.build/edge-port.json` for the chosen ports and rerun `hostbootstrap cluster up` so the host
worker can be restarted with the current record.

### Host worker cannot reach Pulsar

Check the Pulsar admin edge port in `./.build/edge-port.json`. If the port is closed but
dependency pods are Ready, rerun `hostbootstrap cluster up` to refresh edge-port forwarding,
then restart the foreground daemon process.

### Docker runtime not running

Start the local Docker runtime and rerun `hostbootstrap cluster up`. `hostbootstrap doctor`
reports missing or unreachable Docker prerequisites but does not own reboot-time startup.

## What This Runbook Does Not Cover

- Real ML workloads; the mock engine performs no Metal work.
- Multiple host workers on the same Apple machine.
- Networking between multiple Apple hosts.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Linux equivalent: [linux_cpu_runbook.md](linux_cpu_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
