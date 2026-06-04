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
(`Daemon.Sub`, landed in Phase 1) — this covers MinIO (`curl`), Harbor (`docker` / `curl`),
Kubectl (`kubectl`), and `SubprocessEngine`. **Pulsar is the one deliberate exception:** both
its data plane (native binary protocol) and its admin plane (admin REST) run in-process, since
Pulsar sits on the substrate's deadline-sensitive hot path and a subprocess / proxy hop on that
path is exactly the latency the substrate cannot afford. The in-process Pulsar client still
obeys the configuration doctrine — broker endpoints come from typed config, never the
environment or a `$PATH`-resolved command (see
[`development_plan_standards.md` § M](development_plan_standards.md)).

`HasEngine` does **not** land here — it lands in Phase 4 alongside the mock engine and
protobuf envelopes.

## Sprints

### Sprint 2.1: `HasPulsar` typeclass + subprocess + filesystem impls [Planned]

**Status**: Planned
**Docs to update**: `documents/engineering/pulsar_native_client.md` (new),
`documents/engineering/pulsar_topics.md`, `documents/engineering/cabal_layout.md`,
`documents/reference/proto_surface.md`, `system-components.md`

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
- `Daemon.Pulsar.Native` — production **in-process** implementation speaking Pulsar's native
  binary protocol over TCP (port 6650). It does **not** go through `Daemon.Sub`: there is no
  subprocess, no Node runtime, and no WebSocket proxy hop. A single multiplexed TCP connection
  per owner broker carries every producer and consumer, request/response correlated by
  `request_id`. See [`../documents/engineering/pulsar_native_client.md`](../documents/engineering/pulsar_native_client.md)
  for the framing, command set, connection model, and the rationale for choosing the native
  protocol over the WebSocket gateway.

#### Deliverables

- `src/Daemon/Pulsar.hs` populated (typeclass + types)
- `src/Daemon/Pulsar/Native.hs` populated (production `HasPulsar` instance), with internal
  sub-modules `Native/Frame.hs` (wire framing), `Native/Connection.hs` (multiplexed TCP
  connection + `CONNECT` handshake + `PING`/`PONG` keepalive), `Native/Lookup.hs` (topic
  `LOOKUP` + partitioned-topic metadata), `Native/Producer.hs`, `Native/Consumer.hs`, and
  `Native/Compression.hs` (optional, default `NONE`)
- `proto/PulsarApi.proto` vendored (the Pulsar wire-protocol schema; compiled by the existing
  `proto-lens-protoc` step into `Daemon.Proto.PulsarApi`)
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
- production implementation `Daemon.Pulsar.Admin.Http` — an **in-process** HTTP client
  (`http-client` + `http-client-tls`) against the broker admin REST API (port 8080); no
  `pulsar-admin` CLI and no `Daemon.Sub` shell-out
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
- `documents/engineering/pulsar_native_client.md` (new) — canonical contract for
  `Daemon.Pulsar.Native`: wire framing, command set, connection / multiplexing model,
  `LOOKUP` / partitioned-topic handling, send-batching / flow-control / ack semantics,
  compression policy, typed config fields, and the native-vs-WebSocket rationale.
- `documents/engineering/pulsar_topics.md` updates the inventory rows for admin / audit /
  leader-control topics from "planned" to current-state declarative.
- `documents/engineering/cabal_layout.md` adds the native-client dependencies (`network`,
  `http-client` / `http-client-tls`, optional `tls`) and the vendored `PulsarApi.proto`
  generation.
- `documents/engineering/minio_buckets.md` updates the bucket layout (`blobs/`, `manifests/`,
  `pointers/`, `archives/`) from "planned" to current-state declarative; orphan-scan
  description reads as the implemented behavior.

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_policy.md` updates the "Library modules" section as
  `Daemon.Pulsar.Admin` and `Daemon.MinIO.Admin` land.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` gains a note that `proto/PulsarApi.proto` is vendored
  in this phase as the Pulsar wire-protocol schema — distinct from the substrate-owned
  `proto/daemon_substrate/*` envelopes, which still land in Phase 4.

**Cross-references to add:**
- `system-components.md` flips the relevant typeclass and admin rows to `Implemented: yes`
  as sprints close.
