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
  `[magic 0x0e01][4-byte CRC32C checksum][MessageMetadata][payload bytes]`. Framing is built
  with `bytestring` builders; there is no JSON anywhere on the data plane.
- **Commands used.** `CONNECT` / `CONNECTED`, `PING` / `PONG`, `LOOKUP` /
  `PARTITIONED_METADATA`, `PRODUCER` / `PRODUCER_SUCCESS`, `SEND` / `SEND_RECEIPT` /
  `SEND_ERROR`, `SUBSCRIBE` / `SUCCESS`, `FLOW`, `MESSAGE`, `ACK` / `ACK_RESPONSE`,
  `REDELIVER_UNACKNOWLEDGED_MESSAGES`, `SEEK`, `CLOSE_PRODUCER` / `CLOSE_CONSUMER`.
- **Schema.** `proto/PulsarApi.proto` is vendored verbatim from Apache Pulsar and compiled by the
  existing `proto-lens-protoc` step into `Daemon.Proto.PulsarApi`. It is a *wire transport*
  schema, distinct from the substrate-owned application envelopes under `daemon_substrate/`; see
  [../reference/proto_surface.md](../reference/proto_surface.md).

## Connection model

- **One multiplexed TCP connection per owner broker.** All producers and consumers for a broker
  share a single connection; in-flight requests are correlated by `request_id`, and incoming
  frames are demultiplexed to the right producer/consumer by `producer_id` / `consumer_id`.
- **Topic lookup.** `LOOKUP` (and `PARTITIONED_METADATA` for partitioned topics) resolves a topic
  to its owner broker so the client connects **directly** to it — no proxy indirection. The
  connection pool is keyed by resolved broker address.
- **Keepalive.** Periodic `PING` / `PONG` on idle connections; a missed keepalive triggers
  reconnect-and-resubscribe (the same recovery path used on broker failover).
- **Async pipelining.** Requests are issued without head-of-line blocking; responses are matched
  to their `request_id` as they arrive.

## Data-plane semantics (`HasPulsar`)

- `pulsarPublish` → `SEND`; with send-batching enabled, N messages (or a T-millisecond window)
  coalesce into one batched `SEND` whose `MessageMetadata.num_messages_in_batch > 1`. Batching
  composes with the substrate-owned `Daemon.Batching.*` layer rather than replacing it.
- `pulsarSubscribe` → `SUBSCRIBE` in the requested `SubscriptionMode` (`Shared`, `Failover`,
  `KeyShared`, `Exclusive`).
- `pulsarConsume` → bulk `FLOW` permits (tunable prefetch) followed by pipelined `MESSAGE`
  receipt.
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
map to the broker admin REST API (`/admin/v2/...`) via `http-client` + `http-client-tls`. The
admin plane is low-frequency and off the hot path, so it carries no native-protocol perf
requirement; the win is simply removing the last Pulsar subprocess and the `pulsar-admin` binary
from the base image. Idempotency rules are unchanged: creates swallow already-exists, set-ops are
set-not-add.

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
