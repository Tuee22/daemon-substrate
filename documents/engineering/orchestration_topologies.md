# Orchestration Topology Primitives

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/pulsar_minio_ssot.md](../architecture/pulsar_minio_ssot.md), [../architecture/daemon_roles.md](../architecture/daemon_roles.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [pulsar_topics.md](pulsar_topics.md), [batching.md](batching.md), [../reference/proto_surface.md](../reference/proto_surface.md), [../../DEVELOPMENT_PLAN/phase-5-base-loops.md](../../DEVELOPMENT_PLAN/phase-5-base-loops.md)

> **Purpose**: Specify the typed Haskell builders the substrate ships under `Daemon.Topology.*` for assembling Pulsar topologies. Consumers compose these primitives into their orchestrator workflows; the library does not expose raw Pulsar client code as a supported API.

## TL;DR

- Substrate ships seven topology primitives in `Daemon.Topology.*`: `RequestResponse`, `FanOut`, `BatchedFanOut`, `FanIn`, `BatchedFanIn`, `Pipeline`, `Stream`.
- Each primitive is a typed builder that produces a `Topology` value naming Pulsar topics, subscription modes, correlation conventions, and ack semantics.
- Consumers compose `Topology` values into their orchestrator's workflow graph; substrate provisions topics on `Acquire`, dispatches via `HandlerRouter` at runtime, and surrenders subscriptions on `Drain`.
- Batched variants (`BatchedFanOut`, `BatchedFanIn`) accept a `BatchingPolicy` + `SchedulerPolicy` + `BatchingHooks` — full spec in [batching.md](batching.md).
- Substrate is payload-agnostic: dispatch is by `WorkflowEvent.payload_type` URL prefix via `Daemon.Consumer`'s `HandlerRouter`; substrate never inspects payload bytes.
- Large payloads (above `BootConfig.blobInlineThresholdBytes`) flow as `ObjectRef` in `WorkflowEvent.payload`; the topology layer materializes transparently on read when the consumer opts in.

## Current Status

Target behavior. Module surface and Dhall config land in [Phase 5 Sprint 5.1](../../DEVELOPMENT_PLAN/phase-5-base-loops.md) (non-batched primitives) and [Sprint 5.1.5](../../DEVELOPMENT_PLAN/phase-5-base-loops.md) (batched variants). This document precedes implementation by phase ordering so that downstream phases can reference the contract.

## Primitive inventory

| Primitive | Input topics | Output topics | Default subscription mode | Typical use |
|-----------|--------------|---------------|---------------------------|-------------|
| `RequestResponse` | `request` (1) | `response` (1) | `Shared` on request; correlation-IDs demux response | Inference fan-in / fan-back, RPC-shaped flows |
| `FanOut` | `input` (1) | per-cohort `workers` (N) | `Shared` on input; `Shared` per worker subscription | Stateless work distribution across heterogeneous workers |
| `BatchedFanOut` | `input` (1) | per-cohort `workers` (N) | `Shared` on input; `Shared` per worker subscription | Inference / training where worker is batch-native |
| `FanIn` | `inputs` (N) | `aggregator` (1) | `Shared` per input subscription | Result collection, telemetry roll-up |
| `BatchedFanIn` | `inputs` (N) | `aggregator` (1) | `Shared` per input subscription | Gradient accumulation, trajectory aggregation in RL |
| `Pipeline` | `stages[0].input` (1) | `stages[n-1].output` (1) | `Shared` on each stage handoff | Sequenced stages with explicit handoff topics |
| `Stream` | `input` (1) | `output` (1) | `Shared` with windowing + checkpoint cursor | Continuous flow with periodic state checkpointing |

All primitives accept consumer-supplied topic names; the substrate does not prescribe topic naming. Subscription modes can be overridden when the consumer needs `KeyShared` (context-affine inference) or `Failover` (single-active-consumer control flows).

## Builder API

Each primitive is a typed Haskell record with a smart constructor. The resulting `Topology` value is opaque to the consumer; `runOrchestrator` reads its internal structure during `Acquire`.

```haskell
module Daemon.Topology.RequestResponse where

data RequestResponse req resp = RequestResponse
  { reqTopic     :: !Topic
  , respTopic    :: !Topic
  , reqMode      :: !SubscriptionMode   -- default: Shared
  , reqHandler   :: PayloadTypeUrl
  }

requestResponse :: Topic -> Topic -> PayloadTypeUrl -> RequestResponse req resp
```

```haskell
module Daemon.Topology.FanOut where

data FanOut req = FanOut
  { fanInTopic   :: !Topic
  , workerTopics :: !(NonEmpty (Cohort, Topic))
  , workerMode   :: !SubscriptionMode   -- default: Shared
  }

fanOut :: Topic -> NonEmpty (Cohort, Topic) -> FanOut req
```

```haskell
module Daemon.Topology.BatchedFanOut where

import Daemon.Batching (BatchingPolicy, SchedulerPolicy, BatchingHooks)
import Daemon.Topology.FanOut (FanOut)

data BatchedFanOut req = BatchedFanOut
  { underlying      :: !(FanOut req)
  , batchingPolicy  :: !BatchingPolicy
  , schedulerPolicy :: !SchedulerPolicy
  , batchingHooks   :: !(BatchingHooks req)
  }

batchedFanOut
  :: FanOut req
  -> BatchingPolicy
  -> SchedulerPolicy
  -> BatchingHooks req
  -> BatchedFanOut req
```

`FanIn`, `BatchedFanIn`, `Pipeline`, and `Stream` follow the same pattern: a record exposing structural fields plus a smart constructor that defaults `SubscriptionMode` to the documented norm.

## Composition examples

### `infernix` multimodal inference

```haskell
let reqResp  = requestResponse
                  (Topic "infernix.req")
                  (Topic "infernix.res")
                  (PayloadTypeUrl "type.infernix.io/inference/v1/MultimodalRequest")

    workers  = fanOut
                  (Topic "infernix.req")
                  ((CohortLinuxCpu, Topic "infernix.work.linux-cpu") :|
                   [(CohortAppleSilicon, Topic "infernix.work.apple-silicon")])

    batched  = batchedFanOut workers infernixBatchingPolicy infernixSchedulerPolicy
                  BatchingHooks
                    { canCombine = \a b -> reqModel a == reqModel b
                                        && lengthBucket a == lengthBucket b
                    , bucketKey  = Just (\req -> (reqModel req, lengthBucket req))
                    }
```

### `jitML` SL training pipeline

```haskell
let trainLoop = pipeline
                   [ stage dataLoad
                   , batchedFanIn gradientAggregation
                       jitmlSlBatchingPolicy
                       (defaultSchedulerPolicy { bucketDwellTime = secondsToDiffTime 0 })
                       BatchingHooks
                         { canCombine = \_ _ -> True
                         , bucketKey  = Just (\req -> ByDataParallelRank (dpRank req))
                         }
                   , stage trainStep
                   , stage checkpoint
                   ]
```

### `jitML` RL training

```haskell
let envWorkers   = fanOut (Topic "jitml.rl.envreq")
                          ((CohortLinuxCpu, Topic "jitml.rl.envwork.linux-cpu") :| [])

    trajectoryAgg = batchedFanIn (Topic "jitml.rl.trainer")
                       jitmlRlBatchingPolicy
                       defaultSchedulerPolicy
                       defaultBatchingHooks

    rlPipeline    = pipeline [ stage envWorkers, stage trajectoryAgg, stage rlTrainer ]
```

Topologies are normal Haskell values; consumers can build them programmatically, pass them as records, or splice them from Dhall-decoded skeletons.

## How substrate uses a `Topology`

1. **On `Prereq`**: the orchestrator reads the consumer's `Topology` graph and computes the desired-state set of Pulsar topics + subscriptions. Compared against observed state; admin actions are queued.
2. **On `Acquire`**: substrate invokes `Daemon.Pulsar.Admin` to create missing topics, configure retention via the `LifecyclePolicy` declaration, attach to subscriptions, and rehydrate any `WorkflowState` folds. Topology validation runs here — malformed graphs (cycles in `Pipeline`, duplicate topic names) fail closed.
3. **On `Serve`**: messages arrive on input topics. `Daemon.Consumer` consumes, decodes the envelope via `Daemon.Wire.*`, materializes the `ObjectRef` payload via `Daemon.MinIO.Store.readBlob` when present, and dispatches via `HandlerRouter` keyed by `payload_type` URL prefix.
4. **On `Drain`**: substrate surrenders subscriptions in reverse topology dependency order (downstream first; upstream last) so that no message is consumed without somewhere to publish its result.

## Validation

Property tests in `daemon-substrate-unit`:

- Builder → expected `Daemon.Pulsar.Admin` calls match a golden inventory per primitive.
- Round-trip publish/consume through each primitive delivers the right messages to the right subscribers.
- Subscription mode defaults are honored; overrides take effect.
- `Failover` vs `Shared` semantics observable end-to-end (single active vs round-robin).
- Cycle detection on `Pipeline` fails closed at `Acquire`.

Integration tests in `daemon-substrate-integration`:

- A composed graph (`Pipeline` of `RequestResponse` + `BatchedFanOut` + `FanIn`) provisions correctly against filesystem Pulsar, services synthetic load, and drains cleanly.

## Cross-references

- Batched-variant configuration: [batching.md](batching.md)
- Substrate-owned envelope schema: [../reference/proto_surface.md](../reference/proto_surface.md)
- Pulsar topic inventory + subscription mode rules: [pulsar_topics.md](pulsar_topics.md)
- Where consumers wire topologies into base loops: [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md)
- Orchestrator + reconciler concurrency: [../architecture/daemon_roles.md](../architecture/daemon_roles.md)
- Sprint deliverables: [../../DEVELOPMENT_PLAN/phase-5-base-loops.md](../../DEVELOPMENT_PLAN/phase-5-base-loops.md)
