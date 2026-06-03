# Pulsar / MinIO Lifecycle Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [daemon_roles.md](daemon_roles.md), [pulsar_minio_ssot.md](pulsar_minio_ssot.md), [library_consumption_model.md](library_consumption_model.md), [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md), [../engineering/minio_buckets.md](../engineering/minio_buckets.md), [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md), [../engineering/batching.md](../engineering/batching.md), [../engineering/cluster_topology.md](../engineering/cluster_topology.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../reference/proto_surface.md](../reference/proto_surface.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md), [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md)

> **Purpose**: Canonical home for the Pulsar topic and MinIO bucket / object lifecycle that
> `daemon-substrate` owns — the declarative Dhall `LifecyclePolicy` shape consumers ship, the
> leader-elected reconciler that drives desired→observed convergence, the race-freedom
> guarantees, and the four workload patterns the substrate supports.

## TL;DR

- `daemon-substrate` owns the full lifecycle of every Pulsar topic and MinIO bucket / object the
  substrate plumbing uses. Consumers declare desired state in a typed Dhall `LifecyclePolicy`;
  the substrate reconciles to it.
- The **orchestrator** daemon runs the reconciler as a **fifth concurrent base loop**
  (`runReconciler`) alongside `runOrchestrator`'s fan-in / batch / fan-out / bridge work. Same
  binary, same Deployment.
- Multiple orchestrator replicas are safe — exactly **one is the active reconciler** at a time
  via a Pulsar **Failover subscription** on a control topic. Standbys block; on leader death,
  Pulsar promotes a survivor.
- Every reconcile action is idempotent. Every action is audited to a Pulsar compacted topic
  keyed by `<resource-kind>:<resource-id>`. A fresh leader replays the audit topic on startup
  to learn current state without re-executing completed actions.
- MinIO orphan cleanup is mark-and-sweep with a **safety window** (default 1h) that protects
  freshly-written objects mid-pointer-update from being collected.
- Four declarative topic-lifecycle modes (`Ephemeral`, `ContinuousWithArchive`,
  `FiniteSession`, `OnlineLearning`) cover the workload patterns infernix and jitML need.

## Who runs the lifecycle

The **orchestrator daemon** owns lifecycle implementation. Never the worker, never an external
CLI, never the operator. The reconciler is part of the orchestrator binary because:

- Workers must not touch admin surfaces (they hold no `HasHarbor` / admin capability).
- An external CLI would create a coordination problem (who runs it? when?). Putting it inside
  the orchestrator means k8s already operates the reconciler as part of normal Deployment
  rollout.
- The orchestrator already has every capability the reconciler needs (`HasPulsar` for topic
  admin + audit topic; `HasMinIO` for bucket admin + orphan scan).

`runReconciler` runs as a separate thread inside the orchestrator process, concurrent with
`runOrchestrator`'s workload handling. They share the substrate capabilities; they do not
share mutable state.

## Race-freedom across N replicas

Orchestrator Deployments default to `replicas: 2` (HA). Without coordination, two replicas
both running the reconciler would race on admin operations. The substrate avoids that with:

### Leader election via Pulsar Failover

Each orchestrator replica subscribes to a dedicated control topic
`control.reconcile.leader.<consumer>` in **Failover** mode. Pulsar guarantees at most one
active consumer per Failover subscription: the active replica is the reconciler leader, the
standbys block on `pulsarConsume` and do nothing. On leader death, Pulsar promotes a survivor,
which then resumes reconciliation from the audit topic.

No external coordination service (etcd, ZooKeeper, Consul) is required. The substrate uses
Pulsar's existing guarantees idiomatically.

### Idempotent admin actions

Every admin operation the reconciler issues is naturally idempotent:

- **Pulsar `create-topic`** swallows 409-exists. Subsequent `set-retention` / `set-compaction` /
  `set-dedup-window` are set-not-add semantics. `terminate-topic` is set-once.
- **Pulsar topic export to MinIO**: the export object key is content-addressed
  (`archives/<topic>/<startTime>-<endTime>.archive`); re-running export with the same range
  hits the existing object via `If-None-Match: *` and is a no-op.
- **MinIO `createBucket`** swallows BucketAlreadyOwnedByYou. `setBucketLifecycle` is set-not-add.
- **MinIO object writes** use `If-None-Match: *` for blobs / manifests (true create-if-absent)
  and `If-Match: <etag>` for pointer CAS.

A reconcile tick interrupted by a leadership flip is safe: the new leader sees the same
desired-vs-observed delta, the actions are idempotent, and the partial work either completes
(if the partial state is observable) or re-runs (and noops on the parts that already landed).

### Compacted audit topic

Every reconcile action publishes to `audit.reconcile.<consumer>` — a Pulsar **compacted topic**
keyed by `<resource-kind>:<resource-id>`. Compaction keeps only the latest record per key, so:

- A fresh leader on startup reads the compacted topic to learn the latest known state for every
  resource — without re-doing completed work.
- Operators can inspect the audit topic to see the current reconciled state of every resource
  the substrate manages.

The audit envelope is defined in `proto/daemon_substrate/audit.proto`; see
[../reference/proto_surface.md](../reference/proto_surface.md).

### Safety windows on destructive operations

MinIO orphan deletion only collects objects whose `LastModified` is older than
`now - safetyWindowMin` (default 60 minutes). This protects the race where a workload handler:

1. writes a blob (`putBlobIfAbsent`),
2. writes a manifest referencing it (`putManifest`),
3. updates a pointer to the manifest (`casPointer`),

and the reconciler's orphan scan runs between step 1 and step 3 — the blob is not yet
reachable from any pointer. The safety window guarantees the reconciler will not collect it.

## Four topic-lifecycle modes

```dhall
let TopicLifecycle =
      < Ephemeral :
          { retentionMinutes        : Natural
          , dedupWindowSeconds      : Natural
          }
      | ContinuousWithArchive :
          { hotRetentionHours       : Natural
          , archiveBucket           : Text
          , archivePrefix           : Text
          , archiveRetentionDays    : Natural
          , dedupWindowSeconds      : Natural
          }
      | FiniteSession :
          { sessionControlTopic     : Text
          , exportOnComplete        : Bool
          , archiveBucket           : Optional Text
          , archivePrefix           : Optional Text
          , reopenOnResume          : Bool
          }
      | OnlineLearning :
          { inferenceHotHours       : Natural
          , trainingHotHours        : Natural
          , archiveBucket           : Text
          , archivePrefix           : Text
          , archiveRetentionDays    : Natural
          }
      >
```

| Mode | Use case | Hot store | Cold store | Reopenable |
|------|----------|-----------|-----------|------------|
| `Ephemeral` | request / response (e.g. inference fan-in) | Pulsar (short retention) | none | n/a |
| `ContinuousWithArchive` | continuous inference (e.g. infernix) | Pulsar (N hours) | MinIO (N days) | no |
| `FiniteSession` | finite ML training run (e.g. jitML supervised) | Pulsar (live while active) | MinIO (on session end) | yes |
| `OnlineLearning` | continuous learning + inference hybrid | Pulsar (split hot windows) | MinIO (rolling archive) | implicit |

### Ephemeral

Short-lived request / response. Retention is wall-clock; messages older than `retentionMinutes`
are dropped by the broker. Dedup window suppresses replays of the same `EventId`. No archive.
Use for inference request topics, throwaway control topics, and any short-lived
fire-and-forget flow.

### ContinuousWithArchive

Continuous-flow topics that should remain queryable beyond Pulsar's broker retention. The
reconciler:

- watches the topic's age periodically;
- when message backlog ages past `hotRetentionHours`, exports the cooled window into MinIO
  under `archiveBucket / archivePrefix / <topic> / <startTime>-<endTime>.archive`;
- writes an audit record;
- lets Pulsar's normal retention collect the exported window from the broker.

The MinIO archives are then governed by `archiveRetentionDays` — a bucket lifecycle rule
deletes them after that window.

This is the right mode for continuous inference workloads where requesters may want to query
historical traffic.

### FiniteSession

A topic that exists for the lifetime of a finite session. The reconciler subscribes to a
session-control topic (declared in `sessionControlTopic`) and watches for `session-start` /
`session-end` events:

- On `session-start <session-id>`: ensures the corresponding workload topic exists; configures
  it without retention (live the whole session).
- On `session-end <session-id>`: if `exportOnComplete = True`, exports the topic's contents to
  MinIO under the declared archive bucket / prefix. Then calls `pulsar terminate` on the topic
  (or deletes if no consumer is attached).
- On `session-resume <session-id>` (if `reopenOnResume = True`): re-creates the topic; if an
  archive exists in MinIO, imports it back so subscribers can replay from the existing cursor.

This is jitML's deterministic-training-session shape. Because deterministic training guarantees
full recoverability, even a worst-case destructive failure mid-session is recoverable by
re-running.

### OnlineLearning

Hybrid pattern for continuous learning + continuous inference. Two parallel "hot" windows —
`inferenceHotHours` for inference traffic, `trainingHotHours` for training events — are
maintained in Pulsar simultaneously, with the reconciler rolling each window into MinIO under
the declared archive bucket / prefix. The archives age out per `archiveRetentionDays`.

## Bucket lifecycle

```dhall
let BucketLifecycle =
      { bucket                  : Text
      , layout :
          { blobs    : { prefix : Text, retentionDays : Optional Natural }
          , manifests: { prefix : Text, retentionDays : Optional Natural }
          , pointers : { prefix : Text }
          , archives : Optional { prefix : Text, retentionDays : Natural }
          }
      , orphanScan :
          < Never
          | EveryHours :
              { interval        : Natural
              , safetyWindowMin : Natural
              }
          >
      , reachableFromPointers   : List Text
      , deleteOnUndeclare       : Bool
      }
```

The bucket's logical layout maps onto S3 prefixes — content-addressed blobs under `blobs/`,
manifests under `manifests/`, mutable pointers under `pointers/`, optional archived topic
exports under `archives/`. Retention on each prefix is delegated to MinIO's native bucket
lifecycle (set via `setBucketLifecycle`).

### Orphan scan (mark-and-sweep)

The reconciler runs the orphan scan on the declared cadence. Algorithm:

1. **Roots**: read every object in each `reachableFromPointers` prefix. Each pointer object's
   body names a manifest content-hash.
2. **Mark**: for each pointer, read the named manifest; collect every blob hash the manifest
   references. Transitively expand if manifests reference manifests.
3. **Sweep**: list every object under `blobs/` and `manifests/`. Compute the reachable set.
   Any object not in the reachable set AND whose `LastModified` is older than
   `now - safetyWindowMin` → hard delete.
4. **Audit**: every delete publishes to `audit.reconcile.<consumer>` keyed by the object key.

Hard delete is the substrate default. Deterministic-training-recoverability is the safety net:
anything mistakenly deleted can be re-derived by re-running the deterministic training run.

If `deleteOnUndeclare = True`, removing a bucket entry from `LifecyclePolicy.buckets` causes
the next reconcile tick to delete the bucket (after emptying it). If `False`, the bucket is
left alone and ownership effectively transfers out of the substrate's purview.

## Top-level LifecyclePolicy

```dhall
let LifecyclePolicy =
      { reconcileEverySeconds : Natural
      , topics                : List { topic : Text, lifecycle : TopicLifecycle }
      , buckets               : List BucketLifecycle
      , auditTopic            : Text
      , leaderControlTopic    : Text
      }
```

Consumers ship `LifecyclePolicy` as part of their orchestrator Dhall config (alongside
`BootConfig` and `LiveConfig`). The substrate decodes it and `runReconciler` drives the desired
state.

Default values for `auditTopic` and `leaderControlTopic`:

- `auditTopic`: `audit.reconcile.<consumer>` (consumer = the `BootConfig.app` name field)
- `leaderControlTopic`: `control.reconcile.leader.<consumer>`

## Batching and scheduling (orchestrator)

The orchestrator daemon owns request batching as a substrate primitive — see
[../engineering/batching.md](../engineering/batching.md) for the full specification of the
`Batcher`, the multi-bucket `Scheduler` (hard-deadline preemption + weighted fair queueing +
optional bucket-affinity dwell), flush strategies, backpressure modes, deadline semantics,
and telemetry surface.

`BatchingPolicy` and `SchedulerPolicy` are part of `LiveConfig` (SIGHUP-reloadable), not
`LifecyclePolicy`. Batch sizing and scheduling weights are tuned at runtime against observed
workload; topic and bucket lifecycles are structural and change on different cadences. The
two surfaces are intentionally separate.

The `WorkflowEvent.deadline_at` field (see [../reference/proto_surface.md](../reference/proto_surface.md))
is the substrate-level deadline carrier; the batcher honors it for force-flush decisions and
drops expired requests with typed telemetry.

## Library modules

- `Daemon.Pulsar.Admin` — typed admin operations: `createTopic`, `deleteTopic`,
  `terminateTopic`, `setRetention`, `setCompaction`, `setDedupWindow`, `listTopics`,
  `exportTopicToObject`, `importTopicFromObject`.
- `Daemon.MinIO.Admin` — typed bucket operations: `createBucket`, `setBucketLifecycle`,
  `listBuckets`, `listObjectsByPrefix`, `deleteObject`.
- `Daemon.MinIO.Cache` — ephemeral local cache for blobs fetched from MinIO, plus an explicit
  pin API:

  ```haskell
  pin       :: HasMinIO m => ObjectRef -> m ()
  unpin     :: HasMinIO m => ObjectRef -> m ()
  isPinned  :: HasMinIO m => ObjectRef -> m Bool
  ```

  The cache enforces a quota plus LRU/TTL eviction; eviction never touches pinned refs.
  Consumers pin hot artifacts (`infernix` currently-served models; `jitML` active-experiment
  checkpoints) so eviction cannot reclaim them mid-request. Pinning is process-local and
  non-durable; on daemon restart the pin set is empty until the consumer re-asserts.
- `Daemon.Config.LifecyclePolicy` — Dhall decoders for the policy types above.
- `Daemon.Audit` — compacted-topic helper: keyed write + replay-on-startup.
- `Daemon.Reconciler` — the leader-elected reconciliation loop:

```haskell
runReconciler
  :: (HasPulsar m, HasMinIO m)
  => BootConfig 'Orchestrator app
  -> LifecyclePolicy
  -> m ()
```

## Concurrency contract

`runOrchestrator` and `runReconciler` run as two concurrent threads inside the same orchestrator
process. They share the `HasPulsar` / `HasMinIO` / `HasHarbor` capabilities; they do not share
mutable state.

The reconciler **never** modifies an in-flight Pulsar message or a freshly-written MinIO
object. Its operations are scoped to admin (topic create / delete / configure, bucket create /
configure) and to mark-and-sweep cleanup with safety windows.

If a workload handler (running in `runOrchestrator` on any replica, or `runWorker` on any
worker) is in the middle of a multi-step write (blob → manifest → pointer), the safety window
guarantees the reconciler will not collect the intermediate blob.

## Cross-references

- Daemon roles: [daemon_roles.md](daemon_roles.md)
- Pulsar / MinIO source-of-truth split: [pulsar_minio_ssot.md](pulsar_minio_ssot.md)
- Library consumption model: [library_consumption_model.md](library_consumption_model.md)
- Pulsar topic inventory (test harness): [../engineering/pulsar_topics.md](../engineering/pulsar_topics.md)
- MinIO bucket inventory (test harness): [../engineering/minio_buckets.md](../engineering/minio_buckets.md)
- Orchestration topology primitives: [../engineering/orchestration_topologies.md](../engineering/orchestration_topologies.md)
- Batching and scheduling: [../engineering/batching.md](../engineering/batching.md)
- Protobuf inventory (audit envelope, lineage refs): [../reference/proto_surface.md](../reference/proto_surface.md)
- Testing strategy (workflow coverage): [../development/testing_strategy.md](../development/testing_strategy.md)
- Plan-level role contract: [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)
