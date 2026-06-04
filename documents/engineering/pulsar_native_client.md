# Native Pulsar Client

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md), [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [pulsar_topics.md](pulsar_topics.md), [cabal_layout.md](cabal_layout.md), [../reference/proto_surface.md](../reference/proto_surface.md), [../../DEVELOPMENT_PLAN/phase-2-capability-typeclasses-and-admin-surfaces.md](../../DEVELOPMENT_PLAN/phase-2-capability-typeclasses-and-admin-surfaces.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define the production Pulsar client — an **in-process, pure-Haskell**
> implementation that speaks Pulsar's native binary protocol over TCP for the data plane and the
> admin REST API for the admin plane — its wire contract, connection model, performance
> properties, configuration, and the rationale for choosing it over the WebSocket gateway.

## TL;DR

- The production `HasPulsar` instance is `Daemon.Pulsar.Native`: it talks Pulsar's
  [native binary protocol](https://pulsar.apache.org/docs/next/developing-binary-protocol/)
  over a raw TCP socket (port 6650), **in-process**, with no subprocess, no Node runtime, and no
  WebSocket-proxy hop.
- The production `Daemon.Pulsar.Admin` instance is `Daemon.Pulsar.Admin.Http`: an in-process
  HTTP client against the broker admin REST API (port 8080).
- This is the one deliberate exception to the `Daemon.Sub` subprocess boundary
  (MinIO / Harbor / Kubectl / `SubprocessEngine` still shell out). Pulsar is on the substrate's
  deadline-sensitive hot path, and a process/proxy hop there is exactly the latency the substrate
  cannot afford. See [../../DEVELOPMENT_PLAN/development_plan_standards.md § M](../../DEVELOPMENT_PLAN/development_plan_standards.md).
- The client is behind the `HasPulsar` / `Daemon.Pulsar.Admin` typeclasses, so neither consumer
  code nor `Daemon.Test.FilesystemPulsar` changes when the implementation does.

## Current Status

Phase 2 has landed the public `HasPulsar` and `Daemon.Pulsar.Admin` typeclass surfaces plus
`Daemon.Test.FilesystemPulsar`, which owns current unit validation for publish / consume /
ack / nack / seek, dedup keys, Exclusive-subscription rejection, and admin idempotency.

`Daemon.Pulsar.Admin.Http` is a concrete in-process HTTP client built on `http-client` /
`http-client-tls`, using a configured admin base URL and optional bearer token. It supports
both `http://` and `https://` through the TLS manager and sends the Pulsar admin REST payload
shapes required by the broker for retention JSON, compaction thresholds, and dedup windows.
The vendored
`proto/PulsarApi.proto` schema is wired into Cabal through `proto-lens-setup`; the generated
`Proto.PulsarApi` / `Proto.PulsarApi_Fields` modules are re-exported as
`Daemon.Proto.PulsarApi`. `Daemon.Pulsar.Native` is a socket-backed production `HasPulsar`
instance: it parses typed `pulsar://host:port` broker URLs, performs the `CONNECT` handshake,
uses `LOOKUP` to resolve owner brokers, registers producers and consumers, publishes `SEND`
frames with Pulsar's metadata-length + CRC32C payload envelope, consumes `MESSAGE` frames via
`FLOW`, sends ACK / redelivery / SEEK commands, and keeps process-local consumer sessions for
long-lived subscriptions. Native consumers are named per process/session so Pulsar can expose a
single `activeConsumerName` for Failover subscriptions. Unit coverage validates frame and
payload round trips, admin payload rendering, and invalid-service-url handling; Apple Silicon
live validation covers topic lookup, admin configuration, seek/reset during audit replay, and
named Failover leadership for the reconciler.

## Why native, not the WebSocket gateway

The Pulsar WebSocket gateway was rejected for the production path:

1. **JSON + base64 framing.** The gateway wraps every message as JSON with a base64-encoded
   payload — ~33% size inflation plus encode/decode CPU on *every* message. For `infernix`'s
   multimodal payloads and `jitML`'s batched tensors that is a per-message tax on the busiest
   path in the system.
2. **Extra hop + extra failure domain.** The WebSocket proxy is a separate Pulsar component that
   must be deployed and enabled; it sits between the client and the owner broker, adding latency
   and another thing that can fall over.
3. **Subprocess boundary.** A Node WebSocket client means IPC serialization, a Node GC, process
   lifecycle management, and an entire Node runtime in the base image — a second language in a
   stack whose doctrine is thin and Haskell-only.
4. **Weak protocol surface.** Over WebSocket there is no native send-batching control, only
   coarse flow control, no cumulative ack, and no direct-to-owner-broker connection.
5. **Deadline sensitivity.** The substrate-owned batcher does epsilon-level deadline preemption
   (see [batching.md](batching.md)); process-boundary + proxy latency variance directly
   undermines that guarantee.

The native binary protocol removes all five: binary framing on the wire, a direct connection to
the owner broker, full producer/consumer protocol features, and in-process latency.

## Module surface

| Module | Role |
|--------|------|
| `Daemon.Pulsar` | `HasPulsar` typeclass + `SubscriptionMode` (unchanged) |
| `Daemon.Pulsar.Native` | production `HasPulsar` instance |
| `Daemon.Pulsar.Native.Frame` | wire framing (length prefix, command framing, payload layout) |
| `Daemon.Pulsar.Native.Connection` | multiplexed TCP connection, `CONNECT` handshake, keepalive, request/response correlation |
| `Daemon.Pulsar.Native.Lookup` | topic `LOOKUP` + partitioned-topic metadata |
| `Daemon.Pulsar.Native.Producer` | producer registration, `SEND`, optional send-batching / chunking |
| `Daemon.Pulsar.Native.Consumer` | subscribe (all modes), `FLOW` permits, message receipt, ack/nack, seek |
| `Daemon.Pulsar.Native.Compression` | optional batch compression (default `NONE`) |
| `Daemon.Proto.PulsarApi` | generated from vendored `proto/PulsarApi.proto` |
| `Daemon.Pulsar.Admin.Http` | production `Daemon.Pulsar.Admin` instance (admin REST) |

## Wire contract

The Pulsar binary protocol is protobuf-framed over TCP. The client implements only the subset
the substrate needs:

- **Framing.** Every frame is `[4-byte total size][4-byte command size][BaseCommand protobuf]`.
  Payload-bearing commands (`SEND`, `MESSAGE`) append
  `[magic 0x0e01][4-byte CRC32C checksum][4-byte metadata size][MessageMetadata][payload bytes]`.
  Framing is built with `bytestring` builders; there is no JSON anywhere on the data plane.
- **Commands used.** `CONNECT` / `CONNECTED`, `PING` / `PONG`, `LOOKUP` /
  `PARTITIONED_METADATA`, `PRODUCER` / `PRODUCER_SUCCESS`, `SEND` / `SEND_RECEIPT` /
  `SEND_ERROR`, `SUBSCRIBE` / `SUCCESS`, `FLOW`, `MESSAGE`, `ACK` / `ACK_RESPONSE`,
  `REDELIVER_UNACKNOWLEDGED_MESSAGES`, `SEEK`, `ACTIVE_CONSUMER_CHANGE`,
  `CLOSE_PRODUCER` / `CLOSE_CONSUMER`.
- **Schema.** `proto/PulsarApi.proto` is vendored verbatim from Apache Pulsar and compiled by
  the `proto-lens-protoc` setup hook into `Proto.PulsarApi` /
  `Proto.PulsarApi_Fields`, re-exported to substrate code as `Daemon.Proto.PulsarApi`. It is a
  *wire transport* schema, distinct from the substrate-owned application envelopes under
  `daemon_substrate/`; see [../reference/proto_surface.md](../reference/proto_surface.md).

## Connection model

- **Producer connection per publish; persistent consumer sessions.** Publish operations open a
  broker connection, perform `CONNECT`, resolve the owner broker with `LOOKUP`, register a
  producer, and complete the `SEND` exchange against that owner. Consumer operations use a
  process-local session keyed by service URL, operation timeout, and `Subscription`; the session
  keeps the native socket and `consumer_id` alive across consume, ack, nack, seek, and
  leadership checks while preserving the handle-free public `HasPulsar` surface.
- **Topic lookup.** `LOOKUP` resolves a topic to its owner broker so the client connects directly
  to it. Partitioned-topic metadata is still a later hardening concern because the harness topics
  are non-partitioned. When the bootstrap service URL is loopback (`localhost`, `127.0.0.1`,
  or `::1`), the client pins the resolved owner to that bootstrap address. This is the
  single-broker port-forward path used by the Apple host worker: Pulsar still advertises its
  in-cluster broker service, but host-native clients must stay on the forwarded loopback
  socket.
- **Keepalive and control frames.** Incoming broker `PING`s are answered with `PONG`.
  `ACTIVE_CONSUMER_CHANGE` frames update the session's cached Failover-active state and are
  ignored by operations that are waiting for data-plane frames. Matching `CLOSE_CONSUMER` frames
  invalidate the session so the next operation reconnects and resubscribes.
- **Seek/reset behavior.** Pulsar standalone can close a consumer after `SEEK`; the native client
  treats a broker close after a successfully written seek as a completed reset and invalidates
  the session. This is the audit-replay reset path used by the reconciler.

## Data-plane semantics (`HasPulsar`)

- `pulsarPublish` → `SEND`; with send-batching enabled, N messages (or a T-millisecond window)
  coalesce into one batched `SEND` whose `MessageMetadata.num_messages_in_batch > 1`. Batching
  composes with the substrate-owned `Daemon.Batching.*` layer rather than replacing it.
- `pulsarSubscribe` → `SUBSCRIBE` in the requested `SubscriptionMode` (`Shared`, `Failover`,
  `KeyShared`, `Exclusive`) with a non-empty native `consumer_name`.
- `pulsarWaitActive` → for non-Failover subscriptions returns active immediately; for Failover
  subscriptions reads `ACTIVE_CONSUMER_CHANGE` frames and returns true only for the active
  consumer, falling back to the cached active state on an idle read timeout.
- `pulsarConsume` → bulk `FLOW` permits (tunable prefetch) followed by pipelined `MESSAGE`
  receipt. An idle read timeout returns `Nothing` rather than failing the loop.
- `pulsarAcknowledge` → individual or **cumulative** `ACK`.
- `pulsarNegativeAcknowledge` → tracked client-side and surfaced as
  `REDELIVER_UNACKNOWLEDGED_MESSAGES`.
- `pulsarSeek` → `SEEK` by message-id or publish-time (the cursor-replay path the recovery model
  in [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md) relies on).
- **Chunking.** For an inline payload larger than `maxMessageSize`, the producer splits it into
  ordered chunked messages (mutually exclusive with batching). In practice the substrate
  guard-rails inline payloads at `BootConfig.maxInlinePayloadBytes` (default 1 MiB) and routes
  large artifacts to MinIO by nature, so chunking is a rarely-exercised safety path.

## Admin plane (`Daemon.Pulsar.Admin.Http`)

The typed admin operations (`createTopic`, `deleteTopic`, `terminateTopic`, `setRetention`,
`setCompaction`, `setDedupWindow`, `listTopics`, `exportTopicToObject`, `importTopicFromObject`)
map to the broker admin REST API (`/admin/v2/...`) via `http-client` + `http-client-tls`.
Retention updates send `{"retentionTimeInMinutes":...,"retentionSizeInMB":...}`, compaction
and dedup updates send numeric request bodies, and every request uses the configured operation
timeout. The admin plane is low-frequency and off the hot path, so it carries no
native-protocol perf requirement. Idempotency rules are unchanged: creates swallow
already-exists, set-ops are set-not-add.

## Compression

Compression is **opt-in and default `NONE`**. The substrate's own envelopes are small and
message-shaped, so compression buys little on that traffic, and the backends (`lz4`, `zstd`,
`snappy`, `zlib`) are C-FFI bindings that the dependency-lean library should not pull in
unconditionally. When a cohort enables compression via config, the whole batch is compressed at
once (per Pulsar semantics) and the negotiated type is recorded in `MessageMetadata.compression`.

## Configuration

All endpoints and tunables are typed config fields — never read from the environment or a
`$PATH`-resolved command (see [../../DEVELOPMENT_PLAN/development_plan_standards.md § M](../../DEVELOPMENT_PLAN/development_plan_standards.md)).

`BootConfig` (slowly-changing):

- broker service URL (`pulsar://host:6650`)
- admin REST base URL (`http://host:8080`)
- optional TLS / auth parameters (`pulsar+ssl`, token / TLS-cert auth)
- connection-pool size, operation timeout, keepalive interval
- `maxMessageSize`, compression type

`LiveConfig` (SIGHUP-reloadable hot knobs):

- consumer prefetch (FLOW permit batch size)
- send-batch max size / max publish-delay window
- dedup cache window

## Cross-references

- Subprocess-boundary doctrine and the Pulsar exception: [../../DEVELOPMENT_PLAN/development_plan_standards.md § M](../../DEVELOPMENT_PLAN/development_plan_standards.md)
- Where `Daemon.Pulsar.Native` lands: [../../DEVELOPMENT_PLAN/phase-2-capability-typeclasses-and-admin-surfaces.md](../../DEVELOPMENT_PLAN/phase-2-capability-typeclasses-and-admin-surfaces.md)
- Pulsar / MinIO source-of-truth split: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md)
- Topic inventory and subscription modes: [pulsar_topics.md](pulsar_topics.md)
- Vendored wire schema vs substrate envelopes: [../reference/proto_surface.md](../reference/proto_surface.md)
- Dependencies and package shape: [cabal_layout.md](cabal_layout.md)
- Batching / scheduling that send-batching composes with: [batching.md](batching.md)
