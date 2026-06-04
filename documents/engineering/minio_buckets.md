# MinIO Buckets (Test Harness)

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [cluster_topology.md](cluster_topology.md), [mock_engine.md](mock_engine.md)

> **Purpose**: Inventory the MinIO buckets the test harness uses, what each holds, who writes
> and reads them, and the content shape of the mock blobs.

## TL;DR

- Three buckets: `daemon-substrate-test-weights` (mock model weights), `daemon-substrate-test-artifacts`
  (mock binary I/O artifacts), and `daemon-substrate-test-archives` (Pulsar topic archives
  for `ContinuousWithArchive` / `FiniteSession` / `OnlineLearning` test cases).
- All blobs are tiny, content-addressable, and seeded deterministically by the test harness
  bootstrap. Total bucket footprint stays under a few MB.
- Workers read from `weights` and `artifacts` via `HasMinIO`. The orchestrator writes the seed
  objects during cluster bring-up as part of its WAN→MinIO hydration role (here simulated,
  not real). Later result-output paths may write tiny artifacts for `ObjectRef` coverage. The
  reconciler manages buckets + orphan-scan per the
  [`LifecyclePolicy`](../architecture/lifecycle_policy.md).

## Current Status

Phase 2 has landed `HasMinIO`, `Daemon.MinIO.Cache`, `Daemon.MinIO.Store`,
`Daemon.MinIO.Admin`, and `Daemon.Test.FilesystemMinIO`. Current unit validation covers
put/get, put-if-absent, pointer CAS, content-addressed blob round-trip, cache cold path,
LRU-style quota eviction, pin survival under eviction pressure, bucket creation, and prefix
listing. `Daemon.MinIO.Subprocess` is a concrete `curl`-backed implementation through
`Daemon.Sub`; it carries typed SigV4 credential fields and renders them to curl's
`--aws-sigv4` / `-u` arguments without reading environment state. The live admin path treats
HTTP 409 bucket creation as no-change, configures bucket lifecycle with S3 XML plus a
checksum header, and parses S3 list-object XML for prefix scans.

## Bucket inventory

| Bucket | Purpose | Writer | Reader | Approx. size |
|--------|---------|--------|--------|--------------|
| `daemon-substrate-test-weights` | mock model "weights" (content-addressed `blobs/`, `manifests/`, `pointers/`) | orchestrator (seed at startup); reconciler (orphan-scan target) | worker (per request) | < 1 MB |
| `daemon-substrate-test-artifacts` | mock binary input / output artifacts for `ObjectRef` coverage | orchestrator (seeds inputs); later output paths | both | < 1 MB |
| `daemon-substrate-test-archives` | Pulsar topic archives (`archives/<topic>/<startTime>-<endTime>.archive`) | reconciler (`ContinuousWithArchive` export) | integration tests (read for assertions) | varies; capped by `archiveRetentionDays` |

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

The mock engine loads one of these per `MockRequest.weight_bucket` / `MockRequest.weight_key`.
The actual bytes are never inspected; they exist to exercise the fetch path and the local
cache.

### `daemon-substrate-test-artifacts`

| Key prefix | Purpose |
|------------|---------|
| `mock/input/<request-id>` | seeded by the orchestrator when a test chooses an `object_ref` input payload |
| `mock/output/<request-id>` | reserved for later output-object paths that exercise `WorkerResult.success.output_object` |

Artifacts are tiny deterministic byte blobs. They exist to exercise the `ObjectRef` reference
flow without turning MinIO into workflow state.

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

- `pointers/<key>` lists the current set of weight keys
- the orchestrator updates the pointer with `If-Match` against the previous ETag
- two simultaneous orchestrator writers would see one succeed and one fail with `412
  Precondition Failed` — the harness asserts this guarantee in the integration suite

No in-place mutations of existing keys. Updates always produce a new key; the pointer is the
only mutable thing.

## Orphan scan (mark-and-sweep)

`daemon-substrate-test-weights` is the canonical orphan-scan target. The reconciler runs the
scan on the cadence declared by `BucketLifecycle.orphanScan`. The harness uses a tight
`safetyWindowMin = 30 seconds` (vs the substrate default of 60 minutes) so tests can exercise
expiration. Algorithm:

1. Read every object in `pointers/`. Each pointer body names a manifest content-hash.
2. Read each named manifest from `manifests/`. Collect every blob hash referenced.
3. List `blobs/` and `manifests/`. Any object not in the reachable set AND whose
   `LastModified` is older than `now - safetyWindowMin` is hard-deleted.
4. Every delete publishes to `audit.reconcile.daemon-substrate-test` keyed by the object key.

The integration suite asserts both directions: (a) an object older than the safety window and
unreachable is deleted; (b) an object younger than the safety window is never deleted, even if
unreachable. See [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md).

## Sizing

The harness is intentionally storage-light. Total MinIO footprint after seeding is well under
2 MB. Per-request churn is bounded (one output object per request, capped by request count).
The kind cluster's MinIO pod can run with a small `emptyDir` or a trivially-sized PVC.

## Cross-references

- Pulsar/MinIO split: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md)
- Cluster bring-up that seeds these buckets: [cluster_topology.md](cluster_topology.md)
- Mock engine behavior: [mock_engine.md](mock_engine.md)
