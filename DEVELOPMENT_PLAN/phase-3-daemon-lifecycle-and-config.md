# Phase 3: Daemon Lifecycle and Config

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-2-typeclasses-pulsar-minio-engine.md](phase-2-typeclasses-pulsar-minio-engine.md), [phase-4-worker-and-orchestrator-base-loops.md](phase-4-worker-and-orchestrator-base-loops.md)

> **Purpose**: Land the daemon lifecycle scaffolding — `BootConfig role app`, `DaemonRuntime`,
> `LifecyclePhase`, signal handlers, readiness reporting — so Phase 4 has somewhere for the
> base loops to live.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 2
**Implementation**: none yet

## Phase Objective

Build the scaffolding that surrounds the worker and orchestrator base loops: a typed
configuration shape (parameterized by role and consumer-specific app data), a runtime record
that holds acquired clients and lifecycle state, a phase enum that names each step from
`Bootstrap` to `Exit`, signal handlers wired to graceful drain, and an HTTP readiness
endpoint.

This phase produces nothing visible to a consumer's main loop yet — that arrives in Phase 4.
But every base-loop sprint in Phase 4 reads from `DaemonRuntime`, so the scaffolding must
land first.

## Sprints

### Sprint 3.1: `BootConfig role app` + Dhall decoders [Planned]

**Status**: Planned
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Config.BootConfig role app`, the `Role = Worker | Orchestrator` tag, and the
`Dhall` decoder. The `app` type parameter is the consumer-specific plug; the substrate
provides a `()` default and a way to substitute.

#### Deliverables

- `src/Daemon/Config.hs` populated
- `dhall/orchestrator.dhall` and `dhall/worker.dhall` schema stubs for the test harness
- unit tests covering: Dhall decode round-trip, schema mismatch fails closed, role tag
  enforcement

#### Validation

`cabal test daemon-substrate-unit` covers every decoder path.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 3.2: `DaemonRuntime` + `LifecyclePhase` [Planned]

**Status**: Planned
**Blocked by**: 3.1
**Docs to update**: `documents/reference/proto_surface.md` (LifecyclePhase enum), `system-components.md`

#### Objective

Define `Daemon.Lifecycle.DaemonRuntime` (the live record carrying boot config, acquired
clients, ready flag, subscription handles) and `LifecyclePhase` (the enum from
`proto/daemon_substrate/lifecycle.proto`). Wire the phase progression
`Bootstrap → AcquireClients → ProbeClients → Ready → Draining → Exit`.

#### Deliverables

- `src/Daemon/Lifecycle.hs` populated
- `runDaemonLifecycle` function with the phase-progression machinery
- unit tests covering: each phase transition, probe failure surfacing as a failed phase,
  graceful drain on simulated SIGTERM

#### Validation

`cabal test daemon-substrate-unit` covers the lifecycle state machine.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 3.3: Signal handlers and readiness reporting [Planned]

**Status**: Planned
**Blocked by**: 3.2
**Docs to update**: `documents/architecture/daemon_roles.md`, `system-components.md`

#### Objective

Install SIGTERM / SIGINT handlers that move the daemon from `Ready` to `Draining`. Expose
`/healthz` and `/readyz` HTTP endpoints reading from `DaemonRuntime`.

#### Deliverables

- signal handler installation in `Daemon.Lifecycle`
- HTTP server stanza in `Daemon.Lifecycle.Http` (or equivalent)
- unit tests against the readiness reporter; integration of HTTP routes covered later

#### Validation

Sending SIGTERM to a daemon running in a test driver transitions the phase as expected; the
`/readyz` response shape matches the protobuf `ReadinessReport` schema.

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/architecture/library_consumption_model.md` updates `BootConfig role app` from
  "planned shape" to current-state.
- `documents/architecture/daemon_roles.md` updates the signal/lifecycle paragraphs from
  forward-looking to current-state.

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` updates `LifecyclePhase` and `ReadinessReport` from
  "planned" to current-state.

**Cross-references to add:**
- `system-components.md` flips the lifecycle module rows to `Implemented: yes`.
