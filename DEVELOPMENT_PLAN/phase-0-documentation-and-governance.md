# Phase 0: Documentation and Governance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Establish documentation and plan governance — the standards docs, the
> metadata-bearing root documents, the `documents/` and `DEVELOPMENT_PLAN/` trees the rest of
> the plan references.

## Phase Status

**Status**: Done
**Implementation**: documentation only
**Remaining work**: none. Sprint 0.5 remains intentionally deferred to Phase 8 Sprint 8.5 and
does not block Phase 0 closure.

## Phase Objective

Make every other phase possible. By the time Phase 0 closes, the repository must carry:

- governance standards (`documents/documentation_standards.md`,
  `DEVELOPMENT_PLAN/development_plan_standards.md`)
- governed root documents with metadata blocks (`README.md`, `AGENTS.md`, `CLAUDE.md`)
- a populated `documents/` tree describing the substrate's intended architecture, engineering,
  development, operations, and reference surface
- a populated `DEVELOPMENT_PLAN/` tree with the phase list, overview, component inventory, and
  cleanup ledger
- a doc validator (eventually) that mechanically enforces the metadata and link rules the
  standards require

The phase does not produce any Haskell, chart, or bootstrap code; that work belongs to later
phases.

## Sprints

### Sprint 0.1: Governance standards documents [Done]

**Status**: Done
**Implementation**: `documents/documentation_standards.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`
**Docs to update**: `documents/documentation_standards.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Land the two standards documents that govern the rest of the repository's documentation and
plan content.

#### Deliverables

- `documents/documentation_standards.md` with metadata block, taxonomy, source-of-truth rule,
  naming and linking, content rules, update rules, and forward-referenced validation section
- `DEVELOPMENT_PLAN/development_plan_standards.md` with sections A through Q

#### Validation

Both files exist and carry the metadata fields they require of other files. Cross-references
between the two resolve.

#### Remaining Work

(none)

### Sprint 0.2: Root document metadata retrofit [Done]

**Status**: Done
**Implementation**: `README.md`, `AGENTS.md`, `CLAUDE.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`

#### Objective

Retrofit the three root documents to carry the metadata blocks Section "Governed Root
Documents" of `documents/documentation_standards.md` requires.

#### Deliverables

- `README.md` with `Status: Governed orientation document`, `Supersedes`, `Canonical homes`,
  purpose blockquote
- `AGENTS.md` with `Status: Governed entry document`, `Supersedes`, `Canonical homes`,
  purpose blockquote
- `CLAUDE.md` with same shape as AGENTS.md

#### Validation

Each file passes the standards' header rules on visual inspection. (Mechanical validation
deferred to Sprint 0.5.)

#### Remaining Work

(none)

### Sprint 0.3: Documents tree population [Done]

**Status**: Done
**Implementation**: `documents/README.md`, `documents/architecture/`, `documents/engineering/`,
`documents/development/`, `documents/operations/`, `documents/reference/`
**Docs to update**: same paths

#### Objective

Populate the `documents/` tree so every architectural, engineering, and operational topic
referenced by later phases has a canonical home.

#### Deliverables

- `documents/README.md` (index)
- `documents/architecture/daemon_roles.md`
- `documents/architecture/pulsar_minio_ssot.md`
- `documents/architecture/library_consumption_model.md`
- `documents/engineering/cabal_layout.md`
- `documents/engineering/pulsar_topics.md`
- `documents/engineering/minio_buckets.md`
- `documents/engineering/cluster_topology.md`
- `documents/engineering/mock_engine.md`
- `documents/engineering/hostbootstrap_integration.md`
- `documents/development/assistant_workflow.md`
- `documents/development/local_dev.md`
- `documents/development/testing_strategy.md`
- `documents/operations/cluster_bootstrap_runbook.md`
- `documents/operations/apple_silicon_runbook.md`
- `documents/operations/linux_cpu_runbook.md`
- `documents/reference/cli_surface.md`
- `documents/reference/proto_surface.md`

#### Validation

Every file carries the required metadata block. Every cross-reference resolves to an existing
file in this sprint or is explicitly forward-referenced to a later phase.

#### Remaining Work

(none)

### Sprint 0.4: Development plan tree population [Done]

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
the eight phase files
**Docs to update**: same paths

#### Objective

Populate the `DEVELOPMENT_PLAN/` tree so the phase plan is browsable end-to-end before any
code lands.

#### Deliverables

- `DEVELOPMENT_PLAN/README.md`
- `DEVELOPMENT_PLAN/00-overview.md`
- `DEVELOPMENT_PLAN/system-components.md`
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
- `phase-0-documentation-and-governance.md` (this file)
- `phase-1-library-scaffolding-and-cabal-package.md`
- `phase-2-capability-typeclasses-and-admin-surfaces.md`
- `phase-3-bootconfig-liveconfig-lifecycle.md`
- `phase-4-engine-mock-protos-audit.md`
- `phase-5-base-loops.md`
- `phase-6-cluster-bringup-tree.md`
- `phase-7-hostbootstrap-and-project-dockerfile.md`
- `phase-8-test-harness-integration.md`

#### Validation

Every phase file carries `Status`, `Phase Status`, `Phase Objective`, `Sprints`, and
`Documentation Requirements` sections per Standards G and H.

#### Remaining Work

(none)

### Sprint 0.5: Doc validator [Deferred — owned by Phase 8 Sprint 8.5]

**Status**: Deferred
**Blocked by**: Phase 8 Sprint 8.5 (the validator implementation lands as part of the
test-lint gate; Phase 0 closure does not depend on it)
**Docs to update**: `documents/documentation_standards.md` (Validation section), this file

#### Objective

The doc validator is forward-referenced from
`documents/documentation_standards.md § Validation` and from the `Documentation Requirements`
sections of later phase files. Its implementation lives in
[`phase-8-test-harness-integration.md` Sprint 8.5](phase-8-test-harness-integration.md);
see that sprint for deliverables, validation, and remaining-work tracking.

This sprint exists only to document the obligation; it does not own the implementation.
Phase 0 can close (Status: `Done`) once Sprints 0.1 – 0.4 and 0.6 close, even if Sprint 0.5
is still `Deferred`. When Sprint 8.5 lands the validator, the
`documents/documentation_standards.md` Validation section transitions from forward-looking to
current-state declarative as a side effect, and this sprint's status becomes `Done` via
reference to that closure.

**Closure coupling**: the change set that flips Sprint 8.5 to `Done` must in the same change
set flip this sprint (0.5) to `Done` and update Phase 0's overall status accordingly. Do not
merge the Phase 8 Sprint 8.5 change set without including the Phase 0 status updates.

### Sprint 0.6: hostbootstrap re-baseline [Done]

**Status**: Done
**Implementation**: `documents/engineering/hostbootstrap_integration.md`, root docs,
`documents/` runbooks and standards, `DEVELOPMENT_PLAN/` overview / standards /
system-components, phases 1 / 5 / 6 / 7, `legacy-tracking-for-deletion.md`
**Docs to update**: see Implementation list

#### Objective

Re-baseline `documents/` and `DEVELOPMENT_PLAN/` onto
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) as the canonical infrastructure
layer. The Haskell-runtime architecture (Pulsar / MinIO / daemon roles / typeclass surface /
lifecycle / mock engine) is untouched; the re-baseline is about the build / lifecycle /
bootstrap layer only.

#### Deliverables

- `documents/engineering/hostbootstrap_integration.md` lands as the canonical home for the
  integration shape, the model-per-substrate mapping, and the ownership boundary
- root `README.md`, `CLAUDE.md`, `AGENTS.md` reference `hostbootstrap` as the foundation
- `documents/documentation_standards.md` and
  `DEVELOPMENT_PLAN/development_plan_standards.md` carry cross-references to `hostbootstrap`'s
  own standards (without absorbing them)
- `documents/development/local_dev.md`, both operations runbooks, and
  `documents/operations/cluster_bootstrap_runbook.md` describe the
  `hostbootstrap doctor` → `hostbootstrap cluster up` flow
- `documents/engineering/cabal_layout.md`, `cluster_topology.md`, and
  `documents/reference/cli_surface.md` reflect the new GHC 9.12 pin and the outer / inner CLI
  split
- `DEVELOPMENT_PLAN/system-components.md` lists `hostbootstrap.dhall`, the base image, and
  the model-per-substrate mapping; previously planned `bootstrap/*.sh` and `compose.yaml`
  rows are removed
- Phase 1 GHC pin updated to 9.12; Phase 6 sprints rewritten; Phases 5 and 7 lightly retouched
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` records the planned-but-now-dropped
  surfaces (`bootstrap/apple-silicon.sh`, `bootstrap/linux-cpu.sh`, `compose.yaml`,
  `daemon-substrate-linux-cpu:local` launcher image)

#### Validation

- Cross-reference walk from `README.md` → `CLAUDE.md` →
  `documents/development/local_dev.md` →
  `documents/engineering/hostbootstrap_integration.md` → both runbooks reads end-to-end with
  no dangling references to `bootstrap/*.sh`, `compose.yaml`, the launcher image, or GHC
  9.14.1.
- `documents/operations/cluster_bootstrap_runbook.md` carries an explicit ownership boundary
  paragraph delineating `hostbootstrap` (outer) from `daemon-substrate-test` (inner)
  responsibilities.
- Phase status table in `DEVELOPMENT_PLAN/README.md` reflects the re-baseline: Phase 0
  documentation obligations include the hostbootstrap integration doc; Phase 6 sprints
  rewritten; Phase 1 GHC pin reads 9.12.

#### Remaining Work

(none)

## Documentation Requirements

**Engineering docs to create/update:**
- This phase produces the docs themselves; the requirement is met by Sprints 0.3 and 0.4.

**Reference docs to create/update:**
- `documents/reference/cli_surface.md` (provisional; real CLI lands in Phase 7)
- `documents/reference/proto_surface.md` (provisional; real protos land in Phase 2)

**Cross-references to add:**
- `README.md` points at `documents/README.md` and `DEVELOPMENT_PLAN/README.md`
- `AGENTS.md` and `CLAUDE.md` point at `documents/development/assistant_workflow.md`
