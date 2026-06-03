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

### Sprint 5.1: `Daemon.Consumer` + `Daemon.WorkflowState` [Planned]

**Status**: Planned
**Docs to update**: `documents/engineering/pulsar_topics.md`,
`documents/architecture/pulsar_minio_ssot.md`, `system-components.md`

#### Objective

Land the canonical consume-decode-dispatch-ack primitive used by every base loop. Includes the
L3 dedup cache (`LiveConfig`-tuned) and the typed `HandlerRouter`. Land
`Daemon.WorkflowState` (append-to-Pulsar then advance in-memory fold; rehydrate on
`AcquireClients`).

#### Deliverables

- `src/Daemon/Consumer.hs` populated
- `src/Daemon/WorkflowState.hs` populated
- unit tests covering: happy-path consume-ack, ack-on-success, nack-on-engine-failure, dedup
  window behavior, workflow-state rehydrate-from-snapshot

### Sprint 5.2: `runWorker` [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the worker base loop: subscribe to assigned Pulsar topics, consume via `Daemon.Consumer`,
decode payloads, dispatch via `HasEngine`, publish results, manage the ephemeral local cache.

#### Deliverables

- `src/Daemon/Worker.hs` populated
- unit tests against the mock engine + filesystem Pulsar + filesystem MinIO

### Sprint 5.3: `runOrchestrator` [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the orchestrator base loop: fan-in from upstream topics, batch per consumer policy,
fan-out to per-cohort worker topics, collect results, fan-back to upstream response topics.

The base loop must be **safe to run as N concurrent replicas**. It attaches to its
subscriptions in `Shared` mode, holds no replica-local authoritative cross-request state, and
tolerates message redelivery on replica loss.

#### Deliverables

- `src/Daemon/Orchestrator.hs` populated
- unit tests covering single-replica and multi-replica simulation (two `runOrchestrator`
  instances against the same filesystem Pulsar broker; assert no duplicate dispatches)

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
- `documents/architecture/lifecycle_policy.md` updates the reconciler-implementation
  references from forward-looking to current-state.
- `documents/architecture/daemon_roles.md` updates the orchestrator section to current-state
  for the concurrent reconciler thread.
- `documents/architecture/pulsar_minio_ssot.md` updates the workflow-state ownership
  paragraphs from forward-looking to current-state.

**Reference docs to create/update:**
- none unique to this phase.

**Cross-references to add:**
- `system-components.md` flips `Daemon.Consumer`, `Daemon.WorkflowState`, `Daemon.Worker`,
  `Daemon.Orchestrator`, `Daemon.Bridge`, `Daemon.Bootstrap`, `Daemon.Reconciler` rows to
  `Implemented: yes`.
