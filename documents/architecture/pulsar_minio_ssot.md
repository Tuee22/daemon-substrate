# Pulsar and MinIO Source-of-Truth Split

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [daemon_roles.md](daemon_roles.md), [library_consumption_model.md](library_consumption_model.md), [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md), [../engineering/minio_buckets.md](../engineering/minio_buckets.md)

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

Payloads are always protobuf. JSON / CBOR / Aeson are not part of the supported contract.

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
