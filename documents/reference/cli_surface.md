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

## Current Status

The cluster, test, `service`, and `check-code` command families below are implemented. Cluster
commands accept an explicit execution model (`container`, `host-binary`, or `host-daemon`) so
the per-model `hostbootstrap` specs can select worker placement without host-keyed branching in
the inner CLI. The `check-code` subcommand is wired into the project Dockerfile as
`RUN daemon-substrate-test check-code` and delegates to the local style gate.

## Top-level commands

Current implementation note: Phase 8 Sprint 8.6 implements live Cabal delegation for
`test ...`, concrete kind / kubectl / helm / Docker execution for `cluster ...` actions,
live Pulsar and MinIO admin operations through the dependency pods, PVC-backed dependency
state, live worker / orchestrator `service` loops, managed Apple edge-port forwarding, and
Apple live workflow handoff. Linux hostbootstrap container bring-up, preserved-state
kind-cluster cycles, worker/orchestrator readiness, retained PVC binding, edge-port
preservation, and the `daemon-substrate-integration` live readiness gate are validated.

| Command | Purpose | Long-running? | Idempotent? |
|---------|---------|---------------|-------------|
| `daemon-substrate-test cluster up [--model <container\|host-binary\|host-daemon>] [--stay-resident]` | Bring up the kind cluster + harness workloads for the selected execution model | optional | yes |
| `daemon-substrate-test cluster down [--model <container\|host-binary\|host-daemon>]` | Tear down the kind cluster for the selected execution model | no | yes |
| `daemon-substrate-test cluster status [--model <container\|host-binary\|host-daemon>]` | Report current kind/node status; target lifecycle state | no | yes (read-only) |
| `daemon-substrate-test test unit` | Run `daemon-substrate-unit` test suite | no | yes |
| `daemon-substrate-test test integration` | Run `daemon-substrate-integration` live readiness suite; requires a running cluster | no | yes |
| `daemon-substrate-test test lint` | Run the local style suite | no | yes |
| `daemon-substrate-test test all` | Run lint + unit + lifecycle + integration in order | no | yes |
| `daemon-substrate-test check-code` | Run the Dockerfile build-gate style check | no | yes |
| `daemon-substrate-test service --role worker --config <path>` | Run the worker daemon | **yes** | n/a |
| `daemon-substrate-test service --role orchestrator --config <path>` | Run the orchestrator daemon | **yes** | n/a |

## Detail

### `cluster up`

Reconciles the kind cluster to the supported topology described in
[../engineering/cluster_topology.md](../engineering/cluster_topology.md). Steps in order:
kind create, manual StorageClass and PVs, local image build and kind image-load, Helm
dependency build and release upgrade, dependency readiness waits, Pulsar bootstrap, MinIO
bootstrap + seed, ConfigMap render, orchestrator Deployment, worker Deployment (Linux CPU
cohort), edge-port discovery.

`--model` defaults to `container`. The selected model determines worker placement and
repo-local runtime paths:

| Model | Worker placement | Runtime records |
|-------|------------------|-----------------|
| `container` | in-cluster worker Deployment | `./.data/runtime/` |
| `host-binary` | in-cluster worker Deployment | `./.build/` |
| `host-daemon` | host-native worker service | `./.build/` |

`--stay-resident` is only accepted with `cluster up`; the container spec uses it so a
successful service-container reconciliation does not exit and trigger restart-loop behavior.

Safe to re-run after any partial failure. The current runner executes the idempotent action
plan in order; existing resources are reused or verified by the underlying tool/admin action,
and an already-existing kind cluster is reported as a successful no-change action.

### `cluster down`

Reconciles cluster absence. Preserves `./.data/`, `./.build/`, the project container image
(Linux), and host prerequisites. Removing those is outside lifecycle teardown.

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

Invokes `cabal test daemon-substrate-integration`. The suite requires a repo-local
kubeconfig from `hostbootstrap cluster up`; it fails fast if the live cluster does not match
the supported node topology, dependency rollouts, daemon workload readiness, retained PVCs,
or edge-port record described in
[../development/testing_strategy.md § test integration](../development/testing_strategy.md).

### `test lint`

Runs `cabal test daemon-substrate-haskell-style`. The style suite enforces the documentation
metadata/link/phase-structure validator and the direct `Daemon.Proto.*` import boundary.

### `test all`

Runs `test lint`, `test unit`, `test lifecycle`, and `test integration` in order. Stops at
the first failure.

### `check-code`

Runs the same local gate as `test lint`. The project Dockerfile invokes this subcommand during
image build so stale docs or invalid direct proto imports fail before the service container is
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

There is no `--substrate`, `--accel`, or `DAEMON_SUBSTRATE_*` flag on any
`daemon-substrate-test` command. The acceleration target (`H.Accel.Cpu`) is selected at the
`hostbootstrap` layer via the active spec file (`--spec`). The execution model is passed
explicitly to inner cluster commands with `--model` by the project specs and persisted beside
the edge-port record for the integration gate.

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
(`pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"`). Each
command accepts `--spec <file>` to select the execution model (`hostbootstrap.dhall` =
`Container` default, `hostbootstrap-hostbinary.dhall` = `HostBinary`,
`hostbootstrap-hostdaemon.dhall` = `HostDaemon`):

| Command | Purpose |
|---------|---------|
| `hostbootstrap doctor` | Detect host; idempotently install host prereqs |
| `hostbootstrap build` | Build the project artifact (container image or native binary) per the active spec |
| `hostbootstrap cluster up` | Build artifact; launch per the model declared in the active spec |
| `hostbootstrap cluster down` | Tear down (preserves `./.data/`) |
| `hostbootstrap cluster delete` | Thorough teardown (still preserves `./.data/`) |
| `hostbootstrap run <cmd...>` | Dispatch into the project container (`Container`) or run the host binary directly (`HostBinary` / `HostDaemon`) |

Status reporting is owned by the inner `daemon-substrate-test cluster status` command.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the boundary between outer and inner commands.

## Cross-references

- Cabal stanzas that produce the binary: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- What each `test` command actually asserts: [../development/testing_strategy.md](../development/testing_strategy.md)
- What `cluster up` deploys: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Outer entry contract: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Operator-facing workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
