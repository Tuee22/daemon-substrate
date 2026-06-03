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
- The outer operator entrypoint on both cohorts is `hostbootstrap cluster up`, not
  `daemon-substrate-test cluster up` directly. The `daemon-substrate-test cluster ...`
  subcommands are the *inner* reconcilers, invoked from inside the `Container` (Linux) or as
  the LaunchDaemon's process (Apple). See
  [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

## Top-level commands

| Command | Purpose | Long-running? | Idempotent? |
|---------|---------|---------------|-------------|
| `daemon-substrate-test cluster up` | Bring up the kind cluster + harness workloads | no | yes |
| `daemon-substrate-test cluster down` | Tear down the kind cluster | no | yes |
| `daemon-substrate-test cluster status` | Report cluster lifecycle state | no | yes (read-only) |
| `daemon-substrate-test test unit` | Run `daemon-substrate-unit` test suite | no | yes |
| `daemon-substrate-test test integration` | Run `daemon-substrate-integration` test suite | no | yes (requires running cluster) |
| `daemon-substrate-test test lint` | Run lint suite (ormolu, hlint, doc, proto) | no | yes |
| `daemon-substrate-test test all` | Run lint + unit + integration in order | no | yes |
| `daemon-substrate-test service --role worker --config <path>` | Run the worker daemon | **yes** | n/a |
| `daemon-substrate-test service --role orchestrator --config <path>` | Run the orchestrator daemon | **yes** | n/a |

## Detail

### `cluster up`

Reconciles the kind cluster to the supported topology described in
[../engineering/cluster_topology.md](../engineering/cluster_topology.md). Steps in order:
kind create, manual StorageClass, Helm dependency build, Harbor bootstrap, Pulsar bootstrap,
MinIO bootstrap + seed, ConfigMap render, orchestrator Deployment, worker Deployment (Linux
CPU cohort), edge-port discovery.

Safe to re-run after any partial failure; resumes at the first phase that is not yet `Ready`.

### `cluster down`

Reconciles cluster absence. Preserves `./.data/`, `./.build/`, the project container image
(Linux), and host prerequisites. Removing those is outside lifecycle teardown.

### `cluster status`

Read-only. Reports:

- `lifecyclePhase` (one of `Bootstrap`, `AcquireClients`, `ProbeClients`, `Ready`, `Draining`,
  `Exit`)
- `lifecycleDetail`
- `lifecycleHeartbeatAt`
- node readiness
- in-cluster workload readiness (Harbor, Pulsar, MinIO, orchestrator, worker)
- the chosen edge port

Does not mutate Kubernetes resources, repo-local state, or the edge-port record.

### `test unit`

Invokes `cabal test daemon-substrate-unit`. Pure Haskell tests; no cluster required.

### `test integration`

Preflight: verifies the cluster is `Ready`; fails fast if not. Then invokes
`cabal test daemon-substrate-integration`. Asserts the surface described in
[../development/testing_strategy.md § test integration](../development/testing_strategy.md).

### `test lint`

Runs ormolu, hlint, doc validator (when implemented), proto validator.

### `test all`

Runs `test lint`, `test unit`, `test integration` in order. Stops at the first failure.

### `service`

The only long-running daemon entrypoint. Required flags:

- `--role worker` or `--role orchestrator`
- `--config <path-to-dhall>`

The role selects which base loop runs (`Daemon.Worker.runWorker` or
`Daemon.Orchestrator.runOrchestrator`). The Dhall file is decoded into `BootConfig role app`;
the daemon then proceeds through its lifecycle phases.

## Substrate-file independence

The lint and docs validators are substrate-file independent. The cluster, test, and `service`
commands read the active substrate from the staged Dhall configuration via binary-owned
preflight; they fail fast with a substrate-specific diagnostic if it cannot be materialized
or validated.

There is no `--substrate` or `DAEMON_SUBSTRATE_*` flag on any command. Substrate selection
happens at the Dhall layer, not at the CLI layer. The cohort (`apple-silicon` vs
`linux-cpu`) is implicit in which Dhall file is staged.

## What is not a supported command

- A `daemon-substrate` binary. The library is consumed by name; it does not produce a
  general-purpose CLI.
- `daemon-substrate-test e2e`. Reserved for future use; not currently implemented.
- `daemon-substrate-test docs check`, `lint files`, etc. as separate top-level commands. They
  are subcommands of `test lint` for now; revisit if the harness grows.

## Outer entry: hostbootstrap

`daemon-substrate-test` is the *inner* CLI; the *outer* entry is
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap). The relevant outer commands:

| Command | Purpose |
|---------|---------|
| `hostbootstrap doctor` | Detect substrate; idempotently install host prereqs |
| `hostbootstrap cluster up` | Build artifact (binary on Apple, container on Linux); launch per the model declared in `hostbootstrap.dhall` |
| `hostbootstrap cluster down` | Tear down (preserves `./.data/`) |
| `hostbootstrap cluster delete` | Thorough teardown (still preserves `./.data/`) |
| `hostbootstrap cluster status` | Report status (delegates inward to `daemon-substrate-test cluster status`) |
| `hostbootstrap run <cmd...>` | Dispatch into the project container (Linux) or run the host binary directly (Apple) |

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the boundary between outer and inner commands.

## Cross-references

- Cabal stanzas that produce the binary: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- What each `test` command actually asserts: [../development/testing_strategy.md](../development/testing_strategy.md)
- What `cluster up` deploys: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Outer entry contract: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Operator-facing workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
