# Phase 8: Test Harness Integration

**Status**: Authoritative source
**Supersedes**: `phase-7-test-harness-integration.md` (renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the `daemon-substrate-test` executable, the four cabal test stanzas, and
> the integration coverage that proves every shared workflow either consumer needs works on
> a real kind cluster, on both cohorts, with the mock engine.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 7
**Implementation**: none yet

## Phase Objective

Make the test harness real. The substrate's tests are the only *direct* validation that
everything between Pulsar / MinIO and the engine boundary works end-to-end. After Phase 8
closes, `daemon-substrate-test test all` on either cohort asserts every row in the workflow
coverage table in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md).

## Sprints

### Sprint 8.1: `daemon-substrate-test` executable [Planned]

**Status**: Planned
**Docs to update**: `../documents/reference/cli_surface.md`, `system-components.md`

#### Objective

Land `app/test/Main.hs` implementing the command surface described in
[`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md):
`cluster {up,down,status}`, `test {unit,lifecycle,integration,lint,all}`, `service --role <r>
--config <path>`.

#### Deliverables

- `app/test/Main.hs` with the option parser (using `Daemon.Lifecycle.runService`)
- delegate functions under `src/Daemon/Test/CLI/*`
- subcommand smoke tests in `daemon-substrate-unit`

#### Validation

`./.build/daemon-substrate-test --help` (Apple) and `hostbootstrap run daemon-substrate-test
--help` (Linux) both succeed and list every documented subcommand.

### Sprint 8.2: `daemon-substrate-unit` stanza [Planned]

**Status**: Planned
**Blocked by**: 8.1
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Finalize the `daemon-substrate-unit` stanza. Most unit coverage was authored alongside each
typeclass / base loop in Phases 2–5; this sprint consolidates the test-suite wiring and adds
any cross-module pure tests not naturally covered earlier.

#### Deliverables

- `test/unit/Spec.hs` with hspec / tasty driver
- helpers under `test/unit/Daemon/Test/Unit/*`
- coverage of every row in the testing strategy table marked "no cluster needed"

#### Validation

`cabal test daemon-substrate-unit` exits 0 in seconds on both cohorts.

### Sprint 8.3: `daemon-substrate-lifecycle` stanza [Planned]

**Status**: Planned
**Blocked by**: 8.1
**Docs to update**: `../documents/development/testing_strategy.md`, `system-components.md`

#### Objective

Land the lifecycle test suite: daemon spawned as a real process; SIGHUP / SIGTERM exercised;
`/readyz` polled; LiveConfig reload validated. No kind cluster needed.

#### Deliverables

- `test/lifecycle/Spec.hs`
- helpers under `test/lifecycle/Daemon/Test/Lifecycle/*` for process spawning + signal sending
- `daemon-substrate-test test lifecycle` preflights nothing and delegates to
  `cabal test daemon-substrate-lifecycle`

#### Validation

`cabal test daemon-substrate-lifecycle` exits 0 on both cohorts; SIGHUP reload visible in
test output; SIGTERM drain completes within `LiveConfig.drainDeadlineSeconds`.

### Sprint 8.4: `daemon-substrate-integration` stanza [Planned]

**Status**: Planned
**Blocked by**: 8.1
**Docs to update**: `../documents/development/testing_strategy.md`, `system-components.md`

#### Objective

Land the integration suite covering every row in the testing-strategy table from "Worker
consumes a `MockBatch`" through "Audit topic replay" — all 30 cluster-requiring rows.

#### Deliverables

- `test/integration/Spec.hs` with hspec-driven assertions
- helpers under `test/integration/Daemon/Test/Integration/*` for cluster preflight, fixture
  request injection, result-topic consumption, lifecycle-policy fixtures (one for each of
  `Ephemeral`, `ContinuousWithArchive`, `FiniteSession`, `OnlineLearning`)
- `daemon-substrate-test test integration` preflights cluster readiness and delegates to
  `cabal test daemon-substrate-integration`
- the cluster is brought up via `hostbootstrap cluster up` (delegating inward to
  `daemon-substrate-test cluster up`)

#### Validation

`hostbootstrap cluster up` → `daemon-substrate-test test integration` exits 0 on both
cohorts. Test output names which cohort it exercised. The integration suite covers:

- worker / orchestrator fan-in / fan-out / result bridge
- MinIO `Store` (blobs / manifests / pointers / CAS) cold + warm + eviction
- worker pod replacement (Linux); MinIO StatefulSet replacement
- reconciler creates declared topics + buckets; idempotent on re-run
- leader election (two orchestrator replicas, only one ticks); leader failover with audit
  replay
- per-`TopicLifecycle`-mode: `Ephemeral`, `ContinuousWithArchive`, `FiniteSession` (including
  session-end → terminate-and-export and session-resume → topic re-open),
  `OnlineLearning`
- MinIO orphan scan: safety window honored, unreachable + past-window objects hard-deleted

### Sprint 8.5: `daemon-substrate-haskell-style` stanza (lint + doc validator) [Planned]

**Status**: Planned
**Blocked by**: 8.1
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/development/local_dev.md`, `../documents/documentation_standards.md`
(Validation section transitions from forward-looking to current-state),
`phase-0-documentation-and-governance.md` (Sprint 0.5 closes via reference)

#### Objective

Land `daemon-substrate-test test lint`. The sprint owns three gates:

1. `ormolu` formatting check against `src/` and `test/`
2. `hlint` against `src/` and `test/`
3. **Doc validator** implementing the checks named in
   `documents/documentation_standards.md § Validation` (required metadata block, relative-link
   resolution, root-doc metadata, `## Documentation Requirements` retention on phase files,
   root `README.md` reference to both `documents/` and `DEVELOPMENT_PLAN/`)

The doc validator is the deferred Phase 0 Sprint 0.5 obligation. Landing it here closes both
sprints simultaneously.

#### Deliverables

- format / lint orchestration under `src/Daemon/Test/Lint/*`
- `daemon-substrate-haskell-style` cabal stanza wired up
- `src/Daemon/Test/Lint/Docs.hs` implementing the doc-validator checks
- `documents/documentation_standards.md § Validation` rewritten from forward-looking to
  current-state declarative

#### Validation

- `daemon-substrate-test test lint` exits 0 on a clean repo
- exits non-zero on a deliberately mis-formatted fixture
- exits non-zero on a doc with a missing `**Status**:` line
- exits non-zero on a doc with a broken relative link
- exits non-zero on a phase file missing its `## Documentation Requirements` section

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/cabal_layout.md` updates with the four-stanza shape.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` updates from "planned" to current-state declarative.

**Development docs to create/update:**
- `../documents/development/testing_strategy.md` updates every coverage row from
  forward-looking to current-state declarative.

**Cross-references to add:**
- `system-components.md` flips `daemon-substrate-test`, `daemon-substrate-unit`,
  `daemon-substrate-lifecycle`, `daemon-substrate-integration`, and
  `daemon-substrate-haskell-style` rows to `Implemented: yes`. Phase 8 closure is the closing
  milestone for the substrate-library buildout.
