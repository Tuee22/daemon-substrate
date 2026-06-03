# Phase 3: BootConfig / LiveConfig / LifecyclePolicy + Lifecycle + Signal Handling

**Status**: Authoritative source
**Supersedes**: `phase-3-daemon-lifecycle-and-config.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-2-capability-typeclasses-and-admin-surfaces.md](phase-2-capability-typeclasses-and-admin-surfaces.md), [phase-4-engine-mock-protos-audit.md](phase-4-engine-mock-protos-audit.md)

> **Purpose**: Land the typed configuration shapes (`BootConfig role app`, `LiveConfig`,
> `LifecyclePolicy`), the 7-phase lifecycle state machine, the SIGHUP / SIGTERM / SIGINT
> handlers, the readiness / health / metrics HTTP endpoints, and the `runService` entry
> point that every consumer daemon binary will call.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 2
**Implementation**: none yet

## Phase Objective

Build the scaffolding that surrounds every base loop: typed configuration (split into
boot-time immutable and SIGHUP-reloadable runtime), a phase enum and the transitions between
them, signal handlers wired to graceful drain and live-config reload, and the HTTP listener
that serves `/readyz` / `/healthz` / `/metrics`.

This phase produces nothing visible to a consumer's main loop yet — that arrives in Phase 5.
But every base-loop sprint in Phase 5 reads from the lifecycle scaffolding, so it lands first.

## Sprints

### Sprint 3.1: `BootConfig role app` + Dhall decoder [Planned]

**Status**: Planned
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Config.BootConfig role app`, the `Role = Worker | Orchestrator` tag, and the
Dhall decoder. The `app` type parameter is the consumer-specific plug; the substrate provides
a `()` default and a `Dhall.FromDhall app` constraint at the use site.

#### Deliverables

- `src/Daemon/Config/BootConfig.hs` populated
- `dhall/orchestrator.dhall` and `dhall/worker.dhall` schema stubs for the test harness
- unit tests covering: decode round-trip, schema mismatch fails closed, role tag enforcement

### Sprint 3.2: `LiveConfig` + SIGHUP reload [Planned]

**Status**: Planned
**Blocked by**: 3.1
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Config.LiveConfig` — the SIGHUP-reloadable runtime configuration shape (retry
policy, dedup cache size + TTL, drain deadline, batch size, batch latency window). Decode from
Dhall on startup; re-decode from the same path on SIGHUP without restarting the daemon.

#### Deliverables

- `src/Daemon/Config/LiveConfig.hs` populated
- `dhall/live.dhall` schema stub
- unit tests covering: initial decode, reload-after-edit observation, decode-failure-on-reload
  preserves the previous LiveConfig

### Sprint 3.3: `LifecyclePolicy` Dhall decoders [Planned]

**Status**: Planned
**Blocked by**: 3.1
**Docs to update**: `documents/architecture/lifecycle_policy.md`, `system-components.md`

#### Objective

Define `Daemon.Config.LifecyclePolicy` — the Dhall decoders for `TopicLifecycle` (the four
modes `Ephemeral` / `ContinuousWithArchive` / `FiniteSession` / `OnlineLearning`),
`BucketLifecycle`, and the top-level `LifecyclePolicy` record. The reconciler in Phase 5
consumes these.

#### Deliverables

- `src/Daemon/Config/LifecyclePolicy.hs` populated
- `dhall/lifecycle-policy.dhall` schema definition
- unit tests covering: decode round-trip for every `TopicLifecycle` variant, decode round-trip
  for `BucketLifecycle` with `orphanScan = Never` and `EveryHours`, the safety-window default

### Sprint 3.4: 7-phase lifecycle state machine [Planned]

**Status**: Planned
**Blocked by**: 3.2, 3.3
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Define `Daemon.Lifecycle.LifecyclePhase` (`Load | Prereq | Acquire | Ready | Serve | Drain | Exit`),
`DaemonRuntime` (live record holding `BootConfig`, `LiveConfig`, `LifecyclePolicy`, acquired
capability clients, subscription handles, ready flag), and `runDaemonLifecycle` driving the
phase progression.

#### Deliverables

- `src/Daemon/Lifecycle.hs` populated
- unit tests covering each phase transition; probe failure surfacing as a failed phase

### Sprint 3.5: Signal handlers + readiness HTTP [Planned]

**Status**: Planned
**Blocked by**: 3.4
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Install SIGTERM / SIGINT handlers that move the daemon from `Serve` to `Drain`. Install SIGHUP
handler that triggers `LiveConfig` reload. Expose `/healthz`, `/readyz`, `/metrics` HTTP
endpoints reading from `DaemonRuntime`. The HTTP listener is intentionally minimal — no
routing framework, no auth, no JSON-RPC. Just the three k8s liveness probes.

#### Deliverables

- `src/Daemon/Signal.hs` populated (`applyDaemonSignal :: DaemonControl -> DaemonSignal -> IO DaemonControlSnapshot`)
- `src/Daemon/Lifecycle/Endpoints.hs` populated (minimal HTTP server stanza)
- unit tests covering signal effects on `DaemonRuntime`; integration of HTTP routes covered in
  Phase 8's `daemon-substrate-lifecycle` stanza

### Sprint 3.6: `runService` entry point [Planned]

**Status**: Planned
**Blocked by**: 3.5
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `runService :: (FromDhall app) => (BootConfig role app -> LiveConfig -> IO ()) -> IO ()`
as the one entry every consumer daemon calls. It parses CLI args, decodes Dhall, instantiates
the capability clients, runs the lifecycle to `Serve`, then hands control to the consumer-
supplied callback.

#### Deliverables

- `src/Daemon/Lifecycle.hs` export of `runService`
- unit tests covering: CLI arg parsing, Dhall decode failure → graceful exit, callback invocation

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/architecture/library_consumption_model.md` updates `BootConfig role app` and
  `LiveConfig` from "planned shape" to current-state.
- `documents/architecture/daemon_roles.md` updates the signal / lifecycle paragraphs from
  forward-looking to current-state.
- `documents/architecture/lifecycle_policy.md` updates the "Library modules" entry for
  `Daemon.Config.LifecyclePolicy` from forward-looking to current-state.

**Reference docs to create/update:**
- none unique to this phase (`LifecyclePhase` / `ReadinessReport` proto lands in Phase 4).

**Cross-references to add:**
- `system-components.md` flips the lifecycle / config module rows to `Implemented: yes`.
