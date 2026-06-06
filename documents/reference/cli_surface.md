# CLI Surface (`daemon-substrate-test`)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)

> **Purpose**: Authoritative inventory of the `daemon-substrate-test` executable's command
> surface, what each command does, and which commands are idempotent reconcilers vs. long-
> running daemons.

## TL;DR

- `daemon-substrate-test` is the only binary the substrate produces, and it exists only for
  the test harness.
- Three command families: `cluster ...`, `test ...`, `service`.
- `service` is the only long-running entrypoint. Everything else is an idempotent reconciler.
- All non-`service` commands are safe to re-run.
- The outer operator entrypoint is `hostbootstrap cluster up`, not
  `daemon-substrate-test cluster up` directly. The `daemon-substrate-test cluster ...`
  subcommands are the *inner* reconcilers, invoked from inside the `Container` model's project
  container or as the `HostBinary` / `HostDaemon` host process. See
  [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).
- For the `HostDaemon` target, the host worker itself is run by
  `hostbootstrap daemon run` as a foreground process after cluster bring-up.

## Current Status

The cluster, test, `service`, and `check-code` command families below are implemented. Outer
`hostbootstrap cluster up/down/delete` commands forward plain inner `cluster up/down/delete`.
For direct debugging, cluster commands still accept an explicit execution model (`container`,
`host-binary`, or `host-daemon`). The `check-code` subcommand is wired into the project
Dockerfile as `RUN daemon-substrate-test check-code` and delegates to the local style gate.

## Top-level commands

Current implementation note: Phase 8 Sprint 8.6 implements live Cabal delegation for
`test ...`, concrete kind / kubectl / helm / Docker execution for `cluster ...` actions,
live Pulsar and MinIO admin operations through the dependency pods, PVC-backed dependency
state, live worker / orchestrator `service` loops, managed Apple edge-port forwarding, and
Apple live workflow handoff. Container-model `test integration` and `test all` runs attach
the current project container to Docker's `kind` network before Cabal delegation. Phase 8 is
reopened because `daemon-substrate-integration` must become the full nine-case matrix runner,
creating and tearing down a fresh cluster per case instead of checking one preexisting
environment.

| Command | Purpose | Long-running? | Idempotent? |
|---------|---------|---------------|-------------|
| `daemon-substrate-test cluster up [--model <container\|host-binary\|host-daemon>] [--stay-resident]` | Bring up the kind cluster + harness workloads for the selected execution model | optional | yes |
| `daemon-substrate-test cluster down [--model <container\|host-binary\|host-daemon>]` | Tear down the kind cluster for the selected execution model | no | yes |
| `daemon-substrate-test cluster delete [--model <container\|host-binary\|host-daemon>]` | Thoroughly tear down the kind cluster for the selected execution model | no | yes |
| `daemon-substrate-test cluster status [--model <container\|host-binary\|host-daemon>]` | Report current kind/node status; target lifecycle state | no | yes (read-only) |
| `daemon-substrate-test test unit` | Run `daemon-substrate-unit` test suite | no | yes |
| `daemon-substrate-test test lifecycle` | Run `daemon-substrate-lifecycle` test suite | no | yes |
| `daemon-substrate-test test integration` | Run the nine-case model × workflow integration matrix; owns cluster create/upload/teardown for each case | no | yes |
| `daemon-substrate-test test lint` | Run the local style suite | no | yes |
| `daemon-substrate-test test all` | Run lint + unit + lifecycle + integration in order | no | yes |
| `daemon-substrate-test check-code` | Run the Dockerfile build-gate style check | no | yes |
| `daemon-substrate-test service --role worker --config <path>` | Run the worker daemon | **yes** | n/a |
| `daemon-substrate-test service --role orchestrator --config <path>` | Run the orchestrator daemon | **yes** | n/a |

## Detail

### `cluster up`

Reconciles the kind cluster to the supported topology described in
[../engineering/cluster_topology.md](../engineering/cluster_topology.md). Steps in order:
kind create, manual StorageClass and PVs, Harbor deployment and harness image upload, Helm
dependency build and release upgrade, dependency readiness waits, Pulsar bootstrap, MinIO
bootstrap + seed, ConfigMap render, coordinator/orchestrator Deployment, worker placement for
the selected execution model, edge-port discovery.

When invoked by `hostbootstrap`, the selected target supplies the execution model. Direct inner
invocations default to `container` unless `--model` is provided. The selected model determines
worker placement and repo-local runtime paths:

| Model | Worker placement | Runtime records |
|-------|------------------|-----------------|
| `container` | in-cluster worker Deployment | `./.data/runtime/` |
| `host-binary` | in-cluster worker Deployment | `./.build/` |
| `host-daemon` | host-native worker service | `./.build/` |

`--stay-resident` is only accepted with direct `cluster up` debugging. The `hostbootstrap`
container lifecycle is one-shot and does not use a restart loop.

Safe to re-run after any partial failure. The current runner executes the idempotent action
plan in order; existing resources are reused or verified by the underlying tool/admin action,
and an already-existing kind cluster is reported as a successful no-change action.

### `cluster down`

Reconciles cluster absence. Preserves `./.data/`, `./.build/`, the project container image
(Linux), and host prerequisites. Removing those is outside lifecycle teardown.

### `cluster delete`

Runs the same absence reconciliation as `cluster down` today and is the reserved thorough
teardown verb forwarded by `hostbootstrap cluster delete`. It remains idempotent and preserves
`./.data/`.

### `cluster status`

Read-only. Reports:

- node readiness
- known kind clusters

The target status report also includes `lifecyclePhase`, `lifecycleDetail`,
`lifecycleHeartbeatAt`, in-cluster workload readiness, and the chosen edge port. That richer
report remains target telemetry. The current command does not mutate Kubernetes resources,
repo-local state, or the edge-port record.

### `test unit`

Invokes `cabal test daemon-substrate-unit`. Pure Haskell tests; no cluster required.

### `test integration`

Invokes `cabal test daemon-substrate-integration`. The target suite creates and tears down one
fresh kind cluster for each execution-model/workflow-archetype matrix cell. It deploys Harbor /
Pulsar / MinIO, uploads the already-built harness image through Harbor, deploys two
coordinator/orchestrator replicas plus exactly one worker in the selected placement, runs the
workflow assertions, checks cluster status, and tears the cluster down before the next case.
For the `container` execution model, the command attaches the current project container to
Docker's `kind` network before using the internal kind API endpoint.

### `test lint`

Runs `cabal test daemon-substrate-haskell-style`. The style suite enforces the documentation
metadata/link/phase-structure validator and the direct `Daemon.Proto.*` import boundary.

### `test all`

Runs `test lint`, `test unit`, `test lifecycle`, and `test integration` in order. Stops at
the first failure. Because `test integration` owns cluster lifecycle, `test all` does not
require a preexisting kind cluster.

### `check-code`

Runs the same local gate as `test lint`. The project Dockerfile invokes this subcommand during
image build so stale docs or invalid direct proto imports fail before the project image is
produced.

### `service`

The only long-running daemon entrypoint. Required flags:

- `--role worker` or `--role orchestrator`
- `--config <path-to-dhall>`

The role selects which base loop runs (`Daemon.Worker.runWorker` or
`Daemon.Orchestrator.runOrchestrator`). The Dhall file is decoded into `BootConfig role app`;
the daemon then proceeds through its lifecycle phases.

## Configuration-file independence

The lint and docs validators are configuration-file independent. The cluster, test, and
`service` commands read their settings from the staged Dhall configuration via binary-owned
preflight; they fail fast with a diagnostic if it cannot be materialized or validated.

There is no `--substrate` or `--accel` flag on any `daemon-substrate-test` command. The
substrate target is selected at the `hostbootstrap` layer from the single
`hostbootstrap.dhall`, optionally overridden with `--force-target`. The selected execution
model is persisted beside each matrix case's edge-port record for integration assertions.

## What is not a supported command

- A `daemon-substrate` binary. The library is consumed by name; it does not produce a
  general-purpose CLI.
- `daemon-substrate-test e2e`. Reserved for future use; not currently implemented.
- `daemon-substrate-test docs check`, `lint files`, etc. as separate top-level commands. They
  are subcommands of `test lint` for now; revisit if the harness grows.

## Outer entry: hostbootstrap

`daemon-substrate-test` is the *inner* CLI; the *outer* entry is
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap). The relevant outer commands:

`hostbootstrap` is installed via `pipx` only
(`pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"`). The
single `hostbootstrap.dhall` maps Apple Silicon to `HostDaemon`, Linux CPU to `Container`, and
Linux GPU to `Container` with the CUDA-flavored base image; lifecycle commands accept
`--force-target` for validation:

| Command | Purpose |
|---------|---------|
| `hostbootstrap doctor` | Detect host; idempotently install host prereqs |
| `hostbootstrap build [--force-target <substrate>]` | Build the selected project artifact |
| `hostbootstrap cluster up [--force-target <substrate>]` | Build artifact; forward `daemon-substrate-test cluster up` |
| `hostbootstrap cluster down [--force-target <substrate>]` | Tear down (preserves `./.data/`) |
| `hostbootstrap cluster delete [--force-target <substrate>]` | Thorough teardown (still preserves `./.data/`) |
| `hostbootstrap daemon run [--force-target <substrate>]` | Run the selected HostDaemon worker as a foreground process |
| `hostbootstrap run [--force-target <substrate>] <cmd...>` | Dispatch to the project entrypoint for the selected target |

Status reporting is owned by the inner `daemon-substrate-test cluster status` command.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the boundary between outer and inner commands.

## Cross-references

- Cabal stanzas that produce the binary: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- What each `test` command actually asserts: [../development/testing_strategy.md](../development/testing_strategy.md)
- What `cluster up` deploys: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Outer entry contract: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Operator-facing workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
