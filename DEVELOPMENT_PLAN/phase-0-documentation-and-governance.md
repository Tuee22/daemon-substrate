# Phase 0: Documentation and Governance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Establish documentation and plan governance — the standards docs, the
> metadata-bearing root documents, the `documents/` and `DEVELOPMENT_PLAN/` trees the rest of
> the plan references.

## Phase Status

**Status**: Active
**Implementation**: documentation only
**Remaining work**: doc validator implementation (deferred to a later phase); progressive
filling-in of placeholder sprint detail as the relevant later phases open.

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

### Sprint 0.3: Documents tree population [Active]

**Status**: Active
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

Detail-level revisions land as later phases tighten the implementation (e.g.
`engineering/cabal_layout.md` is provisional until the cabal file itself exists in Phase 1).

### Sprint 0.4: Development plan tree population [Active]

**Status**: Active
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
- `phase-2-typeclasses-pulsar-minio-engine.md`
- `phase-3-daemon-lifecycle-and-config.md`
- `phase-4-worker-and-orchestrator-base-loops.md`
- `phase-5-kind-cluster-and-helm-chart.md`
- `phase-6-bootstrap-and-outer-container.md`
- `phase-7-test-harness-integration.md`

#### Validation

Every phase file carries `Status`, `Phase Status`, `Phase Objective`, `Sprints`, and
`Documentation Requirements` sections per Standards G and H.

#### Remaining Work

Per-sprint detail inside each phase file fills out as that phase opens.

### Sprint 0.5: Doc validator [Deferred — owned by Phase 7 Sprint 7.4]

**Status**: Deferred
**Blocked by**: Phase 7 Sprint 7.4 (the validator implementation lands as part of the
test-lint gate; Phase 0 closure does not depend on it)
**Docs to update**: `documents/documentation_standards.md` (Validation section), this file

#### Objective

The doc validator is forward-referenced from
`documents/documentation_standards.md § Validation` and from the `Documentation Requirements`
sections of later phase files. Its implementation lives in
[`phase-7-test-harness-integration.md` Sprint 7.4](phase-7-test-harness-integration.md);
see that sprint for deliverables, validation, and remaining-work tracking.

This sprint exists only to document the obligation; it does not own the implementation.
Phase 0 can close (Status: `Done`) once Sprints 0.1 – 0.4 close, even if Sprint 0.5 is
still `Deferred`. When Sprint 7.4 lands the validator, the `documents/documentation_standards.md`
Validation section transitions from forward-looking to current-state declarative as a side
effect, and this sprint's status becomes `Done` via reference to that closure.

## Documentation Requirements

**Engineering docs to create/update:**
- This phase produces the docs themselves; the requirement is met by Sprints 0.3 and 0.4.

**Reference docs to create/update:**
- `documents/reference/cli_surface.md` (provisional; real CLI lands in Phase 7)
- `documents/reference/proto_surface.md` (provisional; real protos land in Phase 2)

**Cross-references to add:**
- `README.md` points at `documents/README.md` and `DEVELOPMENT_PLAN/README.md`
- `AGENTS.md` and `CLAUDE.md` point at `documents/development/assistant_workflow.md`
