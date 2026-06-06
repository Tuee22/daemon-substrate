# CLI Surface (`daemon-substrate-test`)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../engineering/dhall_generation.md](../engineering/dhall_generation.md), [../engineering/test_isolation.md](../engineering/test_isolation.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)

> **Purpose**: Authoritative inventory of the `daemon-substrate-test` executable's command
> surface — the `hostbootstrap-core` command tree it extends, the project verbs it adds, and
> which commands are idempotent reconcilers vs. long-running daemons.

## TL;DR

- `daemon-substrate-test` is the only binary the substrate produces, and it exists only for the
  test harness. It **extends `hostbootstrap-core`** via optparse-applicative
  (`runHostBootstrapCLI "daemon-substrate-test" projectCommands`). See
  [../engineering/cabal_layout.md](../engineering/cabal_layout.md).
- The binary inherits the **core verbs** — `ensure <tool>`, `cluster`, `config` — and adds the
  **project verbs** `service`, `test`, and `check-code`.
- `service` is the only long-running entrypoint. Every other command is an idempotent reconciler
  and is safe to re-run.
- `config schema` and `config render` are project verbs: the binary emits its own Dhall schema
  and renders the rich project / per-case test Dhall. See
  [../engineering/dhall_generation.md](../engineering/dhall_generation.md).
- The outer operator entry is the thin Python bootstrapper (`hostbootstrap cluster up`), which
  reads the skeletal `hostbootstrap.dhall`, builds the binary, copies it to `./.build/`, and
  execs it. See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

## Current Status

The target architecture above is the shape this document describes. Implementation status — the
optparse migration onto `hostbootstrap-core`, `config schema` / `config render`, and the
`ClusterProfile`-driven nine-cluster `test integration` runner — is tracked in
[`../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md`](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md),
[`../../DEVELOPMENT_PLAN/phase-8-test-harness-integration.md`](../../DEVELOPMENT_PLAN/phase-8-test-harness-integration.md),
and the `hostbootstrap-core`-integration phase. The hand-rolled CLI parser and the
`--force-target` / readiness-only integration surfaces are queued for removal in
[`../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## Command tree

The binary is one optparse-applicative tree. Core verbs come from `hostbootstrap-core`; project
verbs are added by `daemon-substrate-test`.

### Core verbs (from `hostbootstrap-core`)

| Command | Purpose | Long-running? | Idempotent? |
|---------|---------|---------------|-------------|
| `daemon-substrate-test ensure <tool>` | Reconcile a host tool (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`); fail-fast on the wrong host | no | yes |
| `daemon-substrate-test cluster up` | Bring up the kind cluster + harness workloads for the active `ClusterProfile` | optional | yes |
| `daemon-substrate-test cluster down` | Tear down the cluster for the active profile | no | yes |
| `daemon-substrate-test cluster delete` | Thorough teardown for the active profile | no | yes |
| `daemon-substrate-test cluster status` | Report kind/node status (read-only) | no | yes |
| `daemon-substrate-test config schema` | Emit the binary's own Dhall schema | no | yes |
| `daemon-substrate-test config render` | Render the rich project-tier Dhall config | no | yes |

### Project verbs (added by `daemon-substrate-test`)

| Command | Purpose | Long-running? | Idempotent? |
|---------|---------|---------------|-------------|
| `daemon-substrate-test test unit` | Run `daemon-substrate-unit` test suite | no | yes |
| `daemon-substrate-test test lifecycle` | Run `daemon-substrate-lifecycle` test suite | no | yes |
| `daemon-substrate-test test integration` | Run the nine-case model × workflow matrix; owns per-case create/upload/teardown | no | yes |
| `daemon-substrate-test test lint` | Run the local style suite | no | yes |
| `daemon-substrate-test test all` | Run lint + unit + lifecycle + integration in order | no | yes |
| `daemon-substrate-test check-code` | Run the Dockerfile build-gate style check | no | yes |
| `daemon-substrate-test service --role worker --config <path>` | Run the worker daemon | **yes** | n/a |
| `daemon-substrate-test service --role orchestrator --config <path>` | Run the orchestrator daemon | **yes** | n/a |

## ClusterProfile and test-scope selection

The `cluster ...` verbs operate on the active `ClusterProfile`:

| Profile | Cluster name | Data root | Selected by |
|---------|--------------|-----------|-------------|
| `ProductionProfile` | `daemon-substrate-<cohort>` | `./.data` | operator `cluster up/down` for a cohort |
| `TestProfile` | `dst-test-<model>-<archetype>` | `./.test_data/<case>` | the `test integration` runner, per case |

The execution model (`container` / `host-binary` / `host-daemon`) and the test case select the
generated per-case Dhall and the worker placement. Teardown is guarded: only `dst-test-`-prefixed
clusters can be deleted by the test path. See
[../engineering/test_isolation.md](../engineering/test_isolation.md).

## Detail

### `cluster up`

Reconciles the kind cluster to the topology in
[../engineering/cluster_topology.md](../engineering/cluster_topology.md): kind create, manual
StorageClass and PVs, Harbor deployment and harness image upload, Helm dependency build and
release upgrade, dependency readiness waits, Pulsar bootstrap, MinIO bootstrap + seed, ConfigMap
render from the generated project Dhall, coordinator/orchestrator Deployment, worker placement
for the selected execution model, and edge-port discovery. Names and host paths come from the
active `ClusterProfile`. Safe to re-run after any partial failure; an already-existing cluster is
reported as a successful no-change action.

### `cluster down` / `cluster delete`

Reconcile cluster absence. `ProductionProfile` preserves `./.data/`; `TestProfile` reconciles
away the case's `./.test_data/<case>/` workspace only. Both preserve `./.build/` and host
prerequisites. The test path refuses any name not prefixed `dst-test-`.

### `cluster status`

Read-only. Reports node readiness and known kind clusters for the active profile. Does not mutate
Kubernetes resources, repo-local state, or the edge-port record.

### `config schema`

Emits the Dhall type the binary's own decoders accept. The schema is owned by the binary because
the binary owns the decoders, so it cannot drift from the Haskell types. See
[../engineering/dhall_generation.md](../engineering/dhall_generation.md).

### `config render`

Materializes a concrete project-tier Dhall config from the binary's defaults plus the skeletal
`hostbootstrap.dhall` inputs (`project`, `resources`). Idempotent: re-rendering with the same
inputs is byte-identical. The integration runner uses the same generator to emit per-case test
Dhall.

### `ensure <tool>`

Reconciles a single host tool through the `hostbootstrap-core` reconciler set. Each reconciler is
idempotent and fails fast on the wrong host (for example `ensure tart` on Linux, or `ensure cuda`
without an NVIDIA runtime).

### `test integration`

Invokes the `daemon-substrate-integration` runner. It generates per-case test Dhall, recursively
invokes `hostbootstrap` to bring up each `dst-test-*` cluster, deploys Harbor / Pulsar / MinIO,
uploads the already-built harness image through Harbor, deploys two coordinator/orchestrator
replicas plus exactly one worker, runs the workflow assertions, and tears the cluster down in a
guaranteed `finally`. Production `.data` and any production cluster are never touched.

### `test lint` / `check-code`

`test lint` runs `daemon-substrate-haskell-style`: the documentation metadata/link/phase-structure
validator and the direct `Daemon.Proto.*` import boundary. `check-code` runs the same local gate
and is invoked from the project Dockerfile so stale docs or invalid proto imports fail before the
image is produced.

### `test all`

Runs `test lint`, `test unit`, `test lifecycle`, and `test integration` in order, stopping at the
first failure. Because `test integration` owns cluster lifecycle, `test all` does not require a
preexisting kind cluster.

### `service`

The only long-running daemon entrypoint. Required flags `--role worker|orchestrator` and
`--config <path-to-dhall>`. The role selects the base loop (`Daemon.Worker.runWorker` or
`Daemon.Orchestrator.runOrchestrator`); the generated Dhall file is decoded into
`BootConfig role app`, and the daemon proceeds through its lifecycle phases.

## Configuration-file independence

The lint and docs validators are configuration-file independent. The cluster, test, and `service`
commands read their settings from the **generated** Dhall configuration via binary-owned
preflight; they fail fast with a diagnostic if it cannot be materialized or validated. There is
no `--substrate` or `--accel` flag. Host selection and the resource budget come from the skeletal
`hostbootstrap.dhall` at the Python-bootstrapper layer.

## What is not a supported command

- A `daemon-substrate` binary. The library is consumed by name; it does not produce a
  general-purpose CLI.
- `daemon-substrate-test e2e`. Reserved for future use; not currently implemented.
- `--force-target`. The old per-host force override is removed; the host is detected and the
  budget is read from the skeletal Dhall.
- A hand-rolled argument parser. The tree is `hostbootstrap-core`'s optparse-applicative tree
  extended with project verbs.

## Outer entry: the Python bootstrapper

`daemon-substrate-test` is the binary that does the inner work; the outer entry is the thin Python
bootstrapper shipped by [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap). It reaches a
fail-fast host minimum, ensures Docker (a per-project Colima VM on Apple), builds the project
container with the `check-code` gate, copies the binary to `./.build/`, and execs it with the
requested verb. `hostbootstrap cluster up/down/delete` therefore resolve to the same binary's
`cluster` verbs after the build/copy step.

See [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
for the boundary between the Python bootstrapper, `hostbootstrap-core`, and this binary.

## Cross-references

- Cabal stanzas that produce the binary: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- What each `test` command actually asserts: [../development/testing_strategy.md](../development/testing_strategy.md)
- What `cluster up` deploys: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Binary-generated Dhall: [../engineering/dhall_generation.md](../engineering/dhall_generation.md)
- Test isolation invariants: [../engineering/test_isolation.md](../engineering/test_isolation.md)
- Outer entry contract: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Operator-facing workflow: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
