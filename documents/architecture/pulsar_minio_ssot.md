# Pulsar and MinIO Source-of-Truth Split

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [daemon_roles.md](daemon_roles.md), [library_consumption_model.md](library_consumption_model.md), [lifecycle_policy.md](lifecycle_policy.md), [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md), [../engineering/pulsar_native_client.md](../engineering/pulsar_native_client.md), [../engineering/minio_buckets.md](../engineering/minio_buckets.md), [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md), [../engineering/batching.md](../engineering/batching.md), [../reference/proto_surface.md](../reference/proto_surface.md)

> **Purpose**: Define the authoritative split between Pulsar (workflow source of truth) and
> MinIO (static blob source of truth), and the rules that keep the two complementary rather
> than overlapping.

## TL;DR

- **Pulsar** is authoritative for *work in motion*: every request, event, command, and
  sequence-model checkpoint that has to survive a daemon restart.
- **MinIO** is authoritative for *large static blobs*: model weights, datasets, generated
  images / audio / video, training checkpoints — anything large, immutable once written, and
  content-addressable.
- The two are complementary, not overlapping. Pulsar payloads stay small and message-shaped and
  *reference* MinIO objects by URL when a workload needs a large blob.
- **Substrate-owned envelopes are protobuf; consumer-owned payloads are opaque.** The
  substrate routes by `WorkflowEvent.payload_type` URL prefix; consumers choose whatever
  encoding fits their payload shape.
- **Consumer payloads are sealed per consumer.** `infernix` and `jitML` exchange no payloads
  with each other; they share infrastructure but not domain artifacts. Substrate mediates
  infrastructure (envelope, topology, batching, lifecycle), not consumer-to-consumer
  protocol.

## Why two stores

A single source of truth would be wrong: a message broker is a poor blob store, and a blob store
is a poor message broker. The substrate uses each for the thing it is good at.

- Pulsar's strengths: durable ordered topics, exactly-once-ish acks, replay-from-cursor,
  per-subscription delivery guarantees, low-latency fan-out. Used for: everything that has a
  workflow event shape.
- MinIO's strengths: cheap large-object storage, content-addressable keys, S3-compatible API,
  ETag-based optimistic concurrency. Used for: everything that has a blob shape.

## What goes where

### Pulsar (workflow SSoT)

Pulsar carries every protobuf event that a daemon needs to recover from on restart:

- inference requests and results (consumer workloads like `infernix`)
- training commands and per-step events (consumer workloads like `jitML`)
- sequence-model state: LLM conversation context, AlphaZero move history, RL trajectories
- orchestrator-to-worker control envelopes (fan-out batches, drain signals)
- worker-to-orchestrator status (readiness, completion, failure)

Substrate-owned envelopes are always protobuf. Consumer payloads carried inside
`WorkflowEvent.inline_bytes` (or referenced via `WorkflowEvent.object_ref`) are opaque to
substrate; consumers choose the encoding that fits their workload. See
[`../reference/proto_surface.md`](../reference/proto_surface.md).

**Pulsar is also the public ingress.** Upstream callers of the overall compute workflow
publish their workflow events directly to the orchestrator's fan-in topic. The substrate
exposes no separate HTTP / gRPC / REST surface for upstream callers — Pulsar is the
public interface. Consumers may layer an HTTP frontend in their own code if they want one,
but that is consumer-owned, not substrate-owned.

### MinIO (static blob SSoT)

MinIO holds the large, content-addressable artifacts that a workload references:

- model weights — original (hydrated from the WAN by the Orchestrator) and derived
  (post-training checkpoints, fine-tuned variants)
- datasets — training, evaluation, fine-tuning corpora
- large input / output artifacts — images, audio, video, generated media
- training checkpoints (jitML carries an extensive specification for this; the substrate
  generalizes it)

MinIO objects are immutable once written. Updates produce a new key, never an in-place mutation.
Atomic pointer updates use CAS (`If-Match`) against the pointer object's ETag.

## The reference pattern

When a Pulsar message needs to refer to a MinIO blob, the message carries an `ObjectRef`
(bucket + key). The receiver reads the blob from MinIO at the URL the reference resolves to.

A pseudo-protobuf:

```proto
message ObjectRef {
  string bucket = 1;
  string key    = 2;
  string etag   = 3;   // optional; for explicit version pinning
}
```

The receiver MUST treat the blob as authoritative if and only if its ETag matches the reference
(when the reference pins a version). A cached copy is allowed for performance, but the cache is
never the authority — see [daemon_roles.md § Ephemeral cache](daemon_roles.md#ephemeral-cache).

## Large-blob handoff

Placement is by the **nature** of the payload, not its size. Static binary artifacts — model
weights, image / audio / video, large training tensors — flow as `WorkflowEvent.object_ref`
*because of what they are*, at any size: they have a lifecycle (retention, archival, sweep),
are content-addressable (dedup by ETag), and have no business sitting in broker backlog. The
**producer** makes that choice and publishes an `ObjectRef`; the substrate stays payload-blind
and never inspects bytes to second-guess it. The receiver may opt into transparent
materialization via `Daemon.MinIO.Store.readBlob` so that handler code sees the bytes back
in-memory without explicit fetch.

Size is a separate concern, enforced as a **broker guard rail** — not a router. The substrate
caps inline-payload size at `BootConfig.maxInlinePayloadBytes` (default 1048576 = 1 MiB;
tunable per cohort) and **fails closed at publish time** with a typed error
(`InlinePayloadTooLarge`) when a producer hands it an over-max `inline_bytes`. It does **not**
silently `putBlob` and rewrite the envelope — placement is the producer's decision, so an
over-max inline payload is a producer bug, surfaced loudly and locally rather than papered over.

Rationale: multimodal inference (`infernix` accepting image / audio / video as inputs *and*
producing them as outputs) and large training tensors (`jitML`) would otherwise create giant
Pulsar payloads with no lifecycle, no dedup, and broker memory pressure — which is why those
artifacts ride in MinIO by nature, letting `BucketLifecycle` be the single declarative surface
for how long a transient payload sticks around. The guard rail covers the residual case
type-based placement does not: legitimately-large *message-shaped* in-motion state (LLM
conversation context, RL trajectories, large batched envelopes) is not a static artifact, so it
stays inline, yet can still stress broker memory and replication. The cap (and ultimately
Pulsar's own `maxMessageSize`) bounds it, and a substrate-level publish-time check is a far
better failure surface than a broker-level rejection deeper in the stack.

Substrate-owned envelopes (`WorkflowEvent`, `OrchestratorToWorker`, `WorkerResult`,
`AuditEvent`) themselves stay small — they are message-shaped by design. The threshold
applies only to the consumer payload carried inside `WorkflowEvent.payload`.

## Substrate-owned Pulsar abstractions

The substrate ships three layered Pulsar abstractions; consumers compose them rather than
writing raw Pulsar client code. All three sit on the in-process native-protocol client
(`Daemon.Pulsar.Native`), which talks the Pulsar binary protocol directly to the owner broker
over TCP — so the "low-latency fan-out" the split relies on is realized by a direct binary-wire
connection, not a WebSocket-proxy hop. See
[../engineering/pulsar_native_client.md](../engineering/pulsar_native_client.md).

1. **Envelope layer** — `WorkflowEvent` and friends in [../reference/proto_surface.md](../reference/proto_surface.md);
   `Daemon.Wire.*` ADTs in application code.
2. **Topology layer** — typed builders for `RequestResponse`, `FanOut`, `BatchedFanOut`,
   `FanIn`, `BatchedFanIn`, `Pipeline`, `Stream`; see
   [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md).
3. **Batching layer** — the in-cluster orchestrator's substrate-owned batcher + multi-bucket
   scheduler, configured via `BatchingPolicy` + `SchedulerPolicy` (Dhall in `LiveConfig`) and
   `BatchingHooks` (consumer combinability predicate + bucket key); see
   [../engineering/batching.md](../engineering/batching.md).

Consumer-owned payload schemas live in the consumer's own repository, addressed via the
`payload_type` URL prefix routed by `Daemon.Consumer.HandlerRouter`. Substrate does not
mediate the schema; it routes by URL.

## Reference scaffolding: how the split serves the three workflow archetypes

The Pulsar/MinIO split is the scaffolding `infernix` and `jitML` build on, and it carries the
three ML workflow archetypes the substrate is the reference for:

- **(a) Continuous batched inference** (≈ `infernix`) — requests and results ride Pulsar;
  model weights and large media inputs/outputs ride MinIO as `ObjectRef`; conversation /
  sequence state stays on Pulsar.
- **(b) Finite SL / offline-RL training jobs** (≈ `jitML`) — training commands and per-step
  events ride Pulsar; datasets and checkpoints ride MinIO. The run terminates and exports its
  final checkpoint to MinIO.
- **(c) Continuous online RL** — new weights are written to MinIO and their availability is
  **announced on the Pulsar inference topics**; training and inference task messages are
  distinct on Pulsar and route by `payload_type` URL prefix to the same or separate stateless
  engines. Pulsar carries the announcement and the routing; MinIO carries the weights.

In every archetype Pulsar stays the workflow SSoT and MinIO stays the static-blob SSoT; the
archetype only changes which topics and buckets the consumer declares.

## Anti-patterns

- **Putting workflow state in MinIO.** Workflow events go to Pulsar. MinIO doesn't carry "the
  current state of conversation X"; the conversation event log on Pulsar does.
- **Putting large blobs in Pulsar.** Pulsar payloads stay message-shaped (bounded, small). Large
  blobs ride in MinIO, referenced from a small Pulsar message.
- **Treating a local cache as authoritative.** A Worker's `.cache/` or `emptyDir` exists for
  speed; losing it is never a data-loss event.
- **In-place MinIO mutations of an existing key.** Always write to a new key; update a pointer
  object with CAS to make the change visible.

## Crash recovery

The split exists precisely so that recovery is mechanical. On daemon restart:

1. Re-read Dhall config (slowly-changing, on disk).
2. Re-subscribe to Pulsar topics; replay any unacknowledged messages.
3. Refetch any referenced MinIO blobs on demand.

There is no other authoritative state to rebuild. See the
[daemon_roles.md](daemon_roles.md) statelessness sections for Worker and Orchestrator.

## Cross-references

- Topic inventory for the test harness: [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md)
- Bucket inventory for the test harness: [../engineering/minio_buckets.md](../engineering/minio_buckets.md)
- How consumers wire their own topics and buckets: [library_consumption_model.md](library_consumption_model.md)
- Envelope schema (`WorkflowEvent`, `WorkflowKind`, `payload` oneof, `ObjectRef`): [../reference/proto_surface.md](../reference/proto_surface.md)
- Topology primitives: [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md)
- Batching and scheduling: [../engineering/batching.md](../engineering/batching.md)
- Lifecycle of topics and buckets: [lifecycle_policy.md](lifecycle_policy.md)
