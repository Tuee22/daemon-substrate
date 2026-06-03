# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Phase plan orientation. Names the phases in execution order, reports the
> current status of each, and links to the standards and inventory documents.

## Phases

| Phase | Title | Status |
|-------|-------|--------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Active |
| 1 | [Library scaffolding and cabal package](phase-1-library-scaffolding-and-cabal-package.md) | Blocked (by Phase 0) |
| 2 | [Typeclasses: Pulsar, MinIO, Engine](phase-2-typeclasses-pulsar-minio-engine.md) | Blocked (by Phase 1) |
| 3 | [Daemon lifecycle and config](phase-3-daemon-lifecycle-and-config.md) | Blocked (by Phase 2) |
| 4 | [Worker and orchestrator base loops](phase-4-worker-and-orchestrator-base-loops.md) | Blocked (by Phase 3) |
| 5 | [Kind cluster and Helm chart](phase-5-kind-cluster-and-helm-chart.md) | Blocked (by Phase 4) |
| 6 | [Bootstrap and outer container](phase-6-bootstrap-and-outer-container.md) | Blocked (by Phase 5) |
| 7 | [Test harness integration](phase-7-test-harness-integration.md) | Blocked (by Phase 6) |

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
