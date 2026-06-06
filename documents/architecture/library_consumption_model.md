# Library Consumption Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [daemon_roles.md](daemon_roles.md), [pulsar_minio_ssot.md](pulsar_minio_ssot.md), [lifecycle_policy.md](lifecycle_policy.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../engineering/pulsar_native_client.md](../engineering/pulsar_native_client.md), [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md), [../engineering/batching.md](../engineering/batching.md), [../reference/proto_surface.md](../reference/proto_surface.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define how downstream Haskell projects (`infernix`, `jitML`, future consumers)
> depend on, configure, and extend `daemon-substrate`, and what the library does versus what
> the consumer owns.

## TL;DR

- Consumers depend on `daemon-substrate` as a **Haskell library** via `cabal.project`'s
  `path:` mechanism. No binary, no Docker image, no published package.
- The library exposes substrate-agnostic typeclasses (`HasPulsar`, `HasMinIO`, `HasHarbor`,
  `HasKubectl`, `HasEngine`), five base loops (`runWorker`, `runOrchestrator`, `runBridge`,
  `runFanInBootstrap`, `runReconciler`), the `BootConfig role app` / `LiveConfig` /
  `LifecyclePolicy` configuration shapes, and the `runService` entry point.
- The consumer brings the engine, the substrate-specific code (Metal FFI, CUDA FFI, etc.), the
  Dhall layout, the protobuf payload types, the application data type plugged into
  `BootConfig`, the `OrchestratorBehavior` callbacks (fan-in / batch / fan-out / hydrate /
  bridge), and the `LifecyclePolicy` declaring which Pulsar topics and MinIO buckets it
  wants the substrate to manage.

## Dependency mechanism

The supported consumption mechanism is `cabal.project` `path:`. Consumers clone
`daemon-substrate` as a sibling repository and reference it relatively:

```cabal
packages:
  .
  ../daemon-substrate

with-compiler: ghc-9.12.4
```

GHC pin (`9.12.4`) is shared across `daemon-substrate`, `infernix`, and `jitML`, and matches the
GHC the [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image ships.
Mismatched compiler pins are not supported.

Consumers also depend on `hostbootstrap` for their own build, lifecycle, and bootstrap layer.
The dependency is at the *infrastructure* layer, not the Haskell-library layer:
`daemon-substrate`'s library surface is unchanged whether or not a consumer uses
`hostbootstrap`. See
[`../engineering/hostbootstrap_integration.md`](../engineering/hostbootstrap_integration.md)
for how `daemon-substrate` itself adopts `hostbootstrap`.

Alternative mechanisms — git submodules, vendoring with copy-paste, a published Hackage / git
dependency — are not part of the supported contract. If they become necessary, the plan changes
together with the implementation.

## Library surface

The library exposes these public modules (names finalized in the relevant phase):

| Module | Purpose | Owner |
|--------|---------|-------|
| `Daemon.Sub` | typed `Subprocess` boundary; every shell-out (MinIO / Harbor / Kubectl / `SubprocessEngine`) goes through here — Pulsar is the in-process exception | library |
| `Daemon.Pulsar` | `HasPulsar` typeclass and `SubscriptionMode` (`Shared`, `KeyShared`, `Exclusive`, `Failover`) | library |
| `Daemon.Pulsar.Native` | production in-process `HasPulsar` impl over Pulsar's native binary protocol (TCP); not a subprocess | library |
| `Daemon.Pulsar.Admin` | typed Pulsar admin operations (create / delete / terminate / set retention / export / import) | library |
| `Daemon.Pulsar.Admin.Http` | production in-process admin impl over the broker admin REST API | library |
| `Daemon.MinIO` | `HasMinIO` typeclass with CAS / ETag semantics | library |
| `Daemon.MinIO.Cache` | non-authoritative ephemeral cache wrapper | library |
| `Daemon.MinIO.Store` | generic content-addressed store (blobs / manifests / pointers + CAS) | library |
| `Daemon.MinIO.Admin` | typed MinIO bucket operations (create / lifecycle / list / delete) | library |
| `Daemon.Harbor` | `HasHarbor` typeclass (image registry operations) | library |
| `Daemon.Kubectl` | `HasKubectl` typeclass (cluster resource operations) | library |
| `Daemon.Engine` | `HasEngine` typeclass and the `SubprocessEngine` / `NativeEngine` sum | library |
| `Daemon.Config.BootConfig` | `BootConfig role app`, Dhall decoders, role tag | library |
| `Daemon.Config.LiveConfig` | SIGHUP-reloadable runtime config (retry policy, dedup cache, drain deadline) | library |
| `Daemon.Config.LifecyclePolicy` | Dhall decoders for `TopicLifecycle` / `BucketLifecycle` / `LifecyclePolicy` | library |
| `Daemon.Lifecycle` | 7-phase machine (`Load → Prereq → Acquire → Ready → Serve → Drain → Exit`), `runService` entry | library |
| `Daemon.Signal` | SIGHUP / SIGTERM / SIGINT handling | library |
| `Daemon.Audit` | compacted-topic helper for reconciler audit log | library |
| `Daemon.Consumer` | consumer-batch primitive + `HandlerRouter` + dedup cache | library |
| `Daemon.Worker` | `runWorker` base loop | library |
| `Daemon.Orchestrator` | `runOrchestrator` base loop and `runOrchestratorWithReconciler` concurrent runner | library |
| `Daemon.Bridge` | `runBridge` base loop (transform one topic, publish another) | library |
| `Daemon.Bootstrap` | `runFanInBootstrap` base loop (request → MinIO → ready event) | library |
| `Daemon.Reconciler` | `runReconciler` base loop (leader-elected Pulsar + MinIO lifecycle) | library |
| `Daemon.WorkflowState` | append-only workflow event ownership over Pulsar topics | library |
| `Daemon.Proto.*` | generated protobuf envelopes for substrate-owned messages (workflow, control, orchestrator↔worker, lifecycle, audit) | library |
| `Daemon.Wire.*` | hand-written Haskell ADT wrappers around `Daemon.Proto.*`; idiomatic application-facing types with `toProto` / `fromProto` codecs | library |
| `Daemon.Topology.*` | typed builders for Pulsar topologies (`RequestResponse`, `FanOut`, `BatchedFanOut`, `FanIn`, `BatchedFanIn`, `Pipeline`, `Stream`) | library |
| `Daemon.Batching.*` | substrate-owned batcher + multi-bucket scheduler (`BatchingPolicy`, `SchedulerPolicy`, `BatchingHooks`); see [../engineering/batching.md](../engineering/batching.md) | library |

Current implementation note: `Daemon.Config.BootConfig`, `Daemon.Config.LiveConfig`, and
`Daemon.Config.LifecyclePolicy` are implemented. `BootConfig` exposes `Role` (`Worker` /
`Orchestrator`), phantom role markers, role-specific decode helpers, and
`maxInlinePayloadBytes` defaulting to `1048576` when omitted. `LiveConfig` exposes retry
policy, dedup-cache policy, `drainDeadlineSeconds`, `BatchingPolicy`, `SchedulerPolicy`,
closed `FlushStrategy` and `BackpressureMode` enums, and `reloadLiveConfigFile`, which returns
the previous config unchanged when reload decode fails. `LifecyclePolicy` exposes the four
`TopicLifecycle` modes, bucket layout/orphan-scan policy, and Dhall decoders with
`safetyWindowMin = None Natural` defaulting to 60 minutes. `Daemon.Lifecycle` implements the
seven-phase callback-driven state machine, runtime record, CLI parser, and `runService` /
`runServiceWithArgs` entry points. `runService` decodes BootConfig, LiveConfig, and
LifecyclePolicy, invokes the consumer callback at `Serve`, and reports typed decode or
lifecycle failures. `Daemon.Signal` maps SIGHUP to reload and SIGTERM / SIGINT to drain, and
`Daemon.Lifecycle.Endpoints` renders the minimal health, readiness, and metrics endpoints
from runtime state.

`Daemon.Engine` implements the batch-native `HasEngine` signature:
`engineCall :: NonEmpty EngineRequest -> m (NonEmpty (Either EngineError EngineResponse))`.
`NativeEngine` wraps an in-process batch handler. `SubprocessEngine` runs each request through
the typed `Daemon.Sub` boundary, preserves the request id on success, returns typed
subprocess failures, and enforces a per-request timeout. `Daemon.Test.EchoEngines` provides
native and subprocess echo handles used by unit coverage; it is a test helper, not a
consumer-facing engine implementation.

`Daemon.Audit` publishes generated `AuditEvent` protobuf messages with compacted-topic keys
rendered as `<kind>:<id>` and replays the latest `ReconcileAction` per resource. `Daemon.Wire.*`
is implemented for workflow, control, orchestrator/worker, lifecycle, and audit envelopes;
application code uses the wire ADTs while generated `Daemon.Proto.*` imports stay restricted
to wrapper, wire, protocol-boundary, audit-boundary, and test-helper modules.

`Daemon.Worker` implements the worker-side base loop surface: `runWorker` subscribes to a
work topic, `workerStep` consumes one `OrchestratorToWorker` batch, materializes inline or
`ObjectRef` payloads, dispatches through the batch-native `HasEngine` contract, publishes
`WorkerResult` success / failure envelopes, and acks only after result publication succeeds.
`Daemon.Orchestrator` implements the orchestrator-side acquire/step surface: provision a
consumer-supplied `Topology`, attach shared ingress/result subscriptions, dispatch
`WorkflowEvent` messages to worker topics as `OrchestratorToWorker` batches, forward
`WorkerResult` messages to response topics, and compute reverse subscription order for drain.
It also exposes `runOrchestratorWithReconciler`, which runs an orchestrator action and a
reconciler action in separate threads while preserving typed loop outcomes.
`Daemon.Bridge` implements the generic one-topic-to-another bridge: consume a source message,
run a consumer-supplied transform that may choose the target topic, publish the transformed
payload, and ack only after the publish succeeds.
`Daemon.Bootstrap` implements the fan-in bootstrap pattern: consume a `WorkflowEvent`
request, run consumer-supplied work, write the ready bytes into MinIO, publish a deduplicated
ready `WorkflowEvent` carrying an `ObjectRef`, and nack failures for retry.
`Daemon.Reconciler` implements the leader-acquire plus one-tick reconciliation surface:
subscribe to the leader-control topic in `Failover` mode, replay audit state, create/configure
declared Pulsar topics and MinIO buckets idempotently, publish audit records for changed
resources, and remove unreachable declared-prefix objects in the filesystem test backend.
The repository's own harness Dhall files use the consumer-owned `app` field to declare the
test orchestrator topic graph and worker cohort settings; consumers define their own `app`
records the same way.

## What the library owns

- Pulsar, MinIO, Harbor, and Kubectl transport / cluster-I/O plumbing (the typeclasses, the
  substrate-default subscription semantics, the ETag handling, the typed subprocess seam for
  MinIO / Harbor / Kubectl, and the in-process native-protocol / admin-REST Pulsar client).
- The five base loops (`runWorker`, `runOrchestrator`, `runBridge`, `runFanInBootstrap`,
  `runReconciler`).
- The `BootConfig role app` / `LiveConfig` / `LifecyclePolicy` configuration shapes, Dhall
  decoders, and the typed plug for consumer-specific configuration.
- Workflow event ownership patterns over Pulsar (the `WorkflowOwner` shape: replay on
  `Acquire`, append-then-step on write).
- Lifecycle scaffolding: 7-phase machine, readiness / health / metrics HTTP endpoints, signal
  handlers, `runService` entry point.
- **Full lifecycle ownership of Pulsar topics and MinIO buckets / objects** declared in the
  consumer's `LifecyclePolicy` — the reconciler creates / configures / archives / deletes
  topics and buckets, runs MinIO orphan-scan with safety windows, and audits every action to a
  compacted Pulsar topic. See [lifecycle_policy.md](lifecycle_policy.md).
- The generic content-addressed `Daemon.MinIO.Store` (blobs / manifests / pointers with CAS),
  plus the `Daemon.MinIO.Cache` pin API (`pin` / `unpin` / `isPinned`) for consumer-managed
  hot-set protection.
- Substrate-owned protobuf envelopes (orchestrator-to-worker, worker status, generic workflow
  events with `WorkflowKind` tagging + `deadline_at` + `payload` oneof, audit events with
  lineage references). See [../reference/proto_surface.md](../reference/proto_surface.md).
- **Pulsar topology primitives** (`RequestResponse`, `FanOut`, `BatchedFanOut`, `FanIn`,
  `BatchedFanIn`, `Pipeline`, `Stream`) as typed Haskell builders that consumers compose into
  their orchestrator workflow graph; substrate provisions topics, dispatches by
  `payload_type` URL prefix, and surrenders subscriptions on drain. See
  [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md).
- **Batching machinery** for the in-cluster orchestrator: the `Batcher` (temporal
  accumulator + flush triggers + per-request response demux), the multi-bucket `Scheduler`
  (hard-deadline preemption + WFQ + optional dwell), `BatchingPolicy` / `SchedulerPolicy`
  Dhall surfaces in `LiveConfig`, and the `BatchingHooks` consumer extension. See
  [../engineering/batching.md](../engineering/batching.md).
- **Large-blob handoff convention**: payloads are placed by nature — the consumer publishes
  static binary artifacts as `ObjectRef` in `WorkflowEvent.payload` (at any size), and the
  substrate enforces only a `BootConfig.maxInlinePayloadBytes` guard rail on what is inlined.
  `ObjectRef` payloads are transparently materialized via `Daemon.MinIO.Store.readBlob` on
  receive when the consumer opts in.

## What the consumer owns

- The **engine**: the actual computation that runs against the hardware. Wrapped in either
  `SubprocessEngine` (process per request) or `NativeEngine` (in-process FFI).
- All **substrate-specific code**: Metal FFI, CUDA FFI, Apple host topology, GPU device
  enumeration, anything that talks to acceleration hardware directly.
- The **orchestrator's application logic.** `daemon-substrate` provides the orchestrator base
  loop (`runOrchestrator`), the role plumbing, and the lifecycle scaffolding. Consumer-specific
  orchestrator behavior — which upstream Pulsar topics to subscribe to, how to batch, which
  per-cohort worker topics to fan out to, which WAN registries to hydrate weights from, what
  the response envelopes look like — is supplied through the typed `BootConfig role app` plug
  and the consumer's own `app`-side code. `infernix` and `jitML` may carry completely
  different orchestrator behavior and Dhall shapes; the substrate prescribes the *shape* any
  orchestrator must fit into, not the *behavior* it performs.
- The **application data type** plugged into `BootConfig role app` (consumer-specific routing,
  engine selection, model registry).
- The **Dhall on-disk layout** and loader. The library defines the shape; the consumer decides
  where Dhall files live and how they're staged.
- Consumer-specific **payloads** that ride the substrate-owned envelopes. The substrate treats
  every `WorkflowEvent.inline_bytes` payload as opaque and every `WorkflowEvent.object_ref`
  payload as a MinIO reference; consumers choose whatever encoding fits (own proto family,
  CBOR, raw tensor buffers, etc.). Each consumer namespaces its `payload_type` URLs under its
  own root (`type.infernix.io/inference/v1/...`, `type.jitml.io/training/v1/...`) and
  registers handlers with `Daemon.Consumer.HandlerRouter` keyed by URL prefix.
- The **placement decision**: which payloads ride inline vs. as `ObjectRef`. Because the
  substrate is payload-blind, the consumer (not the substrate) decides by payload nature —
  static binary artifacts go to MinIO as `ObjectRef`; message-shaped state stays inline under
  the `maxInlinePayloadBytes` guard rail.
- **The `BatchingHooks` combinability predicate** (`canCombine` + `bucketKey`) — the only
  payload-aware extension into substrate's batcher. Substrate cannot inspect payloads; the
  consumer's `bucketKey` choice is what makes scheduler fairness meaningful for the workload.
- **Composition of topology primitives** into a workflow graph: choosing which Pulsar topics
  exist, which `RequestResponse` / `FanOut` / `Pipeline` / `Stream` shapes wire them together,
  and which workflows get batched.
- The consumer's own deployment artifacts: Helm charts, bootstrap scripts, Dockerfiles, kind
  setup. The substrate's own test harness is *not* a model for consumer deployment; consumers
  reuse infernix's or jitML's existing patterns.
- WAN-side concerns: model registry credentials, HuggingFace tokens, dataset acquisition.

## What is forbidden in library code

- branching on **cohort identifier** anywhere under `src/Daemon/*`. (`apple-silicon` and
  `linux-cpu` are *test-harness cohort* identifiers — used by the harness for cluster
  bootstrap, Pulsar topic suffixes, and Dhall file selection. The library proper is cohort-
  and substrate-agnostic; only the harness under `src/Daemon/Cluster/*`, `hostbootstrap.dhall`,
  `docker/Dockerfile`, and `chart/` may branch on cohort, and only for
  cluster bring-up purposes.)
- shell-inherited daemon configuration reads
- `proc "<bare-command-name>"` invocations (anything resolved via `$PATH`)
- direct WAN access (the substrate never talks to HuggingFace, S3, or any external endpoint;
  the consumer's Orchestrator does)
- carrying authoritative state outside Pulsar and MinIO

These rules match the consumer projects' own doctrines so the library never relaxes a
constraint the consumer enforces.

## Reference scaffolding for the three ML workflow archetypes

`daemon-substrate` is the reference scaffolding `infernix` and `jitML` build on. The library
surface above is deliberately shaped to carry three ML workflow archetypes without prescribing
any of them:

- **(a) Continuous batched inference** (≈ `infernix`) — `runOrchestrator` fan-in + batching,
  `runWorker` engine dispatch, `runBridge` result fan-back; sequence state on Pulsar.
- **(b) Finite SL / offline-RL training jobs** (≈ `jitML`) — bounded runs over Pulsar with
  `FiniteSession` topic lifecycle; checkpoints as MinIO `ObjectRef` blobs.
- **(c) Continuous online RL** — `runFanInBootstrap` writes new weights to MinIO and announces
  them on the Pulsar inference topics; distinct training-vs-inference task messages route by
  `payload_type` URL prefix to the same or separate stateless engines.

The substrate provides the base loops, topology primitives, batching machinery, and lifecycle
policy; the consumer plugs in its archetype-specific `app` record, payloads, and
`OrchestratorBehavior`. The test harness validates all three archetypes against each execution
model (the 3×3 matrix in [../development/testing_strategy.md](../development/testing_strategy.md)).

## Sealed consumer loops

`infernix` and `jitML` are **sealed loops** over shared substrate primitives. They share
infrastructure (envelope, topology, batching, lifecycle) but do not exchange domain payloads
with each other:

- `infernix` consumes only public-domain open-weight models (HuggingFace, Civitai, etc.) and
  exposes its own inference protocol; it does not consume artifacts produced by `jitML`.
- `jitML` trains and serves only its own model type; its checkpoints and training data are
  not consumed by `infernix`.

The substrate consequence: there is no third "shared-consumer" contract layer between the
substrate and the consumers. Substrate-owned schemas cover envelopes / topology / batching /
lifecycle. Consumer-owned schemas cover payloads. There is no substrate-mediated
consumer-to-consumer protocol. If a future consumer breaks the sealed-loop assumption, the
correct response is to introduce a shared-contracts library between those two consumers — not
to push the schema down into substrate, which would force the substrate to evolve on
consumer-domain timescales.

## Substrate-aware test harness

The library code is substrate-agnostic; the *test harness* that proves the library works is
necessarily aware of the execution model for cluster bootstrap (`Container` project image vs
`HostBinary` / `HostDaemon` native host build). The harness declares one substrate entry per
hostbootstrap target in the single root `hostbootstrap.dhall`: Apple Silicon `HostDaemon`,
Linux CPU `Container`, and Linux GPU `Container` with the CUDA-flavored base image. The harness lives outside consumer-facing
`src/Daemon/*` code — under `hostbootstrap.dhall`, `docker/Dockerfile`,
`chart/`, `src/Daemon/Cluster/*`, and the `daemon-substrate-test` executable. The host-specific
bring-up itself is delegated to
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap); see
[`../engineering/hostbootstrap_integration.md`](../engineering/hostbootstrap_integration.md).
Consumers do not run the harness; it exists for `daemon-substrate`'s own validation. See
[../development/testing_strategy.md](../development/testing_strategy.md).

## Cross-references

- Daemon role definitions: [daemon_roles.md](daemon_roles.md)
- Pulsar / MinIO split: [pulsar_minio_ssot.md](pulsar_minio_ssot.md)
- Lifecycle policy and reconciler: [lifecycle_policy.md](lifecycle_policy.md)
- Envelope schema and `payload_type` URL conventions: [../reference/proto_surface.md](../reference/proto_surface.md)
- Orchestration topology primitives: [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md)
- Batching and scheduling: [../engineering/batching.md](../engineering/batching.md)
- Cabal package layout: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- Plan-level surface contract: [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)
