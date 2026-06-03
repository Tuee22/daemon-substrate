# Phase 7: Test Harness Integration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-bootstrap-and-outer-container.md](phase-6-bootstrap-and-outer-container.md)

> **Purpose**: Land the `daemon-substrate-test` executable, the
> `daemon-substrate-integration` cabal test stanza, and the end-to-end coverage that proves
> the substrate works against a real kind cluster on both cohorts.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 6
**Implementation**: none yet

## Phase Objective

Make the test harness real. The substrate's integration tests are the substrate's only
*direct* validation that everything between Pulsar / MinIO and the engine boundary works
end-to-end. After Phase 7 closes, `daemon-substrate-test test integration` on either cohort
asserts every behavior listed in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md).

## Sprints

### Sprint 7.1: `daemon-substrate-test` executable [Planned]

**Status**: Planned
**Docs to update**: `documents/reference/cli_surface.md`, `system-components.md`

#### Objective

Land `app/test/Main.hs` implementing the command surface described in
[`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md):
`cluster {up,down,status}`, `test {unit,integration,lint,all}`, `service --role <r> --config
<path>`.

#### Deliverables

- `app/test/Main.hs` with the option parser
- delegate functions in `src/Daemon/Test/*` (e.g. `Daemon.Test.Cluster.runUp`,
  `Daemon.Test.Service.runService`)
- subcommand smoke tests in `daemon-substrate-unit`

#### Validation

`./.build/daemon-substrate-test --help` (Apple) and `hostbootstrap run daemon-substrate-test
--help` (Linux) both succeed and list every documented subcommand.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 7.2: Integration test stanza [Planned]

**Status**: Planned
**Blocked by**: 7.1
**Docs to update**: `documents/development/testing_strategy.md`, `documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Land `daemon-substrate-integration` covering the assertions named in the testing strategy:
cluster lifecycle, orchestrator → worker handoff, MinIO fetch, mock engine result
publication, cache cold / warm paths, dedup, failure / retry.

#### Deliverables

- `test/integration/Spec.hs` with hspec-driven assertions
- helpers under `test/integration/Daemon/Test/Integration/*` for cluster preflight, fixture
  request injection, result-topic consumption
- `daemon-substrate-test test integration` preflights cluster readiness and delegates to
  `cabal test daemon-substrate-integration`

#### Validation

Cluster brought up via `hostbootstrap cluster up` (which delegates inward to
`daemon-substrate-test cluster up`), then `daemon-substrate-test test integration` exits 0 on
both cohorts. Test output names which cohort it exercised.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 7.3: Pod-replacement and durability assertions [Planned]

**Status**: Planned
**Blocked by**: 7.2
**Docs to update**: `documents/development/testing_strategy.md`

#### Objective

Land the durability assertions: kill the worker pod and verify resumption; delete the MinIO
StatefulSet pod and verify recovery; restart Pulsar and verify topic continuity.

#### Deliverables

- integration test cases under `test/integration/Daemon/Test/Integration/Durability/*`
- documentation of which assertions are cohort-specific (e.g. worker pod-replacement only
  applies on Linux CPU; Apple worker is host-native)

#### Validation

The durability suite runs green on both cohorts (with Apple-specific cases marked skipped
where the worker pod does not exist).

#### Remaining Work

(scoped when the sprint opens)

### Sprint 7.4: Lint / format gate + doc validator [Planned]

**Status**: Planned
**Blocked by**: 7.1
**Docs to update**: `documents/development/testing_strategy.md`,
`documents/development/local_dev.md`, `documents/documentation_standards.md` (Validation
section transitions from forward-looking to current-state),
`phase-0-documentation-and-governance.md` (Sprint 0.5 closes via reference)

#### Objective

Land `daemon-substrate-test test lint`. The sprint owns three gates:

1. `ormolu` formatting check against `src/` and `test/`
2. `hlint` against `src/` and `test/`
3. **Doc validator** implementing the checks named in `documents/documentation_standards.md
   § Validation` (required-metadata block, relative-link resolution, root-doc metadata,
   `## Documentation Requirements` retention on phase files, root `README.md` reference to
   both `documents/` and `DEVELOPMENT_PLAN/`)

The doc validator is the deferred Phase 0 Sprint 0.5 obligation. Landing it here closes
both sprints simultaneously.

#### Deliverables

- format / lint orchestration under `src/Daemon/Test/Lint/*`
- `daemon-substrate-haskell-style` cabal stanza wired up
- `src/Daemon/Test/Lint/Docs.hs` implementing the doc-validator checks
- `documents/documentation_standards.md § Validation` rewritten from forward-looking to
  current-state declarative
- pre-commit-friendly format-check helper for contributors

#### Validation

- `daemon-substrate-test test lint` exits 0 on a clean repo
- Exits non-zero on a deliberately mis-formatted fixture (formatter gate)
- Exits non-zero on a doc with a missing `**Status**:` line (validator gate)
- Exits non-zero on a doc with a broken relative link (validator gate)
- Exits non-zero on a phase file missing its `## Documentation Requirements` section
  (validator gate)

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` updates with the actual integration-suite shape.

**Reference docs to create/update:**
- `documents/reference/cli_surface.md` updates from "planned" to current-state declarative.

**Development docs to create/update:**
- `documents/development/testing_strategy.md` updates the per-command assertion lists from
  forward-looking to current-state declarative as the assertions land.

**Cross-references to add:**
- `system-components.md` flips `daemon-substrate-test` and `daemon-substrate-integration` rows
  to `Implemented: yes`. Phase 7 closure is the closing milestone for the test-harness model
  as a whole.
