# Phase 4: Worker and Orchestrator Base Loops

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-daemon-lifecycle-and-config.md](phase-3-daemon-lifecycle-and-config.md), [phase-5-kind-cluster-and-helm-chart.md](phase-5-kind-cluster-and-helm-chart.md)

> **Purpose**: Land `Daemon.Worker.runWorker`, `Daemon.Orchestrator.runOrchestrator`, the
> mock engine implementation, and the `WorkflowState` ownership pattern that both base loops
> use.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 3
**Implementation**: none yet

## Phase Objective

Bring the two daemon roles to life. After this phase closes, a consumer can wire its own
config and engine into `runWorker` or `runOrchestrator` and get a daemon that consumes from
Pulsar, reads MinIO, dispatches to its engine, and publishes results. The test harness's
mock engine ships alongside so the substrate has something to validate the base loops with
in Phase 7.

## Sprints

### Sprint 4.1: `Daemon.WorkflowState` [Planned]

**Status**: Planned
**Docs to update**: `documents/architecture/pulsar_minio_ssot.md`, `system-components.md`

#### Objective

Land the `WorkflowOwner state event` shape: `rehydrate` (replay snapshot + tail at
`AcquireClients`), `recordEvent` (append-to-Pulsar then advance in-memory fold), snapshot
cadence.

#### Deliverables

- `src/Daemon/WorkflowState.hs` populated
- unit tests covering: rehydrate from empty, rehydrate from snapshot + tail, recordEvent
  publish-before-advance invariant, snapshot-every-N behavior

#### Validation

`cabal test daemon-substrate-unit` covers the workflow-state state machine.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 4.2: `Daemon.Consumer.consumerStep` [Planned]

**Status**: Planned
**Blocked by**: 4.1
**Docs to update**: `documents/engineering/pulsar_topics.md`, `system-components.md`

#### Objective

Land the canonical consume-decode-dispatch-ack loop used by both worker and orchestrator.
Includes the L3 dedup cache (rejects duplicate `EventId`s within the window).

#### Deliverables

- `src/Daemon/Consumer.hs` (an internal module, not consumer-facing typeclass surface)
- unit tests covering: happy-path consume-ack, ack-on-success, nack-on-engine-failure, dedup
  window behavior

#### Validation

`cabal test daemon-substrate-unit` covers the consumer-step loop.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 4.3: `Daemon.Worker.runWorker` [Planned]

**Status**: Planned
**Blocked by**: 4.2
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the worker base loop: subscribe to assigned Pulsar topics, consume, decode payloads,
dispatch to the engine via `HasEngine`, publish results back to Pulsar, manage local cache.

#### Deliverables

- `src/Daemon/Worker.hs` populated
- unit tests against the mock engine + mock Pulsar + mock MinIO + mock cache

#### Validation

`cabal test daemon-substrate-unit` runs a full worker loop end-to-end with mock services.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 4.4: `Daemon.Orchestrator.runOrchestrator` [Planned]

**Status**: Planned
**Blocked by**: 4.2
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Land the orchestrator base loop: fan-in from upstream topics, batch, fan-out to per-cohort
worker topics, collect results, fan-back to upstream response topics. Also includes the
WAN→MinIO hydration interface point (substrate provides the hook; the test harness implements
a mock hydration).

The base loop must be **safe to run as N concurrent replicas**. It attaches to its
subscriptions in `Shared` mode, holds no replica-local authoritative cross-request state,
and tolerates message redelivery on replica loss. Any per-batch state (in-flight
correlation tracking, pending hydration jobs) lives only for the lifetime of one
`recordEvent` → response cycle; nothing persists in-memory across redeliveries to a
different replica. The unit test suite must include a multi-replica simulation that runs
two `runOrchestrator` instances against the same mock Pulsar broker and asserts no
duplicate dispatches.

#### Deliverables

- `src/Daemon/Orchestrator.hs` populated
- unit tests against mock services

#### Validation

`cabal test daemon-substrate-unit` runs a full orchestrator loop end-to-end with mocks.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 4.5: Mock engine implementation [Planned]

**Status**: Planned
**Blocked by**: 4.3
**Docs to update**: `documents/engineering/mock_engine.md`, `system-components.md`

#### Objective

Land the test harness's mock engine: a `NativeEngine` that returns deterministic placeholder
bytes, performs mock MinIO reads, and uses the local cache. Spec is
[`../documents/engineering/mock_engine.md`](../documents/engineering/mock_engine.md).

#### Deliverables

- mock engine module under `src/Daemon/Test/Mock/Engine.hs` (exposed for the
  `daemon-substrate-test` executable; not part of consumer-facing surface)
- unit tests covering: happy path, forced failure path, cache cold/warm paths, output write
  path

#### Validation

`cabal test daemon-substrate-unit` exercises every documented mock-engine behavior.

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/mock_engine.md` updates from "planned" to current-state.
- `documents/architecture/daemon_roles.md` updates worker / orchestrator responsibilities from
  forward-looking to current-state.
- `documents/architecture/pulsar_minio_ssot.md` updates the workflow-state ownership
  paragraphs from forward-looking to current-state.

**Reference docs to create/update:**
- none unique to this phase

**Cross-references to add:**
- `system-components.md` flips `Daemon.Worker`, `Daemon.Orchestrator`, `Daemon.WorkflowState`
  to `Implemented: yes`.
