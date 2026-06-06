# Batching and Scheduling

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [orchestration_topologies.md](orchestration_topologies.md), [pulsar_topics.md](pulsar_topics.md), [../reference/proto_surface.md](../reference/proto_surface.md), [../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md](../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md), [../../DEVELOPMENT_PLAN/phase-5-base-loops.md](../../DEVELOPMENT_PLAN/phase-5-base-loops.md)

> **Purpose**: Specify how the substrate batches in-flight requests inside the in-cluster orchestrator to keep accelerated workers saturated. Covers the `Daemon.Batching.Batcher` component, the `BatchingPolicy` and `SchedulerPolicy` Dhall surfaces, the `BatchingHooks` consumer extension, flush strategies, deadline semantics, multi-bucket scheduling, backpressure modes, and the telemetry surface.

## TL;DR

- Batching is **substrate-owned** because it is infrastructure-shaped: the temporal-accumulator + flush-trigger + deadline-aware + response-demux stack is identical across LLM inference, image / audio / video generation, supervised training, and RL training. Re-implementing it per consumer would be wasteful and divergent.
- Worker interface is **batch-native**: `HasEngine.engineCall :: NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))`. Per-request dispatch and per-request response demux is substrate's job; consumers never write batching code.
- `BatchingPolicy` (Dhall, in `LiveConfig`, SIGHUP-reloadable) governs flush triggers: `maxBatchSize`, `maxWaitWindow`, `minBatchSize`, `maxInFlightBuffer`, `flushStrategy`, `backpressureMode`.
- `SchedulerPolicy` (Dhall, sibling) governs multi-bucket scheduling: per-bucket weights, deadline preemption ε, bucket dwell time.
- `BatchingHooks` (Haskell, in consumer code) provides the only payload-aware extension: `canCombine :: req -> req -> Bool` and `bucketKey :: Maybe (req -> BucketKey)`. Defaults are universal-combinable / single-queue.
- Multi-bucket scheduler layers: **hard-deadline preemption** (always on) + **weighted fair queueing** (default) + **optional bucket-affinity dwell**. Adaptive weights are deferred to a future revision.
- Fairness is measured in request-count × wait-time (the WFQ virtual-time abstraction), **not** compute cost. Cost-aware fairness is achieved by consumer choice of `bucketKey` so that within-bucket cost is roughly uniform.
- `WorkflowEvent.deadline_at` is the substrate-level deadline carrier; expired requests are dropped before dispatch and emit a typed telemetry event.

## Current Status

`BatchingPolicy` and `SchedulerPolicy` are implemented as Dhall-decoded records in
`Daemon.Config.LiveConfig` and are reloadable through `reloadLiveConfigFile`.
`Daemon.Batching.Hooks`, `Daemon.Batching.Batcher`, `Daemon.Batching.Scheduler`, and
`Daemon.Batching.Telemetry` implement the pure runtime batching machinery. The batched
topology wrappers live in `Daemon.Topology.BatchedFanOut` and
`Daemon.Topology.BatchedFanIn`. The later `runOrchestrator` sprint wires these pure
primitives into the long-running Pulsar loop.

## Why substrate-owned

Three reasons the batcher belongs in substrate rather than in each consumer:

1. **Identical mechanics across workloads.** The temporal accumulator, deadline-aware flush, per-request response demux, backpressure, and telemetry stack does not differ between LLM inference, image generation, gradient accumulation, and RL trajectory replay. The differences are entirely in policy values and the combinability predicate.
2. **Worker decoupling.** The worker exposes a batch-native handler; it never speaks raw Pulsar. Substrate owns the path from Pulsar topic to batched dispatch to per-request response correlation. Re-implementing this in each consumer would be wasteful and divergent.
3. **Operational consistency.** Telemetry shape, backpressure semantics, and deadline handling are uniform across consumers because the operator's tools (dashboards, alerts, runbooks) are uniform.

The only payload-aware extension is `BatchingHooks`, which is small enough (two functions) that consumers can declare it inline without depending on substrate-internal types.

## BatchingPolicy

Lives in `LiveConfig` (SIGHUP-reloadable). Defined in `Daemon.Config.LiveConfig` and decoded from Dhall.

```haskell
data BatchingPolicy = BatchingPolicy
  { maxBatchSize         :: !Int             -- flush at N
  , maxWaitWindow        :: !NominalDiffTime -- flush after T elapsed
  , minBatchSize         :: !Int             -- do not flush below M unless deadline forces
  , maxInFlightBuffer    :: !Int             -- backpressure trigger
  , flushStrategy        :: !FlushStrategy
  , backpressureMode     :: !BackpressureMode
  , secondaryWorker      :: !(Maybe Text)    -- topic name for BackpressureMode = Redirect
  }
```

Dhall shape:

```dhall
let BatchingPolicy =
      { maxBatchSize      : Natural
      , maxWaitWindowMs   : Natural
      , minBatchSize      : Natural
      , maxInFlightBuffer : Natural
      , flushStrategy     : FlushStrategy
      , backpressureMode  : BackpressureMode
      , secondaryWorker   : Optional Text
      }
```

Field semantics:

| Field | Meaning |
|-------|---------|
| `maxBatchSize` | Maximum requests in a single dispatched batch. Once reached, flush regardless of wait window. |
| `maxWaitWindow` | Maximum time the oldest request in the queue waits before forced flush. Bounds tail latency. |
| `minBatchSize` | Floor below which the batcher prefers to wait. Overridden by deadline preemption. |
| `maxInFlightBuffer` | Total cap on (queued + dispatched-but-unacked) requests across all buckets. Triggers `backpressureMode`. |
| `flushStrategy` | Chooses among the named strategies below. |
| `backpressureMode` | Chooses among the named modes below. |
| `secondaryWorker` | Topic name to redirect to when `backpressureMode = Redirect`. |

## SchedulerPolicy

Lives in `LiveConfig` alongside `BatchingPolicy`.

```haskell
data SchedulerPolicy = SchedulerPolicy
  { bucketWeights              :: !(Map BucketKey Double)
  , deadlinePreemptionEpsilon  :: !NominalDiffTime
  , bucketDwellTime            :: !NominalDiffTime
  }
```

Dhall shape:

```dhall
let SchedulerPolicy =
      { bucketWeights              : List { bucket : Text, weight : Double }
      , deadlinePreemptionMs       : Natural
      , bucketDwellMs              : Natural
      }
```

Layered algorithm (always applied in this order):

1. **Hard-deadline preemption (always on).** When any request in any bucket is within `deadlinePreemptionEpsilon` of its `WorkflowEvent.deadline_at`, the batcher force-flushes that bucket on the next worker availability, overriding fairness and dwell. Deadlines always win.
2. **Weighted fair queueing.** Substrate maintains a per-bucket virtual-time deficit. When a worker is free and no preemption applies, dispatch the bucket with the largest deficit. Weights come from `bucketWeights`; missing buckets default to weight 1. Deficits update by `serviced_count / weight` on each dispatch.
3. **Optional bucket-affinity dwell.** When `bucketDwellTime > 0`, once a bucket is selected, the scheduler stays on it for at least the dwell window (or until it drains) before reconsidering. Trades fairness for throughput when bucket-switching has cost (e.g., model weight reload). Default `0` (no dwell).

**Adaptive weights** (deferred): substrate would observe `deadline_miss_rate` per bucket and temporarily boost weight when miss rate exceeds threshold. Not in v1; start with static weights and add adaptation when there is production telemetry to tune against.

### Unit of fairness

Substrate measures fairness as **request-count × elapsed-wait-time** (the WFQ virtual-time abstraction), **not** compute cost. Compute cost requires per-bucket cost estimates that substrate cannot produce without payload knowledge. Consumers needing cost-aware fairness should choose a `bucketKey` that makes within-bucket cost roughly uniform — then count-based fairness across buckets approximates resource fairness. This is a deliberate substrate constraint, not an oversight.

## BatchingHooks

The only payload-aware extension. Lives in consumer code (Haskell, not Dhall) because it requires payload type knowledge.

```haskell
data BatchingHooks req = BatchingHooks
  { canCombine :: req -> req -> Bool
  -- Returning False forces these two requests into separate batches even within the same bucket.
  -- e.g., LLM with strict KV-cache-shape requirements; mismatched precision modes.
  , bucketKey  :: Maybe (req -> BucketKey)
  -- When Just, substrate maintains a per-bucket queue and applies SchedulerPolicy across them.
  -- When Nothing, all requests live in a single queue (no scheduling).
  }
```

Defaults exported from `Daemon.Batching.Hooks`:

```haskell
defaultBatchingHooks :: BatchingHooks req
defaultBatchingHooks = BatchingHooks
  { canCombine = \_ _ -> True
  , bucketKey  = Nothing
  }
```

Worked examples:

```haskell
-- infernix LLM inference: bucket by (model, sequence-length bucket)
llmHooks :: BatchingHooks InferenceRequest
llmHooks = BatchingHooks
  { canCombine = \a b -> reqModel a == reqModel b
                      && reqQuantization a == reqQuantization b
                      && lengthBucket a == lengthBucket b
  , bucketKey  = Just (\req -> BucketKey (reqModel req <> "/" <> showBucket (lengthBucket req)))
  }
  where lengthBucket r = bucketize (estimatedSequenceLength r)  -- e.g., 0-512, 513-2048, 2049-8192, 8193+
```

```haskell
-- jitML data-parallel training: bucket by data-parallel rank
trainingHooks :: BatchingHooks TrainStepRequest
trainingHooks = BatchingHooks
  { canCombine = \a b -> dpRank a == dpRank b
  , bucketKey  = Just (\req -> BucketKey ("dp-" <> showRank (dpRank req)))
  }
```

## Flush strategies

`FlushStrategy` is a closed enum in v1. Open extension (typeclass / callback) would be the escape hatch if a consumer needs a learned or predictive strategy; see [open questions](#open-questions).

| Strategy | Behavior |
|----------|----------|
| `MaxFillOrTimeout` | Flush at `maxBatchSize` OR after `maxWaitWindow`, whichever comes first. The default. |
| `AdaptiveLatencyAware` | Observe worker service latency; shrink effective wait window when latency budget is tight. |
| `WindowedFixed` | Flush at exactly `maxBatchSize`; never partial. Forces gradient-accumulation semantics where batch shape determines convergence. Suitable for training only; will deadlock if request rate is too low and there's no deadline pressure. |
| `DeadlineAware` | Flush whenever any in-queue request is within `deadlinePreemptionEpsilon` of its deadline. Implies `BatchingPolicy.maxWaitWindow` is a soft hint, not a hard bound. Suitable for SLA-bound inference. |

## Backpressure modes

When `maxInFlightBuffer` is reached:

| Mode | Behavior |
|------|----------|
| `Block` | Pause Pulsar consume permits until the in-flight count drops below threshold. Upstream Pulsar producers experience backpressure naturally. The safe default. |
| `ShedLoad` | Fail in-flight requests with a typed `BatcherOverloaded` error published to the response topic. Upstream sees explicit failures rather than latency. Suitable when latency is preferable to be visible. |
| `Redirect` | Route subsequent requests to a secondary worker pool (topic named in `BatchingPolicy.secondaryWorker`) until pressure subsides. Suitable for sticky-failover patterns where a degraded-but-available secondary exists. |

## Deadline semantics

`WorkflowEvent.deadline_at = 0` (the proto-default value) means **no deadline** — the request is best-effort and ignored by deadline preemption.

For requests with `deadline_at > 0`:

- A request within `deadlinePreemptionEpsilon` of its deadline force-flushes its bucket on the next worker availability, overriding fairness and dwell.
- A request whose deadline has already passed at flush time is **dropped before dispatch** and emits `deadline_expired` telemetry. The substrate publishes a `BatcherDroppedExpired` failure envelope to the response topic so the upstream caller sees the drop rather than silent timeout.
- `deadlinePreemptionEpsilon` defaults to `2 × observed mean batch service time` when set to `0` in Dhall; substrate measures and adapts. Operators can override with a fixed value.

## Telemetry

The batcher emits the following metrics per bucket via the substrate observability surface (see [`../operations/`](../operations/) for the metric-naming conventions and dashboards):

| Metric | Type | Description |
|--------|------|-------------|
| `batcher_batch_fill_size`    | histogram | Actual size of each dispatched batch. |
| `batcher_batch_wait_time_ms` | histogram (p50 / p95 / p99) | Time from request enqueue to batch dispatch. |
| `batcher_queue_depth`        | gauge | Current queued requests, per bucket. |
| `batcher_service_count`      | counter | Requests serviced since process start, per bucket. |
| `batcher_deadline_miss_rate` | counter | Requests dropped past deadline, per bucket. |
| `batcher_scheduler_deficit`  | gauge | WFQ virtual-time deficit, per bucket. Useful for tuning weights from real data. |
| `batcher_backpressure_events`| counter | Times the in-flight buffer hit cap, labeled by `backpressureMode`. |

Operators tune `bucketWeights` by watching the deficit gauge and `deadline_miss_rate` together: a bucket with persistent positive deficit and elevated miss rate is underweighted.

## What substrate does NOT provide

- **Compute-cost-aware fairness.** Substrate cannot estimate per-request compute cost without payload knowledge. Consumers achieve cost-aware fairness by bucket choice.
- **Cross-process / cross-replica batching.** Each orchestrator replica's batcher is local. Multiple replicas reading the same input topic in `Shared` mode see disjoint request subsets (Pulsar guarantees at-most-one-active-consumer-per-message) and batch them independently. Total throughput scales with replica count.
- **Per-tenant quotas.** If a consumer wants per-tenant rate limiting, it implements it as a layer above the batcher (drop or queue at admission time). Substrate's `maxInFlightBuffer` is a flat cap, not per-tenant.

## Open questions

- **Adaptive weights.** When to add the adaptive-weight extension to `SchedulerPolicy`. Hold for production telemetry.
- **`FlushStrategy` extensibility.** Whether to keep the enum closed or expose a typeclass / callback for consumer-defined strategies. Closed for v1; revisit if a real use case appears.
- **Bucket eviction.** What happens when `bucketKey` produces an unbounded space (e.g., per-request-ID bucket by mistake). Current behavior: each bucket lives forever in the scheduler's state. Long term: idle-bucket eviction with configurable timeout. Not v1.

## Validation

Property tests in `daemon-substrate-unit`:

- 1000-iteration flush-trigger coverage for each `FlushStrategy` (size hit, wait window hit,
  and `WindowedFixed` full-batch behavior).
- WFQ service share over a 10 000-step synthetic trace.
- Deadline preemption fires within `deadlinePreemptionEpsilon` of the deadline.
- Bucket-affinity dwell is honored: scheduler stays on selected bucket for the full window unless the bucket drains.
- Backpressure modes resolve to the expected typed decisions: `Block`, `ShedLoad`, and
  `Redirect` with the secondary topic.
- Expired requests are dropped before dispatch and emit `BatcherDroppedExpired` telemetry.

Target matrix assertions in `daemon-substrate-integration`:

- End-to-end batching against the live Pulsar/MinIO harness with synthetic load profiles
  (uniform, bursty, heavy-tailed).
- Hot-bucket-vs-cold-bucket starvation regression: under sustained load, cold bucket completes ≥ `cold_weight / total_weight` fraction of service slots.
- Deadline-miss regression: a workload with declared deadlines sees `deadline_miss_rate` stay under threshold across the synthetic load.

## Cross-references

- Wire envelope (`WorkflowEvent.deadline_at`): [../reference/proto_surface.md](../reference/proto_surface.md)
- Topology primitives that wrap the batcher: [orchestration_topologies.md](orchestration_topologies.md)
- Lifecycle policy (where `BucketLifecycle` and `LiveConfig` are configured): [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md)
- Orchestrator concurrency contract: [../architecture/daemon_roles.md](../architecture/daemon_roles.md)
- Sprint deliverables: [../../DEVELOPMENT_PLAN/phase-5-base-loops.md](../../DEVELOPMENT_PLAN/phase-5-base-loops.md), [../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md](../../DEVELOPMENT_PLAN/phase-3-bootconfig-liveconfig-lifecycle.md)
