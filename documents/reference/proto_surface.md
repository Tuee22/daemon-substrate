# Protobuf Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md), [../engineering/mock_engine.md](../engineering/mock_engine.md)

> **Purpose**: Authoritative inventory of every `.proto` file in `proto/`, the messages each
> defines, and the boundary between substrate-owned envelopes and consumer-owned (or
> test-harness-owned) payloads.

## TL;DR

- Substrate-owned envelopes live under `proto/daemon_substrate/`.
- Test-harness payloads live under `proto/daemon_substrate_test/`.
- Consumers define their own payload protos in their own repositories. The substrate provides
  the envelopes that wrap them.
- All Pulsar payloads are protobuf. JSON / Aeson / CBOR are not part of the supported
  contract.

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
  string event_id    = 1;          // sha256 of payload bytes; for L3 dedup
  int64  produced_at = 2;          // unix nanoseconds; monotonic per producer
  bytes  payload     = 3;          // consumer-defined or test-harness payload
  string payload_type = 4;         // fully-qualified protobuf type URL of `payload`
}

message ObjectRef {
  string bucket = 1;
  string key    = 2;
  string etag   = 3;               // optional; for explicit version pinning
}
```

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
}
```

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
