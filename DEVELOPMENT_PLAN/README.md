# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Phase plan orientation. Names the phases in execution order, reports the
> current status of each, and links to the standards and inventory documents.

## Foundation

The build, lifecycle, and bootstrap layer is provided by
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap); see
[`00-overview.md`](00-overview.md) and
[`../documents/engineering/hostbootstrap_integration.md`](../documents/engineering/hostbootstrap_integration.md).
The phases below focus on the Haskell library, the in-cluster reconcilers, and the
`hostbootstrap.dhall` plus thin project Dockerfile that wire the two layers together.

## Phases

| Phase | Title | Status |
|-------|-------|--------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Active |
| 1 | [Library scaffolding and cabal package](phase-1-library-scaffolding-and-cabal-package.md) | Blocked (by Phase 0) |
| 2 | [Capability typeclasses + admin surfaces](phase-2-capability-typeclasses-and-admin-surfaces.md) | Blocked (by Phase 1) |
| 3 | [BootConfig / LiveConfig / LifecyclePolicy + lifecycle](phase-3-bootconfig-liveconfig-lifecycle.md) | Blocked (by Phase 2) |
| 4 | [Engine + mock + protos + audit](phase-4-engine-mock-protos-audit.md) | Blocked (by Phase 3) |
| 5 | [Base loops (worker, orchestrator, bridge, bootstrap, reconciler)](phase-5-base-loops.md) | Blocked (by Phase 4) |
| 6 | [Kind cluster and Helm chart](phase-6-cluster-bringup-tree.md) | Blocked (by Phase 5) |
| 7 | [hostbootstrap.dhall and project Dockerfile](phase-7-hostbootstrap-and-project-dockerfile.md) | Blocked (by Phase 6) |
| 8 | [Test harness integration](phase-8-test-harness-integration.md) | Blocked (by Phase 7) |

## Governance

- [development_plan_standards.md](development_plan_standards.md) defines how the plan is
  organized, updated, and kept aligned with implementation.
- [00-overview.md](00-overview.md) tells the cross-phase narrative and names the dependency
  edges.
- [system-components.md](system-components.md) is the authoritative inventory of substrate
  components.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the cleanup ledger.

## Authority

This plan owns current-state implementation status. When status claims in
[`../documents/`](../documents/) conflict with the plan, reconcile the governed docs to the
plan. See [development_plan_standards.md § J](development_plan_standards.md).
