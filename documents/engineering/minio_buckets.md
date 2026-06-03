# MinIO Buckets (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [cluster_topology.md](cluster_topology.md), [mock_engine.md](mock_engine.md)

> **Purpose**: Inventory the MinIO buckets the test harness uses, what each holds, who writes
> and reads them, and the content shape of the mock blobs.

## TL;DR

- Two buckets: `daemon-substrate-test-weights` (mock model weights) and
  `daemon-substrate-test-artifacts` (mock binary I/O artifacts).
- All blobs are tiny, content-addressable, and seeded deterministically by the test harness
  bootstrap. Total bucket footprint stays under a few MB.
- Workers read from both buckets via `HasMinIO`. The orchestrator writes the seed objects
  during cluster bring-up as part of its WAN→MinIO hydration role (here simulated, not real).

## Bucket inventory

| Bucket | Purpose | Writer | Reader | Approx. size |
|--------|---------|--------|--------|--------------|
| `daemon-substrate-test-weights` | mock model "weights" | orchestrator (seed at startup) | worker (per request) | < 1 MB |
| `daemon-substrate-test-artifacts` | mock binary input / output artifacts | worker (writes outputs); orchestrator (seeds inputs) | both | < 1 MB |

Both buckets are pre-created by the kind cluster bring-up flow (see
[cluster_topology.md](cluster_topology.md) § MinIO).

## Seed contents

### `daemon-substrate-test-weights`

Three deterministic mock weight objects:

| Key | Content | ETag (sha256) |
|-----|---------|---------------|
| `mock/v1/small.bin` | 1 KiB of `0xAA`-filled bytes | deterministic |
| `mock/v1/medium.bin` | 16 KiB of `0xBB`-filled bytes | deterministic |
| `mock/v1/large.bin` | 256 KiB of `0xCC`-filled bytes | deterministic |

The mock engine "loads" one of these per `MockRequest` based on a field in the request. The
actual bytes are never inspected; they exist to exercise the fetch path and the local cache.

### `daemon-substrate-test-artifacts`

| Key prefix | Purpose |
|------------|---------|
| `mock/input/<request-id>` | seeded by the orchestrator on request fan-out when the request includes an "input artifact" flag |
| `mock/output/<request-id>` | written by the worker when the mock engine indicates it produced an output |

Outputs are also tiny (128 bytes of zero-padded JSON-like content). They exist to exercise the
write path and the `ObjectRef` reference flow in `WorkerResult`.

## Authoritative vs cached reads

Workers may cache fetched objects locally per [daemon_roles.md § Ephemeral
cache](../architecture/daemon_roles.md#ephemeral-cache). The cache is wrapped through
`Daemon.MinIO.Cache.readWithCache`, which always treats MinIO as the authoritative source on a
cache miss and never serves cached bytes as authoritative.

The harness exercises:

- cold path: worker starts with empty cache, fetches from MinIO, populates cache
- warm path: worker re-fetches the same key, serves from cache
- invalidation: orchestrator overwrites a weight blob (with a new key under `mock/v2/`),
  publishes a request that references the new key, worker fetches it (cache miss for the new
  key, hit for the old)
- eviction: cache is capped at 64 KiB by harness config so the `large.bin` fetch forces
  eviction of smaller entries

## CAS semantics

Pointer objects use ETag-based CAS:

- `mock/v1/manifest.json` (or equivalent) lists the current set of weight keys
- the orchestrator updates the manifest with `If-Match` against the previous ETag
- two simultaneous orchestrator writers would see one succeed and one fail with `412
  Precondition Failed` — the harness asserts this guarantee in the integration suite

No in-place mutations of existing keys. Updates always produce a new key; the manifest pointer
is the only mutable thing.

## Sizing

The harness is intentionally storage-light. Total MinIO footprint after seeding is well under
2 MB. Per-request churn is bounded (one output object per request, capped by request count).
The kind cluster's MinIO pod can run with a small `emptyDir` or a trivially-sized PVC.

## Cross-references

- Pulsar/MinIO split: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md)
- Cluster bring-up that seeds these buckets: [cluster_topology.md](cluster_topology.md)
- Mock engine behavior: [mock_engine.md](mock_engine.md)
