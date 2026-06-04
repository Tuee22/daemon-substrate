# Mock Engine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [pulsar_topics.md](pulsar_topics.md), [minio_buckets.md](minio_buckets.md), [cluster_topology.md](cluster_topology.md), [../development/testing_strategy.md](../development/testing_strategy.md)

> **Purpose**: Define exactly what the test harness's mock worker engine does and (explicitly)
> what it does not. The mock engine exists to exercise the substrate's transport, lifecycle,
> and cache plumbing without any real ML cost.

## TL;DR

- The mock engine implements `HasEngine` with a `NativeEngine` variant that returns
  deterministic placeholder bytes per `MockRequest`.
- It performs real reads from MinIO (mock weight blobs) and real reads/writes against the
  worker's local cache. None of these payloads are large.
- It is **not** an ML model. There is no math, no inference, no training, no GPU work. The
  engine exists only to validate the substrate, not the consumers' workloads.

## Current Status

`Daemon.Test.MockEngine` is implemented. It exposes `MockEngine`, `mockNativeEngine`,
`mockResult`, and `mockResultPayload`. `mockNativeEngine` is a `NativeEngine` whose
`EngineRequest` payload is an encoded `MockRequest`; successful responses carry an encoded
`MockResult` in `EngineResponse.engineResponsePayload`. Unit coverage exercises singleton
batches, multi-element batches, mixed success/failure batches, and cache cold/warm behavior.

## What the mock engine does

Given a `MockRequest` envelope:

```proto
message MockRequest {
  string request_id     = 1;
  string weight_bucket  = 2;  // usually daemon-substrate-test-weights
  string weight_key     = 3;  // object key inside weight_bucket
  bool   force_failure  = 4;  // if true, engine returns EngineError for retry-path testing
  bytes  input_payload  = 5;  // opaque test payload mixed into the deterministic result
}
```

The engine:

1. Reads `<weight_key>` from `<weight_bucket>` via `HasMinIO`. On cold
   path, fetches from MinIO; on warm path, hits the local cache via `Daemon.MinIO.Cache`.
2. If `force_failure` is `true`, returns `EngineRequestFailed "mock forced failure"` so the
   worker's negative-ack path can be exercised.
3. Computes a placeholder result: SHA-256 of `(request_id || input_payload || weight_blob)`,
   truncated to 32 bytes. This is deterministic, exercises the byte path, and produces nothing
   meaningful. The hash domain is exactly those bytes in that order, with no separator.
4. Returns a `MockResult` envelope:

```proto
message MockResult {
  string request_id      = 1;
  bytes  result_payload  = 2;  // the 32-byte placeholder
}
```

The worker wraps `MockResult` in the substrate-owned `WorkerResult` envelope and publishes to
`test.result`.

## What the mock engine does not do

- **No ML.** No tensor operations, no matrix multiplies, no model loading in any meaningful
  sense.
- **No GPU.** It does not call CUDA, Metal, or any accelerator API. It runs purely on CPU.
- **No subprocess.** The mock engine is implemented as `NativeEngine` (in-process), not
  `SubprocessEngine`. The `SubprocessEngine` variant is exercised separately by a unit test
  with a trivial echo subprocess, not by the integration harness.
- **No persistent state.** Each request is independent. The engine carries no per-request
  history, no KV cache, no replay buffer.
- **No WAN access.** The engine never reaches outside the cluster. Mock weights are seeded
  into MinIO by the orchestrator during `cluster up`.

## Why a mock and not a real engine

The substrate's job is to be substrate. Validating it with a real ML engine would couple every
substrate test to a model download, a GPU runtime, and inference correctness — none of which
the substrate is responsible for. A mock keeps the harness fast, deterministic, and focused on
what the substrate actually owns: transport, lifecycle, cache, and SSoT discipline.

`infernix` and `jitML` validate against their own real engines on their own model matrices.
That is their cohort obligation, not the substrate's. See
[`../../DEVELOPMENT_PLAN/development_plan_standards.md` § P](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Determinism

Every aspect of the mock engine is deterministic given the request inputs and the seeded
MinIO content:

- weights are deterministic byte patterns (see [minio_buckets.md](minio_buckets.md))
- the result hash is SHA-256 of inputs
- the result payload includes only the deterministic hash bytes; no timestamps, no random IDs,
  no locale-dependent ordering

Integration tests assert exact result bytes when needed; this lets the harness pin down
regressions in the substrate's request/response plumbing without flake.

## Cross-references

- What goes on Pulsar between worker and orchestrator: [pulsar_topics.md](pulsar_topics.md)
- What blobs the engine reads and writes: [minio_buckets.md](minio_buckets.md)
- Worker role contract: [../architecture/daemon_roles.md § Worker](../architecture/daemon_roles.md#worker)
- Test invocation: [../development/testing_strategy.md](../development/testing_strategy.md)
