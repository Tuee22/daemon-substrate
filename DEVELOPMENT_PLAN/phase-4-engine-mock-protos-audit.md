# Phase 4: Engine Typeclass + Mock Engine + Protobuf Envelopes + Audit Topic

**Status**: Authoritative source
**Supersedes**: `phase-4-worker-and-orchestrator-base-loops.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-bootconfig-liveconfig-lifecycle.md](phase-3-bootconfig-liveconfig-lifecycle.md), [phase-5-base-loops.md](phase-5-base-loops.md)

> **Purpose**: Land the engine seam (`HasEngine` + `SubprocessEngine` / `NativeEngine`
> variants), the mock engine used by every integration test, the substrate-owned protobuf
> envelopes, and `Daemon.Audit` — the compacted-topic helper the reconciler depends on.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 3
**Implementation**: none yet

## Phase Objective

Build the engine boundary and the audit primitive both base loops need. The engine seam is
the only place the substrate ever talks to consumer-owned code that touches real hardware;
the mock engine is the substrate's own deterministic placeholder for every integration test.

The protobuf schemas land here (not Phase 2) so that the audit envelope's resource-kind /
action-kind enums can be defined alongside the other substrate-owned envelopes.

## Sprints

### Sprint 4.1: Protobuf schemas + code generation [Planned]

**Status**: Planned
**Docs to update**: `documents/reference/proto_surface.md`, `system-components.md`

#### Objective

Land every `.proto` file listed in `documents/reference/proto_surface.md` and wire
proto-lens-driven code generation into the cabal stanza.

#### Deliverables

- `proto/daemon_substrate/workflow.proto` (`WorkflowEvent`, `ObjectRef`)
- `proto/daemon_substrate/control.proto` (`ControlEnvelope`, `Drain`, `Reload`)
- `proto/daemon_substrate/orchestrator_worker.proto` (`OrchestratorToWorker`, `WorkerResult`,
  `SuccessPayload`, `FailurePayload`)
- `proto/daemon_substrate/lifecycle.proto` (`LifecyclePhase` enum, `ReadinessReport`)
- `proto/daemon_substrate/audit.proto` (`AuditEvent`, `ResourceRef`, `ReconcileAction`)
- `proto/daemon_substrate_test/mock.proto` (`MockRequest`, `MockBatch`, `MockResult`)
- `daemon-substrate.cabal` `build-tool-depends: proto-lens-protoc`, `autogen-modules`
- Generated `Daemon.Proto.*` modules build and are importable

#### Validation

`cabal build all` succeeds. A `daemon-substrate-unit` test round-trips one message of each
type (encode → decode → equality).

### Sprint 4.2: `HasEngine` typeclass + engine-handle sum [Planned]

**Status**: Planned
**Blocked by**: 4.1
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Engine.HasEngine`, `EngineRequest`, `EngineResponse`, `EngineError`, and the
`SubprocessEngine` / `NativeEngine` constructors. Both variants implement `HasEngine`.

#### Deliverables

- `src/Daemon/Engine.hs` populated
- trivial native echo engine + trivial subprocess echo engine under
  `src/Daemon/Test/EchoEngines.hs`
- unit tests covering: round-trip through both variants, error propagation, timeout
  (subprocess variant)

### Sprint 4.3: Mock engine [Planned]

**Status**: Planned
**Blocked by**: 4.2
**Docs to update**: `documents/engineering/mock_engine.md`, `system-components.md`

#### Objective

Land `Daemon.Test.MockEngine` — a `NativeEngine` that reads input bytes from a MinIO blob
referenced in the `EventEnvelope`, returns sha256(input) (32 bytes) as the result, and honors
a `force_failure` flag for retry-path coverage. No GPU, no FFI, no Python, no Metal, no CUDA.

Same instance is reused by every integration test row in Phase 8.

#### Deliverables

- `src/Daemon/Test/MockEngine.hs` populated (exposed for the `daemon-substrate-test`
  executable; not part of consumer-facing surface)
- unit tests covering: happy path, forced-failure path, cache cold / warm paths

### Sprint 4.4: `Daemon.Audit` compacted-topic helper [Planned]

**Status**: Planned
**Blocked by**: 4.1, 4.2
**Docs to update**: `documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Define `Daemon.Audit` — the compacted-topic helper the reconciler in Phase 5 depends on.
Operations:

- `auditPublish :: HasPulsar m => Topic -> ResourceRef -> ReconcileAction -> m ()` — publish
  to the compacted audit topic, keyed by `<kind>:<id>`.
- `auditReplay :: HasPulsar m => Topic -> m (Map ResourceRef ReconcileAction)` — read the
  compacted topic from the beginning, build the latest-state map per resource.

#### Deliverables

- `src/Daemon/Audit.hs` populated
- unit tests covering: publish round-trip, replay after multiple writes to the same key
  (compaction semantics), concurrent-publish dedup

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/mock_engine.md` updates from "planned" to current-state.
- `documents/architecture/lifecycle_policy.md` updates the "Library modules" entry for
  `Daemon.Audit` from forward-looking to current-state.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` updates from "planned" to current-state declarative;
  the new `audit.proto` row reads as the implemented schema.

**Cross-references to add:**
- `system-components.md` flips `Daemon.Engine`, `Daemon.Audit`, and `Daemon.Proto.*` rows to
  `Implemented: yes`.
