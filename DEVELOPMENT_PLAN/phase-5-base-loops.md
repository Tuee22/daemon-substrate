# Phase 5: Base Loops — Worker, Orchestrator, Bridge, Bootstrap, Reconciler

**Status**: Authoritative source
**Supersedes**: `phase-5-kind-cluster-and-helm-chart.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-engine-mock-protos-audit.md](phase-4-engine-mock-protos-audit.md), [phase-6-cluster-bringup-tree.md](phase-6-cluster-bringup-tree.md)

> **Purpose**: Land the five base loops that consumers parameterize with their own
> callbacks: `runWorker`, `runOrchestrator`, `runBridge`, `runFanInBootstrap`, `runReconciler`.
> Also lands `Daemon.Consumer` (dedup'd consumer-batch primitive) and `Daemon.WorkflowState`
> (append-only event ownership over Pulsar).

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 4
**Implementation**: none yet

## Phase Objective

Bring every daemon role to life. After this phase closes, a consumer can wire its own config
and callbacks into the appropriate `run*` function and get a working daemon. The reconciler
runs concurrently with the orchestrator base loop inside the same orchestrator process; the
two threads share the substrate's capability clients but no mutable state.

## Sprints

### Sprint 5.1: `Daemon.Consumer` + `Daemon.WorkflowState` + `Daemon.Topology.*` (non-batched) [Planned]

**Status**: Planned
**Docs to update**: `documents/engineering/pulsar_topics.md`,
`documents/architecture/pulsar_minio_ssot.md`, `documents/engineering/orchestration_topologies.md`,
`documents/reference/proto_surface.md`, `system-components.md`

#### Objective

Land the canonical consume-decode-dispatch-ack primitive used by every base loop, plus the
typed Pulsar topology builders consumers compose into their orchestrator workflow graph.

- `Daemon.Consumer` — consume from a subscription, decode the envelope via `Daemon.Wire.*`,
  honor `WorkflowEvent.payload` materialization (transparent `Daemon.MinIO.Store.readBlob`
  when `WorkflowEvent.payload = object_ref` and the consumer opts in), dispatch via the typed
  `HandlerRouter` keyed by `payload_type` URL prefix, ack on success, nack on failure. L3
  dedup cache is `LiveConfig`-tuned.
- `Daemon.WorkflowState` — append-to-Pulsar then advance in-memory fold; rehydrate on
  `AcquireClients`.
- `Daemon.Topology.*` (non-batched variants only): `RequestResponse`, `FanOut`, `FanIn`,
  `Pipeline`, `Stream`. Each primitive is a typed builder that produces a `Topology` value
  describing required Pulsar topics + subscription modes + correlation conventions + ack
  semantics. The `Topology` value is consumed by `runOrchestrator` / `runWorker` at `Acquire`
  to provision topics via `Daemon.Pulsar.Admin` and at `Serve` to drive dispatch.

The batched variants (`BatchedFanOut`, `BatchedFanIn`) land in Sprint 5.1.5 alongside the
batcher itself.

#### Deliverables

- `src/Daemon/Consumer.hs` populated, including `HandlerRouter` with `payload_type` URL-prefix
  dispatch and the transparent-materialization helper.
- `src/Daemon/WorkflowState.hs` populated.
- `src/Daemon/Topology/RequestResponse.hs`, `src/Daemon/Topology/FanOut.hs`,
  `src/Daemon/Topology/FanIn.hs`, `src/Daemon/Topology/Pipeline.hs`,
  `src/Daemon/Topology/Stream.hs` populated.
- unit tests covering: happy-path consume-ack, ack-on-success, nack-on-engine-failure, dedup
  window behavior, workflow-state rehydrate-from-snapshot, `HandlerRouter` URL-prefix
  dispatch (multiple registered consumers, longest-prefix wins), transparent
  `WireObjectRef`-to-bytes materialization, per-topology builder → expected
  `Daemon.Pulsar.Admin` calls (golden inventory), publish/consume round-trip through each
  topology primitive, subscription mode defaults vs overrides.

### Sprint 5.1.5: `Daemon.Batching.*` — Batcher, Scheduler, BatchedFanOut, BatchedFanIn [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/engineering/batching.md`,
`documents/engineering/orchestration_topologies.md`,
`documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Land the substrate's batching machinery — the in-cluster orchestrator's core responsibility
for keeping accelerated workers saturated. See
[`../documents/engineering/batching.md`](../documents/engineering/batching.md) for the full
specification of `BatchingPolicy`, `SchedulerPolicy`, `BatchingHooks`, flush strategies,
backpressure modes, deadline semantics, and telemetry.

- `Daemon.Batching.Batcher` — temporal accumulator with policy-driven flush, deadline
  awareness (reads `WorkflowEvent.deadline_at`), per-request response demux via correlation
  IDs.
- `Daemon.Batching.Scheduler` — layered multi-bucket scheduler: hard-deadline preemption +
  weighted fair queueing (WFQ virtual-time) + optional bucket-affinity dwell. Adaptive
  weights deferred to a future revision.
- `Daemon.Batching.Hooks` — `BatchingHooks` consumer extension type (`canCombine` +
  `bucketKey`) with safe defaults.
- `Daemon.Batching.Telemetry` — emission stubs for per-bucket histograms / gauges (batch
  fill, wait time, queue depth, deadline miss rate, scheduler deficit, backpressure events).
- `Daemon.Topology.BatchedFanOut` and `Daemon.Topology.BatchedFanIn` — composite topology
  primitives that wrap the corresponding non-batched primitive with a `Batcher` + `Scheduler`.
  Accept `BatchingPolicy`, `SchedulerPolicy`, and `BatchingHooks` at construction.

#### Deliverables

- `src/Daemon/Batching/Batcher.hs`, `src/Daemon/Batching/Scheduler.hs`,
  `src/Daemon/Batching/Hooks.hs`, `src/Daemon/Batching/Telemetry.hs` populated.
- `src/Daemon/Topology/BatchedFanOut.hs`, `src/Daemon/Topology/BatchedFanIn.hs` populated.
- Unit tests in `daemon-substrate-unit` covering: flush-trigger correctness per
  `FlushStrategy`; deadline preemption fires within `deadlinePreemptionEpsilon`; WFQ deficit
  calculation matches reference implementation over a 10000-step synthetic trace;
  bucket-affinity dwell honored; backpressure modes (`Block` pauses permits, `ShedLoad`
  publishes typed failure, `Redirect` routes to secondary topic); expired requests are
  dropped with `BatcherDroppedExpired` telemetry.
- Integration test in `daemon-substrate-integration`: hot-bucket-vs-cold-bucket starvation
  regression — under sustained load, cold bucket completes ≥
  `cold_weight / total_weight` fraction of service slots; deadline-miss regression on a
  workload with declared deadlines.

#### Validation

Property suite: 1000-iteration test per `FlushStrategy`. Integration starvation regression
gate runs as part of the `daemon-substrate-integration` standard suite once Phase 8 lands.

#### Module Surface

```haskell
data BatchingPolicy = BatchingPolicy
  { maxBatchSize         :: !Int
  , maxWaitWindow        :: !NominalDiffTime
  , minBatchSize         :: !Int
  , maxInFlightBuffer    :: !Int
  , flushStrategy        :: !FlushStrategy
  , backpressureMode     :: !BackpressureMode
  , secondaryWorker      :: !(Maybe Text)
  }

data FlushStrategy = MaxFillOrTimeout | AdaptiveLatencyAware | WindowedFixed | DeadlineAware
data BackpressureMode = Block | ShedLoad | Redirect

data SchedulerPolicy = SchedulerPolicy
  { bucketWeights              :: !(Map BucketKey Double)
  , deadlinePreemptionEpsilon  :: !NominalDiffTime
  , bucketDwellTime            :: !NominalDiffTime
  }

data BatchingHooks req = BatchingHooks
  { canCombine :: req -> req -> Bool
  , bucketKey  :: Maybe (req -> BucketKey)
  }
```

### Sprint 5.2: `runWorker` [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the worker base loop: subscribe to assigned Pulsar topics, consume via `Daemon.Consumer`,
decode payloads via `Daemon.Wire.*`, dispatch via the batch-native
`HasEngine.engineCall :: NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))`,
publish results, manage the ephemeral local cache. Per-request dispatch is the singleton-batch
case; multi-element batches flow when the worker is fed by an upstream `BatchedFanOut`.

#### Deliverables

- `src/Daemon/Worker.hs` populated, using the batched `HasEngine` signature.
- unit tests against the mock engine + filesystem Pulsar + filesystem MinIO covering both
  singleton-batch and multi-element-batch paths.

### Sprint 5.3: `runOrchestrator` [Planned]

**Status**: Planned
**Blocked by**: 5.1, 5.1.5
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the orchestrator base loop: provision Pulsar topics from the consumer-supplied
`Topology` graph at `Acquire`, fan-in from upstream topics, batch per `BatchingPolicy` /
`SchedulerPolicy` when the consumer wired a `BatchedFanOut` / `BatchedFanIn`, fan-out to
per-cohort worker topics, collect results, fan-back to upstream response topics, and
surrender subscriptions in reverse topology dependency order on `Drain`.

The orchestrator composes its workflow graph from `Daemon.Topology.*`. The canonical
accelerated-worker pattern is `BatchedFanOut` with consumer-supplied `BatchingHooks`;
substrate handles batching, scheduling, deadline-awareness, backpressure, and response demux.
Consumers do not write raw Pulsar client code.

The base loop must be **safe to run as N concurrent replicas**. It attaches to its
subscriptions in `Shared` mode, holds no replica-local authoritative cross-request state, and
tolerates message redelivery on replica loss. Each replica's `Batcher` is local; total
throughput scales with replica count because Pulsar's `Shared` subscription distributes
disjoint request subsets.

#### Deliverables

- `src/Daemon/Orchestrator.hs` populated, accepting a consumer-supplied `Topology` graph and
  dispatching via `Daemon.Consumer` / `Daemon.Batching` as configured.
- unit tests covering single-replica and multi-replica simulation (two `runOrchestrator`
  instances against the same filesystem Pulsar broker; assert no duplicate dispatches), a
  composed `Topology` graph (`Pipeline` of `RequestResponse` + `BatchedFanOut` + `FanIn`),
  and clean drain in reverse dependency order.

### Sprint 5.4: `runBridge` [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land `runBridge` — consume one topic, transform the payload, publish to another. Generalized
from infernix's `runResultBridgeLoop`. Used wherever a daemon needs to forward / translate
between topics (e.g., orchestrator → upstream response topic).

#### Deliverables

- `src/Daemon/Bridge.hs` populated
- unit tests covering: identity-bridge, payload transform, target-topic routing

### Sprint 5.5: `runFanInBootstrap` [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land `runFanInBootstrap` — request topic → do work → write to MinIO → publish ready event with
dedup. Generalized from infernix's `runModelBootstrapLoop`. Used for WAN→MinIO hydration of
model weights, training datasets, and any other "fetch once, signal readiness" pattern.

#### Deliverables

- `src/Daemon/Bootstrap.hs` populated
- unit tests covering: happy path, idempotent re-request (dedup'd), failure→retry

### Sprint 5.6: `runReconciler` [Planned]

**Status**: Planned
**Blocked by**: 5.1, 5.4 (`runBridge` for control-topic patterns)
**Docs to update**: `documents/architecture/lifecycle_policy.md`,
`documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land `runReconciler` — the leader-elected Pulsar + MinIO lifecycle reconciler. Acquires
leadership via a Failover subscription on `LifecyclePolicy.leaderControlTopic`. While active,
ticks every `LifecyclePolicy.reconcileEverySeconds`; diffs `LifecyclePolicy` desired-state
against observed state (Pulsar topics + MinIO objects + audit topic); executes idempotent
admin actions; audits each action.

Designed to run **concurrently with `runOrchestrator`** inside the same orchestrator process.
They share `HasPulsar` / `HasMinIO` / `HasHarbor`; they share no mutable state.

#### Deliverables

- `src/Daemon/Reconciler.hs` populated
- unit tests covering:
  - leader election: two `runReconciler` instances → only one ticks at a time
  - idempotent reconcile: 2× back-to-back tick = identical end state, zero churn
  - audit-topic replay on fresh-leader startup; completed actions are not re-executed
  - per-`TopicLifecycle`-mode reconciliation: each of `Ephemeral`,
    `ContinuousWithArchive`, `FiniteSession`, `OnlineLearning` exercised against filesystem
    Pulsar + filesystem MinIO
  - MinIO orphan-scan: safety-window honored (object younger than window is never deleted);
    unreachable objects past window are hard-deleted
  - `FiniteSession` session-resume: terminated topic reanimates when `reopenOnResume = True`

### Sprint 5.7: Concurrent execution contract [Planned]

**Status**: Planned
**Blocked by**: 5.3, 5.6
**Docs to update**: `documents/architecture/lifecycle_policy.md`,
`documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Define the orchestrator daemon's concurrent-thread spawning convention:
`runOrchestrator` + `runReconciler` run as separate threads (via `forkIO` or `async`) inside
the same process; the lifecycle scaffolding manages their startup ordering (both wait for
`Acquire` to complete before either enters `Serve`) and their shutdown ordering (both
surrender Failover subs cleanly on `Drain`).

#### Deliverables

- helper `runOrchestratorWithReconciler :: ... -> m ()` that spawns both threads
- unit tests covering: concurrent startup, mid-tick leader failover does not affect
  `runOrchestrator`, graceful shutdown surrenders both Failover subs

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/pulsar_topics.md` updates the consumer-batch / dedup-cache references
  from forward-looking to current-state.
- `documents/engineering/orchestration_topologies.md` lands as current-state when Sprint 5.1
  closes (non-batched primitives) and Sprint 5.1.5 closes (batched primitives).
- `documents/engineering/batching.md` lands as current-state when Sprint 5.1.5 closes.
- `documents/architecture/lifecycle_policy.md` updates the reconciler-implementation
  references from forward-looking to current-state; the "Batching and scheduling
  (orchestrator)" section and the `Daemon.MinIO.Cache` pin API entry also flip when the
  relevant sprints close.
- `documents/architecture/daemon_roles.md` updates the orchestrator section to current-state
  for the concurrent reconciler thread and for the substrate-owned batcher being the
  orchestrator's core responsibility.
- `documents/architecture/pulsar_minio_ssot.md` updates the workflow-state ownership
  paragraphs from forward-looking to current-state.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` — the `## Wire-layer wrappers` section reflects the
  Phase 4 Sprint 4.5 hand-written ADT layer that `Daemon.Consumer` now uses on the
  publish/subscribe boundary.

**Cross-references to add:**
- `system-components.md` flips `Daemon.Consumer`, `Daemon.WorkflowState`, `Daemon.Worker`,
  `Daemon.Orchestrator`, `Daemon.Bridge`, `Daemon.Bootstrap`, `Daemon.Reconciler`,
  `Daemon.Topology.*`, and `Daemon.Batching.*` rows to `Implemented: yes`.
