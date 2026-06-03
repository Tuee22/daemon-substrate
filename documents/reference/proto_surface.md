# Protobuf Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md), [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md), [../engineering/batching.md](../engineering/batching.md), [../engineering/mock_engine.md](../engineering/mock_engine.md)

> **Purpose**: Authoritative inventory of every `.proto` file in `proto/`, the messages each
> defines, and the boundary between substrate-owned envelopes and consumer-owned (or
> test-harness-owned) payloads.

## TL;DR

- Substrate-owned envelopes live under `proto/daemon_substrate/`.
- Test-harness payloads live under `proto/daemon_substrate_test/`.
- Consumers define their own payload protos (or other encoded bytes) in their own repositories.
  The substrate provides the envelopes that wrap them.
- Substrate-owned envelopes are protobuf. Consumer-owned payloads (carried inside
  `WorkflowEvent.inline_bytes` or referenced via `WorkflowEvent.object_ref`) may use whatever
  encoding the consumer chooses — substrate treats them as opaque bytes and routes by
  `payload_type` URL prefix.
- Payloads larger than `BootConfig.blobInlineThresholdBytes` MUST flow as `object_ref`
  (substrate enforces the switch at publish time); see
  [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md).
- Application code uses hand-written `Daemon.Wire.*` ADTs that wrap the generated
  `Daemon.Proto.*` records; only the publish / subscribe boundary touches the generated types.

## Layout

```
proto/
├── daemon_substrate/
│   ├── workflow.proto            # WorkflowEvent envelope, ObjectRef, EventId
│   ├── control.proto             # ControlEnvelope (Drain, Reload, etc.)
│   ├── orchestrator_worker.proto # OrchestratorToWorker, WorkerResult
│   ├── lifecycle.proto           # LifecyclePhase, ReadinessReport (for /readyz)
│   └── audit.proto               # AuditEvent, ResourceRef, ReconcileAction (for runReconciler)
└── daemon_substrate_test/
    └── mock.proto                # MockRequest, MockBatch, MockResult, MockPayload
```

The substrate library carries everything under `daemon_substrate/`. The test harness owns
`daemon_substrate_test/`. Consumers carry their own payload protos in their own repositories;
those protos are wrapped by the substrate-owned envelopes at Pulsar publish time.

## Substrate-owned envelopes

### `daemon_substrate/workflow.proto`

```proto
syntax = "proto3";
package daemon_substrate;

// Carried inside every Pulsar message the substrate publishes or consumes.
message WorkflowEvent {
  string       event_id      = 1;  // sha256 of payload bytes; for L3 dedup
  int64        produced_at   = 2;  // unix nanoseconds; monotonic per producer
  int64        deadline_at   = 3;  // unix nanoseconds; 0 = no deadline; consumed by Batcher
  WorkflowKind workflow_kind = 4;  // operational classification; see enum below
  string       payload_type  = 5;  // fully-qualified protobuf type URL of inline_bytes (when set)
  oneof payload {
    bytes     inline_bytes   = 6;  // payload at-or-below BootConfig.blobInlineThresholdBytes
    ObjectRef object_ref     = 7;  // payload above the threshold; substrate enforces the switch
  }
}

// Operational classification. Affects substrate-level behavior (drain ordering, scaling
// policy, observability segmentation, audit aggregation) but does NOT prescribe payload
// shape — that is the consumer's payload_type URL.
enum WorkflowKind {
  WORKFLOW_KIND_UNSPECIFIED = 0;
  WORKFLOW_KIND_TRAINING    = 1;
  WORKFLOW_KIND_INFERENCE   = 2;
  WORKFLOW_KIND_EVALUATION  = 3;
  WORKFLOW_KIND_INGESTION   = 4;
  WORKFLOW_KIND_AUDIT       = 5;
  WORKFLOW_KIND_CUSTOM      = 6;   // pair with payload_type URL for operational tagging
}

message ObjectRef {
  string bucket = 1;
  string key    = 2;
  string etag   = 3;               // optional; for explicit version pinning
}
```

`deadline_at = 0` means no deadline (best-effort). For requests with a non-zero deadline,
the substrate batcher honors it: requests near their deadline force-flush their bucket;
requests past their deadline are dropped before dispatch. See
[../engineering/batching.md](../engineering/batching.md).

The `payload` oneof keeps Pulsar payloads bounded: bytes above the configured threshold ride
in MinIO as `ObjectRef`, leaving the Pulsar message message-shaped. Receivers can opt into
transparent materialization via `Daemon.MinIO.Store.readBlob`.

### `daemon_substrate/control.proto`

```proto
syntax = "proto3";
package daemon_substrate;

message ControlEnvelope {
  oneof command {
    Drain  drain  = 1;
    Reload reload = 2;
  }
}

message Drain  { int64 deadline_unix_nanos = 1; }
message Reload {}
```

### `daemon_substrate/orchestrator_worker.proto`

```proto
syntax = "proto3";
package daemon_substrate;

import "daemon_substrate/workflow.proto";

// Orchestrator → Worker fan-out envelope.
message OrchestratorToWorker {
  string batch_id   = 1;
  string cohort     = 2;                // "apple-silicon" | "linux-cpu" | ...
  repeated WorkflowEvent events = 3;    // batched requests
}

// Worker → Orchestrator result envelope.
message WorkerResult {
  string request_id = 1;
  string batch_id   = 2;
  oneof outcome {
    SuccessPayload  success = 3;
    FailurePayload  failure = 4;
  }
}

message SuccessPayload {
  bytes      result_payload = 1;        // consumer- or test-defined
  string     payload_type   = 2;
  ObjectRef  output_object  = 3;        // optional MinIO reference
}

message FailurePayload {
  string reason = 1;
  int32  attempt = 2;
}
```

### `daemon_substrate/lifecycle.proto`

```proto
syntax = "proto3";
package daemon_substrate;

enum LifecyclePhase {
  LIFECYCLE_PHASE_UNSPECIFIED = 0;
  LIFECYCLE_PHASE_LOAD        = 1;
  LIFECYCLE_PHASE_PREREQ      = 2;
  LIFECYCLE_PHASE_ACQUIRE     = 3;
  LIFECYCLE_PHASE_READY       = 4;
  LIFECYCLE_PHASE_SERVE       = 5;
  LIFECYCLE_PHASE_DRAIN       = 6;
  LIFECYCLE_PHASE_EXIT        = 7;
}

message ReadinessReport {
  LifecyclePhase phase             = 1;
  string         phase_detail       = 2;
  int64          heartbeat_at      = 3;   // unix nanoseconds
  bool           ready             = 4;
}
```

### `daemon_substrate/audit.proto`

```proto
syntax = "proto3";
package daemon_substrate;

// Identifies a substrate-managed resource for the compacted audit topic. The compaction key
// is rendered as "<kind>:<id>", so each resource has at most one live record.
message ResourceRef {
  string kind = 1;   // "pulsar-topic" | "minio-bucket" | "minio-object" | "pulsar-subscription"
  string id   = 2;   // topic name, bucket name, object key, etc.
}

// The kind of reconciliation action the leader executed for a resource. This is the value
// stored in the compacted audit topic, keyed by ResourceRef.
enum ReconcileAction {
  RECONCILE_ACTION_UNSPECIFIED = 0;
  RECONCILE_ACTION_CREATED     = 1;
  RECONCILE_ACTION_CONFIGURED  = 2;   // retention / compaction / dedup-window applied
  RECONCILE_ACTION_TERMINATED  = 3;   // Pulsar topic terminated (no further writes)
  RECONCILE_ACTION_EXPORTED    = 4;   // contents archived to MinIO
  RECONCILE_ACTION_IMPORTED    = 5;   // FiniteSession resume restored archive into topic
  RECONCILE_ACTION_DELETED     = 6;   // resource removed
  RECONCILE_ACTION_NOOP        = 7;   // observed == desired; recorded for idempotency proof
}

// A single audit record. Published by the reconciler leader after every executed action.
// Consumed by future leaders on startup (via Daemon.Audit.auditReplay) to reconstruct
// "what is already done" without re-executing.
message AuditEvent {
  ResourceRef     resource         = 1;
  ReconcileAction action           = 2;
  int64           executed_at      = 3;   // unix nanoseconds, monotonic per leader
  string          leader_replica   = 4;   // pod / process identity (debug aid)
  string          detail           = 5;   // free-form (e.g., archive object key)
  repeated ObjectRef source_refs   = 6;   // optional; lineage in-edges (graph indexing deferred)
  repeated ObjectRef result_refs   = 7;   // optional; lineage out-edges (graph indexing deferred)
}
```

The `source_refs` and `result_refs` fields land on the wire now so consumers can populate
them as they emit audit events. Graph indexing (BFS/DFS traversal, per-consumer predicate
hooks) is deferred to a later phase. Lineage is per-consumer: `infernix` and `jitML` are
sealed loops over shared substrate primitives, so substrate does not provide cross-consumer
lineage queries. Each consumer queries its own lineage subgraph independently.

## Test-harness payloads

### `daemon_substrate_test/mock.proto`

```proto
syntax = "proto3";
package daemon_substrate_test;

import "daemon_substrate/workflow.proto";

message MockRequest {
  string request_id    = 1;
  string weight_key    = 2;
  bool   write_output  = 3;
  bool   force_failure = 4;
  int64  cache_hint    = 5;
}

message MockBatch {
  repeated MockRequest requests = 1;
}

message MockResult {
  string                        request_id   = 1;
  bytes                         result_hash  = 2;     // 32-byte SHA-256
  daemon_substrate.ObjectRef    output_ref   = 3;     // optional
  int64                         weight_bytes = 4;
  bool                          cache_hit    = 5;
}
```

These ride inside the substrate-owned `WorkflowEvent.payload` / `OrchestratorToWorker.events`
/ `WorkerResult.success.result_payload` fields.

## Generated Haskell

Protobuf code generation produces modules under `src/Daemon/Proto/`:

- `Daemon.Proto.Workflow`
- `Daemon.Proto.Control`
- `Daemon.Proto.OrchestratorWorker`
- `Daemon.Proto.Lifecycle`
- `Daemon.Proto.Audit`
- `Daemon.Proto.Test.Mock` (test-harness only)

The generator is `proto-lens-setup`-driven; the Cabal stanza for the library declares both
`build-tool-depends: proto-lens-protoc` and the appropriate `autogen-modules`. See
[../engineering/cabal_layout.md](../engineering/cabal_layout.md).

## Wire-layer wrappers

Generated `Daemon.Proto.*` modules expose `proto-lens` lens-records that are not idiomatic
Haskell. Substrate exports hand-written `Daemon.Wire.*` ADTs that mirror each envelope, with
`toProto` / `fromProto` codecs:

- `Daemon.Wire.Workflow`            — `WorkflowEvent`, `WorkflowKind`, `WirePayload`
- `Daemon.Wire.Control`             — `ControlEnvelope`, `Drain`, `Reload`
- `Daemon.Wire.OrchestratorWorker`  — `OrchestratorToWorker`, `WorkerResult`, outcome sum
- `Daemon.Wire.Lifecycle`           — `LifecyclePhase`, `ReadinessReport`
- `Daemon.Wire.Audit`               — `AuditEvent` with `ObjectRef` lineage lists

`Daemon.Wire.WorkflowEvent` carries `Maybe UTCTime` for `deadline_at` (Nothing when the proto
field is 0), a Haskell `WorkflowKind` ADT, and a `WirePayload = WireInline ByteString |
WireObjectRef ObjectRef` sum. Application code uses `Daemon.Wire.*`; only the Pulsar publish /
subscribe boundary touches `Daemon.Proto.*`. Round-trip property tests
(`decodeMessage . encodeMessage . toProto . fromProto === id`) are the conformance suite.
See [Phase 4 Sprint 4.5](../../DEVELOPMENT_PLAN/phase-4-engine-mock-protos-audit.md).

## Consumer payload encoding (non-normative)

`infernix` and `jitML` are both Haskell consumers on shared GHC 9.12; the substrate does not
impose a wire encoding on consumer payloads. Substrate guarantees envelope discipline and
routes by `WorkflowEvent.payload_type` URL prefix via `Daemon.Consumer.HandlerRouter`.

Consumers in this project use:

- `infernix` — protobuf catalog under `type.infernix.io/inference/v1/*` for stable multimodal
  inference contracts (text / image / audio / video, with large modalities flowing as
  `object_ref`).
- `jitML` — opaque bytes with `type.jitml.io/*` URLs for experimental SL / RL workload shapes;
  promote to protobuf as a shape stabilizes.

This is a consumer choice, not a substrate-imposed contract. The substrate treats every
`inline_bytes` payload as opaque and every `object_ref` payload as a MinIO reference. The
sealed-loop assumption applies: `infernix` and `jitML` exchange no payloads with each other,
so cross-consumer schema compatibility is not a substrate concern.

## Consumer-owned payloads

Consumers (`infernix`, `jitML`) define their own payload protos in their own repositories.
Examples:

- `infernix` defines `InferenceRequest`, `InferenceResult`, etc. in its own `proto/`
- `jitML` defines `TrainingCommand`, `EpochCompleted`, etc. in its own `proto/`

These ride inside `WorkflowEvent.payload`; the consumer sets `payload_type` to the
fully-qualified proto type URL and decodes accordingly on the receiving side. The substrate
treats `payload` as opaque bytes and never inspects it.

## Cross-references

- Pulsar topic / payload assignments: [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md)
- What the mock engine does with `MockRequest` / `MockResult`: [../engineering/mock_engine.md](../engineering/mock_engine.md)
- How consumers wire their own payload types: [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md)
