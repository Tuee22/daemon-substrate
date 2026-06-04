# Phase 4: Engine Typeclass + Mock Engine + Protobuf Envelopes + Audit Topic

**Status**: Authoritative source
**Supersedes**: `phase-4-worker-and-orchestrator-base-loops.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-bootconfig-liveconfig-lifecycle.md](phase-3-bootconfig-liveconfig-lifecycle.md), [phase-5-base-loops.md](phase-5-base-loops.md)

> **Purpose**: Land the engine seam (`HasEngine` + `SubprocessEngine` / `NativeEngine`
> variants), the mock engine used by every integration test, the substrate-owned protobuf
> envelopes, and `Daemon.Audit` — the compacted-topic helper the reconciler depends on.

## Phase Status

**Status**: Done
**Implementation**: Sprints 4.1 through 4.5 are implemented and validated.

## Phase Objective

Build the engine boundary and the audit primitive both base loops need. The engine seam is
the only place the substrate ever talks to consumer-owned code that touches real hardware;
the mock engine is the substrate's own deterministic placeholder for every integration test.

The protobuf schemas land here (not Phase 2) so that the audit envelope's resource-kind /
action-kind enums can be defined alongside the other substrate-owned envelopes.

## Sprints

### Sprint 4.1: Protobuf schemas + code generation [Done]

**Status**: Done
**Implementation**: `proto/daemon_substrate/*.proto`,
`proto/daemon_substrate_test/mock.proto`, `src/Daemon/Proto/*.hs`,
`src/Daemon/Proto/Workflow.hs`, `daemon-substrate.cabal`, `test/unit/Main.hs`
**Docs to update**: `documents/reference/proto_surface.md`, `system-components.md`

#### Objective

Land every `.proto` file listed in `documents/reference/proto_surface.md` and wire
proto-lens-driven code generation into the cabal stanza.

#### Deliverables

- `proto/daemon_substrate/workflow.proto` (`WorkflowEvent`, `WorkflowKind` enum, `ObjectRef`).
  `WorkflowEvent` carries `event_id`, `produced_at`, `deadline_at` (`0` = no deadline),
  `workflow_kind`, `payload_type`, and a `payload` oneof of `bytes inline_bytes` vs
  `ObjectRef object_ref`. The producer chooses the branch by payload nature; the substrate is
  payload-blind and enforces only a max inline-payload size (guard rail) at publish time,
  failing closed with a typed `InlinePayloadTooLarge` error per `BootConfig.maxInlinePayloadBytes`
  rather than rewriting the envelope. See the schema in
  [`../documents/reference/proto_surface.md`](../documents/reference/proto_surface.md).
- `proto/daemon_substrate/control.proto` (`ControlEnvelope`, `Drain`, `Reload`)
- `proto/daemon_substrate/orchestrator_worker.proto` (`OrchestratorToWorker`, `WorkerResult`,
  `SuccessPayload`, `FailurePayload`)
- `proto/daemon_substrate/lifecycle.proto` (`LifecyclePhase` enum, `ReadinessReport`) — the
  protobuf `LifecyclePhase` is the wire serialization of the Haskell
  `Daemon.Lifecycle.LifecyclePhase` introduced in
  [phase-3-bootconfig-liveconfig-lifecycle.md](phase-3-bootconfig-liveconfig-lifecycle.md)
  Sprint 3.4; the two enums must have identical variant order
  (`Load | Prereq | Acquire | Ready | Serve | Drain | Exit`).
- `proto/daemon_substrate/audit.proto` (`AuditEvent`, `ResourceRef`, `ReconcileAction`).
  `AuditEvent` includes `repeated ObjectRef source_refs` and `repeated ObjectRef result_refs`
  for lineage in-edges and out-edges. Graph indexing (BFS/DFS traversal, predicate hooks)
  is deferred to a later phase; the wire fields land now so consumers can populate them.
- `proto/daemon_substrate_test/mock.proto` (`MockRequest`, `MockBatch`, `MockResult`)
- `daemon-substrate.cabal` `build-tool-depends: proto-lens-protoc`, `autogen-modules`
- Generated `Daemon.Proto.*` modules build and are importable

#### Validation

`cabal build all` succeeds. A `daemon-substrate-unit` test round-trips one message of each
type (encode → decode → equality). Round-trip test asserts the new `WorkflowEvent.payload`
oneof preserves identity across the `inline_bytes` and `object_ref` branches, and that
`WorkflowKind` round-trips for every variant (including `WORKFLOW_KIND_UNSPECIFIED` for
proto3 default behavior). A publish-path test asserts the guard rail: an over-max `inline_bytes`
payload is rejected at publish time with a typed `InlinePayloadTooLarge` error (the substrate
does not externalize it), while an `object_ref` payload of any size publishes unaffected.

Validated with:

- `cabal check` (passes; only the existing no-source-repository warning)
- `cabal build all`
- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit`
- markdown metadata validator
- phase structure validator

### Sprint 4.2: `HasEngine` typeclass + engine-handle sum [Done]

**Status**: Done
**Implementation**: `src/Daemon/Engine.hs`, `src/Daemon/Test/EchoEngines.hs`,
`daemon-substrate.cabal`, `test/unit/Main.hs`
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Engine.HasEngine` with a **batch-native** handler signature:

```haskell
engineCall :: NonEmpty EngineRequest -> m (NonEmpty (Either EngineError EngineResponse))
```

Per-request callers (e.g., the test echo engine) wrap a singleton `NonEmpty`. The batch-native
shape is required so the Phase 5 `Daemon.Batching.Batcher` can dispatch without per-request
synchronization; consumers' engines (`infernix` LLM serving stacks, `jitML` training kernels)
are already batch-native in practice. Define `EngineRequest`, `EngineResponse`, `EngineError`,
and the `SubprocessEngine` / `NativeEngine` constructors. Both variants implement the batched
`HasEngine`.

#### Deliverables

- `src/Daemon/Engine.hs` populated with the batched signature
- trivial native echo engine + trivial subprocess echo engine under
  `src/Daemon/Test/EchoEngines.hs` (both implement the batched signature, returning the input
  list unchanged)
- unit tests covering: singleton-batch round-trip, multi-element-batch round-trip, per-element
  error propagation (one element fails, others succeed), batch-wide error (engine crash),
  timeout (subprocess variant)

#### Validation

Validated with:

- `cabal check` (passes; only the existing no-source-repository warning)
- `cabal build all`
- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit`
- markdown metadata validator
- phase structure validator

### Sprint 4.3: Mock engine [Done]

**Status**: Done
**Implementation**: `src/Daemon/Test/MockEngine.hs`, `daemon-substrate.cabal`,
`test/unit/Main.hs`
**Docs to update**: `documents/engineering/mock_engine.md`, `system-components.md`

#### Objective

Land `Daemon.Test.MockEngine` — a `NativeEngine` that accepts a `NonEmpty MockRequest`,
reads input bytes from the MinIO blob referenced by each `MockRequest.weight_key`, returns
`NonEmpty MockResult` where each result is `sha256(request_id || weight bytes)` (32 bytes),
and honors `MockRequest.force_failure` per element for retry-path coverage. The batched
signature exercises the Phase 5 batcher path end-to-end. No GPU, no FFI, no Python, no Metal,
no CUDA. See [`../documents/engineering/mock_engine.md`](../documents/engineering/mock_engine.md)
for the full message contract.

Same instance is reused by every integration test row in Phase 8.

#### Deliverables

- `src/Daemon/Test/MockEngine.hs` populated (exposed for the `daemon-substrate-test`
  executable; not part of consumer-facing surface). Implements the batched
  `engineCall :: NonEmpty MockRequest -> m (NonEmpty (Either EngineError MockResult))`.
- unit tests covering: singleton batch happy path, multi-element batch happy path, mixed
  success/failure in a single batch (one `force_failure = true`, others succeed), cache cold
  / warm paths

#### Validation

Validated with:

- `cabal check` (passes; only the existing no-source-repository warning)
- `cabal build all`
- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit`
- markdown metadata validator
- phase structure validator

### Sprint 4.4: `Daemon.Audit` compacted-topic helper [Done]

**Status**: Done
**Implementation**: `src/Daemon/Audit.hs`, `daemon-substrate.cabal`, `test/unit/Main.hs`
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

#### Validation

Validated with:

- `cabal check` (passes; only the existing no-source-repository warning)
- `cabal build all`
- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit`
- markdown metadata validator
- phase structure validator

### Sprint 4.5: `Daemon.Wire.*` hand-written ADTs + round-trip property tests [Done]

**Status**: Done
**Implementation**: `src/Daemon/Wire/Workflow.hs`, `src/Daemon/Wire/Control.hs`,
`src/Daemon/Wire/OrchestratorWorker.hs`, `src/Daemon/Wire/Lifecycle.hs`,
`src/Daemon/Wire/Audit.hs`, `daemon-substrate.cabal`, `test/unit/Main.hs`,
`test/haskell-style/Main.hs`
**Docs to update**: `documents/reference/proto_surface.md`, `system-components.md`

#### Objective

Define hand-written Haskell ADTs in `Daemon.Wire.*` that mirror every generated
`Daemon.Proto.*` envelope and expose `toProto` / `fromProto` codecs. Application code uses
`Daemon.Wire.*`; only the Pulsar publish / subscribe boundary touches `Daemon.Proto.*`. The
generated `proto-lens` lens-records are not idiomatic Haskell and should not leak into call
sites.

#### Deliverables

- `src/Daemon/Wire/Workflow.hs` — `WorkflowEvent` ADT with `Maybe UTCTime` for `deadline_at`
  (Nothing when the proto field is 0), a Haskell `WorkflowKind` sum, and a `WirePayload =
  WireInline ByteString | WireObjectRef ObjectRef` sum.
- `src/Daemon/Wire/Control.hs` — `ControlEnvelope`, `Drain`, `Reload` ADTs.
- `src/Daemon/Wire/OrchestratorWorker.hs` — `OrchestratorToWorker`, `WorkerResult`,
  outcome sum.
- `src/Daemon/Wire/Lifecycle.hs` — `LifecyclePhase`, `ReadinessReport` (mirrors the existing
  Haskell `Daemon.Lifecycle.LifecyclePhase`).
- `src/Daemon/Wire/Audit.hs` — `AuditEvent` with `[ObjectRef]` lineage lists.
- Round-trip property tests in `daemon-substrate-unit`: for every Wire ADT,
  `decodeMessage . encodeMessage . toProto . fromProto === id` over a hedgehog generator,
  1000 iterations per envelope type.

#### Validation

Property suite passes 1000 iterations per envelope type. A linter check (or grep gate) in
`daemon-substrate-haskell-style` asserts that no module outside `src/Daemon/Wire/` or the
publish/subscribe boundary imports `Daemon.Proto.*` directly.

Validated with:

- `cabal check` (passes; only the existing no-source-repository warning)
- `cabal build all`
- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit`
- `cabal test daemon-substrate-haskell-style`
- markdown metadata validator
- phase structure validator

#### Module Surface

```haskell
data WorkflowEvent = WorkflowEvent
  { eventId      :: !Text
  , producedAt   :: !UTCTime
  , deadlineAt   :: !(Maybe UTCTime)   -- Nothing when proto deadline_at = 0
  , workflowKind :: !WorkflowKind
  , payloadType  :: !PayloadTypeUrl
  , payload      :: !WirePayload
  }

data WorkflowKind = Training | Inference | Evaluation | Ingestion | Audit | Custom

data WirePayload = WireInline !ByteString | WireObjectRef !ObjectRef

toProto   :: WorkflowEvent -> Daemon.Proto.Workflow.WorkflowEvent
fromProto :: Daemon.Proto.Workflow.WorkflowEvent -> Either WireError WorkflowEvent
```

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` updates with the proto code-gen wiring (proto-lens
  `build-tool-depends` + `autogen-modules`) landed in Sprint 4.1.
- `documents/engineering/mock_engine.md` updates from "planned" to current-state — including
  the batch-native `NonEmpty MockRequest -> NonEmpty MockResult` shape.
- `documents/architecture/lifecycle_policy.md` updates the "Library modules" entry for
  `Daemon.Audit` from forward-looking to current-state.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` updates from "planned" to current-state declarative.
  The `workflow.proto` schema reads as the implemented shape with `deadline_at`,
  `WorkflowKind`, and the `payload` oneof; the `audit.proto` schema includes the lineage
  reference fields (graph indexing deferred). The new `## Wire-layer wrappers` section reads
  as the implemented surface after Sprint 4.5.

**Cross-references to add:**
- `system-components.md` flips `Daemon.Engine`, `Daemon.Audit`, `Daemon.Proto.*`, and
  `Daemon.Wire.*` rows to `Implemented: yes`. The `HasEngine` row reflects the batch-native
  signature.
