# Phase 2: Typeclasses — Pulsar, MinIO, Engine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-library-scaffolding-and-cabal-package.md](phase-1-library-scaffolding-and-cabal-package.md), [phase-3-daemon-lifecycle-and-config.md](phase-3-daemon-lifecycle-and-config.md)

> **Purpose**: Land the public typeclass surface (`HasPulsar`, `HasMinIO`, `HasEngine`), the
> engine-handle sum (`SubprocessEngine`, `NativeEngine`), the protobuf schemas, and reference
> mock instances under the test tree.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 1
**Implementation**: none yet

## Phase Objective

Bring the substrate's public typeclass surface into existence so consumers can write code
against it (against mock instances during development) before the substrate ships any base
loops. Also lands the protobuf schemas and the generated `Daemon.Proto.*` modules they
produce.

## Sprints

### Sprint 2.1: Protobuf schemas + code generation [Planned]

**Status**: Planned
**Docs to update**: `documents/reference/proto_surface.md`, `system-components.md`

#### Objective

Land every `.proto` file listed in `documents/reference/proto_surface.md` and wire
proto-lens-driven code generation into the cabal stanza.

#### Deliverables

- `proto/daemon_substrate/workflow.proto`, `control.proto`, `orchestrator_worker.proto`,
  `lifecycle.proto`
- `proto/daemon_substrate_test/mock.proto`
- `daemon-substrate.cabal` `build-tool-depends: proto-lens-protoc`, `autogen-modules`
- Generated modules `Daemon.Proto.Workflow`, `Daemon.Proto.Control`,
  `Daemon.Proto.OrchestratorWorker`, `Daemon.Proto.Lifecycle`, `Daemon.Proto.Test.Mock` build
  and are importable

#### Validation

`cabal build all` succeeds with the generated modules. A `daemon-substrate-unit` test
round-trips one message of each type (encode → decode → equality).

#### Remaining Work

(scoped when the sprint opens)

### Sprint 2.2: `HasPulsar` typeclass [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `documents/engineering/pulsar_topics.md`, `system-components.md`

#### Objective

Define `Daemon.Pulsar.HasPulsar` with the methods named in
`documents/architecture/library_consumption_model.md`: `pulsarPublish`, `pulsarSubscribe`,
`pulsarConsume`, `pulsarAcknowledge`, `pulsarSeek`. Define `SubscriptionMode`,
`SubscriptionName`, `Delivery`, and the supporting types.

Ship a reference mock instance under `test/unit/` that holds an in-memory map of topics → byte
ledgers so the typeclass can be exercised in pure tests.

#### Deliverables

- `src/Daemon/Pulsar.hs` populated
- mock instance in `test/unit/Daemon/Mock/Pulsar.hs`
- unit tests covering: publish-then-consume, ack, seek, dedup window, subscription mode
  rejection (`Exclusive` rejects second subscriber)

#### Validation

`cabal test daemon-substrate-unit` exercises every method against the mock.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 2.3: `HasMinIO` typeclass + cache wrapper [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `documents/engineering/minio_buckets.md`, `system-components.md`

#### Objective

Define `Daemon.MinIO.HasMinIO` with `minioGet`, `minioPutIfAbsent`, `minioCasPointer`,
`minioListObjects`, `minioDeleteObject`. Define `Daemon.MinIO.Cache` with the phantom-typed
`Bytes (a :: Authority)` and `readWithCache`.

Ship a reference mock instance under `test/unit/`.

#### Deliverables

- `src/Daemon/MinIO.hs`, `src/Daemon/MinIO/Cache.hs` populated
- mock instance in `test/unit/Daemon/Mock/MinIO.hs`
- unit tests covering: get/put round-trip, ETag CAS success and failure, cache cold path, cache
  warm path, cache eviction policy

#### Validation

`cabal test daemon-substrate-unit` exercises every method against the mock.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 2.4: `HasEngine` typeclass + engine-handle sum [Planned]

**Status**: Planned
**Blocked by**: 2.1
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Define `Daemon.Engine.HasEngine`, `EngineRequest`, `EngineResponse`, `EngineError`, and the
`SubprocessEngine` / `NativeEngine` constructors. Both variants implement `HasEngine`.

#### Deliverables

- `src/Daemon/Engine.hs` populated
- a trivial native echo engine and a trivial subprocess echo engine, both under
  `test/unit/Daemon/Mock/Engine.hs`
- unit tests covering: round-trip through both variants, error propagation, timeout (subprocess
  variant)

#### Validation

`cabal test daemon-substrate-unit` exercises both engine variants.

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/pulsar_topics.md` updates from "test-harness target" to actual
  current-state once the typeclass exists
- `documents/engineering/minio_buckets.md` same
- `documents/engineering/cabal_layout.md` updates with the proto code-gen wiring

**Reference docs to create/update:**
- `documents/reference/proto_surface.md` updates from "planned" to current-state declarative

**Cross-references to add:**
- `system-components.md` flips the relevant typeclass and proto rows to `Implemented: yes`
