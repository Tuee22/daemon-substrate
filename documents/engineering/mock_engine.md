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
- It performs real reads from MinIO (mock weight blobs), real writes to MinIO (mock output
  artifacts), and real reads/writes against the worker's local cache. None of these payloads
  are large.
- It is **not** an ML model. There is no math, no inference, no training, no GPU work. The
  engine exists only to validate the substrate, not the consumers' workloads.

## What the mock engine does

Given a `MockRequest` envelope:

```proto
message MockRequest {
  string request_id    = 1;
  string weight_key    = 2;  // points at daemon-substrate-test-weights bucket
  bool   write_output  = 3;  // if true, engine writes to daemon-substrate-test-artifacts
  bool   force_failure = 4;  // if true, engine returns EngineError for retry-path testing
  int64  cache_hint    = 5;  // optional: causes a cache lookup before MinIO read
}
```

The engine:

1. Reads `mock/v1/<weight_key>` from `daemon-substrate-test-weights` via `HasMinIO`. On cold
   path, fetches from MinIO; on warm path, hits the local cache via `Daemon.MinIO.Cache`.
2. If `force_failure` is `true`, returns `EngineNativeError "mock forced failure"` so the
   worker's negative-ack path can be exercised.
3. Computes a placeholder result: SHA-256 of `(request_id || weight bytes)`, truncated to 32
   bytes. This is deterministic, exercises the byte path, and produces nothing meaningful.
4. If `write_output` is `true`, writes a 128-byte JSON-shaped placeholder to
   `mock/output/<request_id>` in `daemon-substrate-test-artifacts`. Includes the placeholder
   result hash and the source weight key for traceability.
5. Returns a `MockResult` envelope:

```proto
message MockResult {
  string request_id    = 1;
  bytes  result_hash   = 2;  // the 32-byte placeholder
  ObjectRef output_ref = 3;  // present only if write_output was true
  int64  weight_bytes  = 4;  // length of the weight blob read (for assertion)
  bool   cache_hit     = 5;  // whether the weight came from cache
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
- the output JSON includes only request_id and result_hash; no timestamps, no random IDs, no
  locale-dependent ordering

Integration tests assert exact result bytes when needed; this lets the harness pin down
regressions in the substrate's request/response plumbing without flake.

## Cross-references

- What goes on Pulsar between worker and orchestrator: [pulsar_topics.md](pulsar_topics.md)
- What blobs the engine reads and writes: [minio_buckets.md](minio_buckets.md)
- Worker role contract: [../architecture/daemon_roles.md § Worker](../architecture/daemon_roles.md#worker)
- Test invocation: [../development/testing_strategy.md](../development/testing_strategy.md)
