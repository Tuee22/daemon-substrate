# Phase 9: hostbootstrap-core Integration and Host-Driven 3x3

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-cluster-bringup-tree.md](phase-6-cluster-bringup-tree.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md), [phase-8-test-harness-integration.md](phase-8-test-harness-integration.md)

> **Purpose**: Invert `daemon-substrate` onto the `hostbootstrap-core` Haskell library. The
> project ships one optparse-applicative binary that extends the core command tree, generates
> its own three-tier Dhall, drives a `ClusterProfile`-isolated executable 3x3 harness under
> `.test_data/`, and invokes `hostbootstrap` recursively per case.

## Phase Status

**Status**: Blocked
**Blocked by**: the `hostbootstrap` repository's `hostbootstrap-core` phases (core scaffolding,
host-tools-and-config, `ensure` reconcilers, skeletal-Dhall-and-command-tree, and
cluster-lifecycle-and-resource-cordoning), and [phase-8-test-harness-integration.md](phase-8-test-harness-integration.md)
Sprint 8.8.

This phase encodes the target architecture: `hostbootstrap` is no longer a pure-Python CLI but a
Haskell `hostbootstrap-core` library plus a thin Python bootstrapper. `daemon-substrate`'s
test-harness binary stops hand-rolling its own command parser, substrate model, and cluster-name
derivation and instead extends `hostbootstrap-core`. None of the sprints below are started; they
remain `Blocked` until the upstream core phases publish a consumable
`source-repository-package` and Phase 8 Sprint 8.8 lands the in-repo runner skeleton they
rewire.

### Remaining Work

All sprints (9.1–9.5) are unstarted. Each lists its own blocking prerequisite. The phase cannot
move past `Blocked` until `hostbootstrap-core` is published and pinned.

## Phase Objective

Consume `hostbootstrap-core` as a pinned `source-repository-package` git dependency and rebuild
the test harness around it:

- replace the custom recursive-descent CLI parser with an optparse-applicative tree that extends
  `hostbootstrap-core` via `runHostBootstrapCLI progName projectCommands`;
- collapse `hostbootstrap.dhall` to the skeletal `project` + `dockerfile` +
  `resources {cpu, memory, storage}` shape and generate the rich project-level and per-case test
  Dhall from the binary (which also emits its own schema);
- introduce `ClusterProfile` (production `.data/` + fixed name vs test `.test_data/<case>/` +
  `dst-test-<model>-<archetype>`) with one centralized cluster-name / `hostPath` derivation;
- make `test integration` an executable per-case 3x3 runner with archetype assertions, guaranteed
  `finally` teardown, a `dst-test-` delete-guard, and a recursive `hostbootstrap` invocation per
  case that never touches the production `.data/cluster`.

The library under `src/Daemon/*` stays substrate-agnostic; all of the substrate-aware seam lives
in the renamed project binary and the new `Daemon.Test.Integration.*` modules.

## Sprints

### Sprint 9.1: hostbootstrap-core consumption + optparse migration [Blocked]

**Status**: Blocked
**Blocked by**: `hostbootstrap` `phase-1-hostbootstrap-core-scaffolding` and
`phase-4-skeletal-dhall-and-command-tree` (publishing the `hostbootstrap-core` library and the
`runHostBootstrapCLI` command-tree extension point)
**Implementation**: `cabal.project`, `daemon-substrate.cabal`, `app/test/Main.hs`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI.hs`
**Docs to update**: `../documents/engineering/cabal_layout.md`,
`../documents/reference/cli_surface.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Pin `hostbootstrap-core` as a `source-repository-package` git dependency and migrate the project
binary's command surface from the hand-written recursive-descent parser in
`src/Daemon/Test/CLI/Types.hs` to an optparse-applicative tree that extends the
`hostbootstrap-core` command tree. The binary is renamed from `daemon-substrate-test` to the
project binary name that `hostbootstrap-core` builds and execs.

#### Deliverables

- `cabal.project` gains a `source-repository-package` stanza pinning `hostbootstrap-core` to an
  exact commit, plus an `optparse-applicative` dependency in `daemon-substrate.cabal`
- `app/test/Main.hs` calls `runHostBootstrapCLI progName projectCommands` instead of the custom
  dispatcher
- the project-specific subcommands (`cluster`, `test`, `service`, `config`, `check-code`) are
  defined as optparse `Parser` values
- the custom parser in `src/Daemon/Test/CLI/Types.hs` is removed and tracked as completed in the
  legacy ledger

#### Validation

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- built `<project-binary> --help` shows the core command tree with the project subcommands grafted
  in
- a static check confirms the recursive-descent parser is absent from `src/Daemon/Test/CLI/`

#### Remaining Work

Unstarted; blocked on the upstream `hostbootstrap-core` publication.

### Sprint 9.2: Three-tier + binary-generated Dhall [Blocked]

**Status**: Blocked
**Blocked by**: Sprint 9.1 and `hostbootstrap`
`phase-4-skeletal-dhall-and-command-tree`
**Implementation**: `hostbootstrap.dhall`, `src/Daemon/Test/Config/Schema.hs`,
`src/Daemon/Test/Config/Render.hs`, `app/test/Main.hs`
**Docs to update**: `../documents/engineering/hostbootstrap_integration.md`,
`../documents/engineering/dhall_generation.md`,
`../documents/reference/cli_surface.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Collapse `hostbootstrap.dhall` to the skeletal `project` + `dockerfile` +
`resources {cpu, memory, storage}` shape read by the thin Python bootstrapper, and generate the
rich project-level Dhall (worker / orchestrator roles + cluster bootstrap) and per-case test
Dhall from the binary. The binary emits its own configuration schema via `config schema` and
renders concrete config via `config render`.

#### Deliverables

- skeletal `hostbootstrap.dhall` with only `project`, `dockerfile`, and
  `resources {cpu, memory, storage}`; the `Model` / `Mounts` / `Cluster` / `NoCluster` schema is
  removed and recorded as completed in the legacy ledger
- `config schema` subcommand emits the project Dhall schema the binary itself decodes against
- `config render` subcommand writes the per-role and per-case Dhall the cluster bring-up consumes
- the chart consumes binary-generated Dhall rather than the hand-maintained `dhall/*.dhall` files

#### Validation

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- `<project-binary> config schema` round-trips through `<project-binary> config render`
- a static check confirms `hostbootstrap.dhall` declares only the skeletal fields and no
  execution-model schema

#### Remaining Work

Unstarted; blocked on Sprint 9.1.

### Sprint 9.3: ClusterProfile + .test_data isolation + centralized derivation [Blocked]

**Status**: Blocked
**Blocked by**: Sprint 9.2 and `hostbootstrap`
`phase-5-cluster-lifecycle-and-resource-cordoning`
**Implementation**: `src/Daemon/Cluster/Profile.hs`, `src/Daemon/Cluster/Runner.hs`,
`src/Daemon/Cluster/Kind.hs`, `src/Daemon/Test/Integration/Runner.hs`, `test/unit/Main.hs`
**Docs to update**: `../documents/engineering/cluster_topology.md`,
`../documents/engineering/test_isolation.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Introduce `ClusterProfile` with two constructors: `ProductionProfile` (fixed cluster name under
`.data/`) and `TestProfile <case>` (`dst-test-<model>-<archetype>` cluster name under
`.test_data/<case>/`). Centralize cluster-name and `hostPath` derivation behind one helper so the
duplicate derivations in `Daemon.Cluster.Runner` and `Daemon.Cluster.Kind` collapse to a single
source of truth.

#### Deliverables

- `Daemon.Cluster.Profile` with `ClusterProfile`, the `dst-test-` name derivation, and the
  `.test_data/<case>/` vs `.data/` `hostPath` derivation
- `Daemon.Cluster.Runner` and `Daemon.Cluster.Kind` call the centralized derivation; the
  duplicate logic is removed and recorded as completed in the legacy ledger
- a `dst-test-` delete-guard so a teardown can never delete the production cluster
- unit tests proving production and test profiles derive distinct, non-overlapping names and paths

#### Validation

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- unit assertions prove the delete-guard rejects a non-`dst-test-` cluster name in the test
  profile and that production and test paths never collide

#### Remaining Work

Unstarted; blocked on Sprint 9.2.

### Sprint 9.4: Executable per-case 3x3 runner + archetype assertions [Blocked]

**Status**: Blocked
**Blocked by**: Sprint 9.3 and [phase-8-test-harness-integration.md](phase-8-test-harness-integration.md)
Sprint 8.8
**Implementation**: `src/Daemon/Test/Integration/Runner.hs`,
`src/Daemon/Test/Integration/Assertions.hs`, `src/Daemon/Test/Matrix.hs`,
`test/integration/Main.hs`, `test/unit/Main.hs`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/engineering/test_isolation.md`, `system-components.md`

#### Objective

Make `test integration` an executable per-case 3x3 runner. `Daemon.Test.Integration.Runner`
iterates `Daemon.Test.Matrix.harnessMatrixCases`; for each case it derives the test
`ClusterProfile`, brings up a fresh cluster, deploys Harbor / Pulsar / MinIO, uploads the harness
image through Harbor, deploys the two-replica coordinator/orchestrator plus exactly one worker,
runs `Daemon.Test.Integration.Assertions` for that archetype, verifies status, and tears down —
always under a guaranteed `finally`.

#### Deliverables

- `Daemon.Test.Integration.Runner` driving nine isolated cases per invocation
- `Daemon.Test.Integration.Assertions` with archetype assertions for continuous batched
  inference, finite training / offline RL, and continuous online RL
- guaranteed `finally` teardown with the `dst-test-` delete-guard for each case
- the integration suite never reuses a live cluster, Harbor deployment, or uploaded image between
  cases and never touches `.data/cluster`
- unit tests covering case enumeration, per-case path isolation, and teardown ordering

#### Validation

- `cabal build all --enable-tests`
- `<project-binary> test unit`
- `<project-binary> test integration` on at least one development host, showing nine fresh
  `dst-test-` cluster create/assert/teardown cycles under `.test_data/`
- a fault-injected teardown leaves no `dst-test-` cluster and no `.test_data/<case>/` residue

#### Remaining Work

Unstarted; blocked on Sprint 9.3 and Phase 8 Sprint 8.8.

### Sprint 9.5: Recursive hostbootstrap test entrypoint [Blocked]

**Status**: Blocked
**Blocked by**: Sprint 9.4 and `hostbootstrap`
`phase-6-base-image-and-thin-python-bootstrapper`
**Implementation**: `src/Daemon/Test/Integration/Runner.hs`, `app/test/Main.hs`,
`hostbootstrap.dhall`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/operations/cluster_bootstrap_runbook.md`, `system-components.md`

#### Objective

Drive each matrix case through a recursive `hostbootstrap` invocation: the runner shells the
host's `hostbootstrap` (Haskell-core + thin-Python bootstrapper) per case, which provisions the
per-project Colima VM (Apple) or applies kind node cordoning (Linux) to the declared resource
budget before handing back to the project binary. `test all` runs unit through the compiled binary
and then the full nine-case matrix without a preexisting cluster.

#### Deliverables

- per-case recursive `hostbootstrap` invocation honoring the skeletal-Dhall resource budget
- Colima per-project VM (Apple) / kind cordoning (Linux) verified before each case proceeds
- `test all` runs unit + the full executable 3x3 matrix on any supported physical host

#### Validation

- `<project-binary> test all`
- `hostbootstrap run --force-target apple-silicon test integration`
- `hostbootstrap run --force-target linux-cpu test integration`
- `hostbootstrap run --force-target linux-gpu test integration`

#### Remaining Work

Unstarted; blocked on Sprint 9.4 and the upstream thin-Python bootstrapper phase.

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/hostbootstrap_integration.md` describes the `hostbootstrap-core`
  extension model, the skeletal `hostbootstrap.dhall`, and the binary-generated Dhall.
- `../documents/engineering/cabal_layout.md` records the `hostbootstrap-core`
  `source-repository-package` pin and the `optparse-applicative` dependency.
- `../documents/engineering/dhall_generation.md` (new) describes the binary-emitted schema and
  per-case config render.
- `../documents/engineering/test_isolation.md` (new) describes `ClusterProfile`, the
  `.test_data/<case>/` tree, and the `dst-test-` teardown-safety invariant.
- `../documents/engineering/cluster_topology.md` records the centralized cluster-name / `hostPath`
  derivation and the per-project Colima / kind resource budget.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` documents the renamed binary, the optparse tree
  extending `hostbootstrap-core`, and `config schema` / `config render`.

**Development docs to create/update:**
- `../documents/development/testing_strategy.md` records the executable 3x3 with `.test_data`
  isolation, generated per-case Dhall, and recursive `hostbootstrap` invocation per case.

**Cross-references to add:**
- `00-overview.md`, `system-components.md`, and `README.md` add Phase 9 and the
  `hostbootstrap-core` inversion; `legacy-tracking-for-deletion.md` records the superseded custom
  parser, substrate-model schema, fixed cluster names, readiness-only stanza, and duplicate
  derivations.
