# Phase 2: Capability Typeclasses + Admin Surfaces

**Status**: Authoritative source
**Supersedes**: `phase-2-typeclasses-pulsar-minio-engine.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-library-scaffolding-and-cabal-package.md](phase-1-library-scaffolding-and-cabal-package.md), [phase-3-bootconfig-liveconfig-lifecycle.md](phase-3-bootconfig-liveconfig-lifecycle.md)

> **Purpose**: Land the four substrate-plumbing typeclasses (`HasPulsar`, `HasMinIO`,
> `HasHarbor`, `HasKubectl`), their subprocess-backed real implementations and
> filesystem-backed test implementations, the generic content-addressed `Daemon.MinIO.Store`,
> and the typed admin surfaces (`Daemon.Pulsar.Admin`, `Daemon.MinIO.Admin`) that the
> reconciler will drive in Phase 5.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 1
**Implementation**: none yet

## Phase Objective

Bring the substrate's transport / cluster-I/O surface into existence so the lifecycle
scaffolding in Phase 3 and the base loops in Phase 5 have a typed seam to dispatch through.
Every shell-out the library performs goes through one typed `Subprocess` boundary
(`Daemon.Sub`, landed in Phase 1).

`HasEngine` does **not** land here — it lands in Phase 4 alongside the mock engine and
protobuf envelopes.

## Sprints

### Sprint 2.1: `HasPulsar` typeclass + subprocess + filesystem impls [Planned]

**Status**: Planned
**Docs to update**: `documents/engineering/pulsar_topics.md`, `system-components.md`

#### Objective

Define `Daemon.Pulsar.HasPulsar` (`pulsarPublish`, `pulsarSubscribe`, `pulsarConsume`,
`pulsarAcknowledge`, `pulsarNegativeAcknowledge`, `pulsarSeek`) and `SubscriptionMode`
(`Shared`, `KeyShared`, `Exclusive`, `Failover`). All four variants are part of the public
typeclass surface; `KeyShared` and `Exclusive` are exposed for consumer use (e.g. `infernix`
context-affine LLM inference; see
[`../documents/engineering/pulsar_topics.md`](../documents/engineering/pulsar_topics.md))
but are not exercised by the test-harness integration suite because the mock engine is
stateless across requests and affinity provides no benefit. Sprint deliverables cover
`Shared` and `Failover` end-to-end; `KeyShared` and `Exclusive` are covered by unit tests
against `Daemon.Test.FilesystemPulsar` only.

Ship two implementations:

- `Daemon.Test.FilesystemPulsar` — in-process implementation backed by an in-memory ledger
  (used for unit tests).
- `Daemon.Pulsar.WebSocketSubprocess` — production implementation driving a Node-WebSocket
  client via the `Daemon.Sub` typed-subprocess boundary.

#### Deliverables

- `src/Daemon/Pulsar.hs` populated (typeclass + types)
- `src/Daemon/Pulsar/WebSocketSubprocess.hs` populated
- `src/Daemon/Test/FilesystemPulsar.hs` populated
- unit tests covering: publish→consume, ack, negative-ack, seek, dedup-window behavior,
  Exclusive-rejects-second-subscriber

#### Validation

`cabal test daemon-substrate-unit` exercises every method against the filesystem
implementation; integration coverage of the subprocess implementation lands in Phase 8.

### Sprint 2.2: `Daemon.Pulsar.Admin` typed admin surface [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Define `Daemon.Pulsar.Admin` with typed operations: `createTopic`, `deleteTopic`,
`terminateTopic`, `setRetention`, `setCompaction`, `setDedupWindow`, `listTopics`,
`exportTopicToObject`, `importTopicFromObject`. Each operation is idempotent (creates swallow
already-exists, set-ops are set-not-add). Implement against both filesystem and subprocess
backends.

#### Deliverables

- `src/Daemon/Pulsar/Admin.hs` populated
- filesystem implementation extending `Daemon.Test.FilesystemPulsar`
- subprocess implementation invoking `pulsar-admin` via `Daemon.Sub`
- unit tests covering idempotency (run create twice → no error, no churn) and audit-shaped
  return values

#### Validation

`cabal test daemon-substrate-unit` covers idempotency on every admin op.

### Sprint 2.3: `HasMinIO` + Cache + Store [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `documents/engineering/minio_buckets.md`,
`documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Define `Daemon.MinIO.HasMinIO` (`minioGet`, `putBlobIfAbsent`, `casPointer`, `listObjects`,
`deleteObject`). Define `Daemon.MinIO.Cache` with `readWithCache` plus an explicit pin API:

```haskell
pin       :: HasMinIO m => ObjectRef -> m ()
unpin     :: HasMinIO m => ObjectRef -> m ()
isPinned  :: HasMinIO m => ObjectRef -> m Bool
```

The cache enforces a quota plus LRU/TTL eviction but never evicts a pinned ref. The pin set
is process-local and non-durable. Required by `infernix`'s hot-model cache (currently-served
models must not be reclaimed mid-request) and useful for `jitML`'s active-experiment
checkpoints. See [`../documents/architecture/lifecycle_policy.md`](../documents/architecture/lifecycle_policy.md)
`## Library modules`.

Define `Daemon.MinIO.Store` — the generic content-addressed store
(`putBlob` / `putManifest` / `casPointer` / `readBlob` / `readManifest`) jitML's checkpoint
store today implements directly.

Ship two implementations:

- `Daemon.Test.FilesystemMinIO` — filesystem-backed (used for unit tests).
- `Daemon.MinIO.Subprocess` — production implementation invoking `curl` with SigV4 headers
  via `Daemon.Sub`.

#### Deliverables

- `src/Daemon/MinIO.hs`, `src/Daemon/MinIO/Cache.hs`, `src/Daemon/MinIO/Store.hs` populated
  (cache module exports `pin` / `unpin` / `isPinned`)
- both implementations populated
- unit tests covering: put / get round-trip, `If-None-Match: *` semantics, `If-Match` CAS
  success and failure, cache cold path, cache warm path, cache eviction (eviction triggers
  on non-pinned set under quota pressure), pin survives eviction-pressure cycles, unpin
  allows eviction to reclaim, `isPinned` round-trip, store-level blob / manifest / pointer
  round-trips

#### Validation

`cabal test daemon-substrate-unit` exercises every method.

### Sprint 2.4: `Daemon.MinIO.Admin` typed bucket admin [Planned]

**Status**: Planned
**Blocked by**: 2.3
**Docs to update**: `documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Define `Daemon.MinIO.Admin` with `createBucket`, `setBucketLifecycle`, `listBuckets`,
`listObjectsByPrefix`, `deleteObject`. Idempotent on every op. Filesystem + subprocess impls.

#### Deliverables

- `src/Daemon/MinIO/Admin.hs` populated
- filesystem implementation extending `Daemon.Test.FilesystemMinIO`
- subprocess implementation invoking `curl` with S3 bucket-admin endpoints
- unit tests covering idempotency

### Sprint 2.5: `HasHarbor` typeclass + subprocess + filesystem impls [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `system-components.md`

#### Objective

Define `Daemon.Harbor.HasHarbor` (`harborImageExists`, `harborPushImage`, `harborPullImage`,
`harborListImages`). Filesystem impl backed by an in-memory image map; subprocess impl
invoking `docker` + `curl` against Harbor's API.

#### Deliverables

- `src/Daemon/Harbor.hs` populated
- both implementations populated
- unit tests covering existence checks, push idempotency, list semantics

### Sprint 2.6: `HasKubectl` typeclass + subprocess + filesystem impls [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `system-components.md`

#### Objective

Define `Daemon.Kubectl.HasKubectl` (`kubectlApply`, `kubectlStatus`, `kubectlGet`,
`kubectlDelete`). Filesystem impl backed by an in-memory resource map; subprocess impl
invoking `kubectl` with `KUBECONFIG` set.

#### Deliverables

- `src/Daemon/Kubectl.hs` populated
- both implementations populated
- unit tests covering apply idempotency, status reporting, get/delete round-trip

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/pulsar_topics.md` updates the inventory rows for admin / audit /
  leader-control topics from "planned" to current-state declarative.
- `documents/engineering/minio_buckets.md` updates the bucket layout (`blobs/`, `manifests/`,
  `pointers/`, `archives/`) from "planned" to current-state declarative; orphan-scan
  description reads as the implemented behavior.
- `documents/engineering/cabal_layout.md` updates with the proto code-gen wiring (proto-lens
  build-tool-depends).

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_policy.md` updates the "Library modules" section as
  `Daemon.Pulsar.Admin` and `Daemon.MinIO.Admin` land.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` does not change in this phase (proto schemas land in
  Phase 4).

**Cross-references to add:**
- `system-components.md` flips the relevant typeclass and admin rows to `Implemented: yes`
  as sprints close.
