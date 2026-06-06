# Pulsar Topics (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [cluster_topology.md](cluster_topology.md), [mock_engine.md](mock_engine.md), [orchestration_topologies.md](orchestration_topologies.md), [batching.md](batching.md), [pulsar_native_client.md](pulsar_native_client.md), [../reference/proto_surface.md](../reference/proto_surface.md)

> **Purpose**: Inventory every Pulsar topic the test harness uses, the subscription mode each
> subscriber attaches with, and the protobuf payload each topic carries.

## TL;DR

- Five workflow topics: `test.request`, `test.batch.<cohort>`, `test.result`,
  `test.control.orchestrator`, `test.control.worker`.
- Two reconciler-control topics: `control.reconcile.leader.<consumer>` (Failover, for
  leader election among orchestrator replicas) and `audit.reconcile.<consumer>` (compacted,
  keyed by `<kind>:<id>` for reconciliation audit log).
- Lifecycle-mode test topics added per `TopicLifecycle` variant covered in the integration
  suite (one each of `Ephemeral`, `ContinuousWithArchive`, `FiniteSession`,
  `OnlineLearning`).
- Worker fan-out and orchestrator fan-in / fan-back are all `Shared` mode. Multiple
  orchestrator replicas consume the same subscription in parallel; the harness worker is
  cardinality-one for each matrix case because it owns the resources of the whole node.
  Pulsar's `Shared` semantics still prevent duplicate delivery.
- `test.request` is **the public ingress topic** — upstream users of the overall compute
  workflow publish here directly. The substrate exposes no separate HTTP / gRPC / REST
  surface.
- Substrate-owned envelopes are protobuf; the consumer (in the test harness's case, a mock
  driver) ships its payload type inside the envelope. The harness uses `MockRequest`,
  `MockBatch`, and `MockResult` protobuf messages for request batching and results.

## Topic inventory

| Topic | Producer | Subscriber | Subscription mode | Partitions | Payload |
|-------|----------|------------|-------------------|------------|---------|
| `test.request` | test driver (representing an upstream user; public ingress) | orchestrator (N replicas) | `Shared` | 1 | `WorkflowEvent { MockRequest }` |
| `test.batch.<cohort>` | orchestrator | worker | `Shared` (single worker in the harness; consumers may scale by deployment policy) | 1 | `OrchestratorToWorker { MockBatch }` |
| `test.result` | worker | orchestrator (N replicas) | `Shared` | 1 | `WorkerResult { MockResult }` |
| `test.control.orchestrator` | test driver | orchestrator | `Failover` | 1 | `ControlEnvelope { Drain | Reload }` |
| `test.control.worker` | orchestrator | worker | `Failover` | 1 | `ControlEnvelope { Drain | Reload }` |
| `control.reconcile.leader.daemon-substrate-test` | (any orchestrator replica) | orchestrator (×N; only one active) | `Failover` | 1 | leader-election placeholder payload |
| `audit.reconcile.daemon-substrate-test` | reconciler leader | (consumers / debug; integration tests assert state) | compacted topic, key = `<kind>:<id>` | 1 | `AuditEvent` |
| `test.session.control` | test driver | reconciler leader | `Failover` | 1 | session start/end events for `FiniteSession`-mode topics |
| `test.session.workload.<session-id>` | session producer / consumer | session consumer | `Shared` | 1 | created on `session-start`, terminated on `session-end` |

### Partition counts

Every test-harness topic is partitioned at **1 partition**. The harness exercises horizontal
scale via multiple consumer replicas attaching to the same `Shared` subscription on a
single-partition topic, which is sufficient to validate the substrate's transport plumbing.
Higher partition counts add no coverage for the harness's purposes.

Consumer projects (`infernix`, `jitML`) choose partition counts for their own topics in their
own `LifecyclePolicy` — partitioning is a consumer-deployment concern, not a substrate one.

See [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md) for the full
reconciler / audit / leader-election design.

`<cohort>` is `apple-silicon` or `linux-cpu`; the test harness picks the topic by cohort so a
co-resident Apple worker and Linux worker do not steal each other's batches.

## Subscription mode rules

- **Shared** is the default mode for orchestrator and worker fan-out / fan-in / fan-back.
  Multiple coordinator/orchestrator replicas attach to the same subscription name; the broker
  distributes messages round-robin and guarantees at-most-one-active-consumer-per-message. The
  harness deliberately keeps worker cardinality at one per matrix case, so worker `Shared`
  mode validates cursor semantics without validating multiple worker replicas.
- **Exclusive** is not used anywhere in the current harness. The harness is deliberately
  designed to validate the lock-free shared-subscription model. (Reserved for future use if a
  control topic ever needs strict single-consumer ownership of a cursor.)
- **Failover** for graceful-drain control envelopes. One active subscriber receives messages;
  on its disconnect, Pulsar promotes the standby. Used so a redeployed orchestrator or worker
  can pick up the cursor where the previous instance left off without dropping in-flight
  control commands.
- `KeyShared` is not used in the test harness. The mock engine is stateless across requests
  (no KV cache, no sticky context); affinity provides no benefit. Real consumers like
  `infernix` will use `KeyShared` for context-affine LLM inference, but that's their concern.

## Subscription naming

Subscription names follow the rule from
[`development_plan_standards.md` § K](../../DEVELOPMENT_PLAN/development_plan_standards.md):
the per-host enforcement scheme via host-tagged subscription names is **not** used here,
because the harness is designed to validate the lock-free shared-subscription model. Names are
flat:

- `daemon-substrate-test-orchestrator` (shared across all orchestrator replicas)
- `daemon-substrate-test-worker-<cohort>` (the single worker for that matrix case)

Two orchestrator replicas attach under the same `daemon-substrate-test-orchestrator`
subscription; Pulsar treats them as one consumer set and distributes accordingly. The harness
does not run multiple worker replicas within a matrix case.

## Payload encoding

Substrate-owned envelopes are protobuf, encoded with `proto-lens`'s `encodeMessage` /
`decodeMessage`. The envelopes live in `proto/daemon_substrate/workflow.proto` and friends;
the test-harness mock types live in `proto/daemon_substrate_test/mock.proto`. See
[../reference/proto_surface.md](../reference/proto_surface.md).

Substrate publishes and consumes envelopes via the `Daemon.Wire.*` ADT layer; only the wire
boundary touches generated `Daemon.Proto.*` types. Application code (test harness and
consumer base loops alike) sees idiomatic Haskell ADTs with `Maybe UTCTime` deadlines,
`WorkflowKind` sums, and a `WirePayload = WireInline ByteString | WireObjectRef ObjectRef`
sum — never the generated lens-records.

Consumer payloads carried inside `WorkflowEvent.inline_bytes` (or referenced via
`WorkflowEvent.object_ref`) are opaque to substrate; the harness's mock payloads are one
example, but consumers in production (`infernix`, `jitML`) choose their own encoding.

## Acknowledgement and retry

Standard Pulsar semantics. The harness exercises:

- happy path: each worker `pulsarAcknowledge`s after a successful mock-engine return
- typed-failure path: if the mock engine is asked to fail (via a flag in `MockRequest`), the
  worker publishes a `WorkerResult.failure` envelope and acknowledges the source batch
- retry path: malformed batches, payload materialization failures, or result-publish failures
  cause the worker to `pulsarNegativeAcknowledge` so the broker redelivers
- dedup path: `Daemon.Consumer.consumerStep` rejects duplicate `EventId`s seen within the dedup
  window; the harness sends the same `MockRequest` twice and asserts only one
  `WorkerResult` is published
- routing path: `Daemon.Consumer.HandlerRouter` dispatches by longest `payload_type` URL prefix
  and `consumerStep` nacks when a handler reports failure

## Cross-references

- The SSoT story: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md)
- What the orchestrator and worker do with these messages: [../architecture/daemon_roles.md](../architecture/daemon_roles.md)
- Generated protobuf modules and `Daemon.Wire.*` wrappers: [../reference/proto_surface.md](../reference/proto_surface.md)
- Typed Pulsar topology builders consumers use to assemble workflows: [orchestration_topologies.md](orchestration_topologies.md)
- Substrate-owned batcher + multi-bucket scheduler for accelerated worker pools: [batching.md](batching.md)
