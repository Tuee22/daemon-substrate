# Phase 8: Test Harness Integration

**Status**: Authoritative source
**Supersedes**: `phase-7-test-harness-integration.md` (renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the `daemon-substrate-test` executable, the four cabal test stanzas, and
> the integration coverage that proves every shared workflow either consumer needs works on
> a real kind cluster, on both cohorts, with the mock engine.

## Phase Status

**Status**: Active
**Implementation**: Sprints 8.1, 8.2, 8.3, 8.4, and 8.5 are implemented and locally
validated. Sprint 8.6 is active: `daemon-substrate-test test ...` delegates to Cabal,
`daemon-substrate-test cluster ...` executes concrete kind / kubectl / helm / Docker image
build and kind image-load actions, the local Harbor / Pulsar / MinIO dependency charts are
deployable, Pulsar and MinIO admin actions run through the live pods, the chart mounts
PVC-backed state into the dependency pods, the Linux project Dockerfile starts `cluster up`
by default, and the harness `service` command runs the live worker / orchestrator loops.
Apple Silicon preserved-state kind bring-up and in-place `cluster up` idempotency are
validated. Native Pulsar admin payloads, audit seek/replay handling, named Failover
consumer leadership, MinIO bucket/lifecycle idempotency, stable Pulsar standalone
BookKeeper identity, service-loop logging, managed edge-port forwarding, Apple host-worker
handoff, and a live request -> orchestrator -> host worker -> response workflow handoff are
implemented and validated on the Apple Silicon live kind cluster. Full live-cluster closure
remains open because Linux CPU cohort validation has not run.

**Remaining Work**:

- Sprint 8.6: validate real kind-cluster integration on the Linux CPU cohort.

## Phase Objective

Make the test harness real. The substrate's tests are the only *direct* validation that
everything between Pulsar / MinIO and the engine boundary works end-to-end. After Phase 8
closes, `daemon-substrate-test test all` on either cohort asserts every row in the workflow
coverage table in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md).

## Sprints

### Sprint 8.1: `daemon-substrate-test` executable [Done]

**Status**: Done
**Implementation**: `app/test/Main.hs`, `src/Daemon/Test/CLI.hs`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Cluster.hs`,
`src/Daemon/Test/CLI/Tests.hs`, `src/Daemon/Test/CLI/Service.hs`, `daemon-substrate.cabal`,
`test/unit/Main.hs`
**Docs to update**: `../documents/reference/cli_surface.md`, `system-components.md`

#### Objective

Land `app/test/Main.hs` implementing the command surface described in
[`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md):
`cluster {up,down,status}`, `test {unit,lifecycle,integration,lint,all}`, `service --role <r>
--config <path>`.

#### Deliverables

- `app/test/Main.hs` with the option parser (using `Daemon.Lifecycle.runService`)
- delegate functions under `src/Daemon/Test/CLI/*`
- subcommand smoke tests in `daemon-substrate-unit`

#### Validation

Validated with:

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- built `daemon-substrate-test --help`
- built `daemon-substrate-test test unit`

The local help output lists every documented top-level command. The `test unit` command
resolves `cabal` to an absolute executable and delegates to `cabal test
daemon-substrate-unit`.

### Sprint 8.2: `daemon-substrate-unit` stanza [Done]

**Status**: Done
**Implementation**: `test/unit/Main.hs`, `daemon-substrate.cabal`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Tests.hs`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Finalize the `daemon-substrate-unit` stanza. Most unit coverage was authored alongside each
typeclass / base loop in Phases 2–5; this sprint consolidates the test-suite wiring and adds
any cross-module pure tests not naturally covered earlier.

#### Deliverables

- `test/unit/Spec.hs` with hspec / tasty driver
- helpers under `test/unit/Daemon/Test/Unit/*`
- coverage of every row in the testing strategy table marked "no cluster needed"

#### Validation

Validated with:

- `cabal test daemon-substrate-unit`

The local unit suite exits 0. Counterpart cohort validation remains part of the Phase 8
full-suite closure batch.

### Sprint 8.3: `daemon-substrate-lifecycle` stanza [Done]

**Status**: Done
**Implementation**: `test/lifecycle/Main.hs`, `daemon-substrate.cabal`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Tests.hs`
**Docs to update**: `../documents/development/testing_strategy.md`, `system-components.md`

#### Objective

Land the lifecycle test suite: daemon spawned as a real process; SIGHUP / SIGTERM exercised;
`/readyz` polled; LiveConfig reload validated. No kind cluster needed.

#### Deliverables

- `test/lifecycle/Spec.hs`
- helpers under `test/lifecycle/Daemon/Test/Lifecycle/*` for process spawning + signal sending
- `daemon-substrate-test test lifecycle` preflights nothing and delegates to
  `cabal test daemon-substrate-lifecycle`

#### Validation

Validated with:

- `cabal test daemon-substrate-lifecycle`

The local lifecycle suite exits 0. Process-level SIGHUP/SIGTERM coverage remains tracked by
the later lifecycle-suite expansion.

### Sprint 8.4: `daemon-substrate-integration` stanza [Done]

**Status**: Done
**Implementation**: `test/integration/Main.hs`, `daemon-substrate.cabal`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Tests.hs`
**Docs to update**: `../documents/development/testing_strategy.md`, `system-components.md`

#### Objective

Land the `daemon-substrate-integration` Cabal stanza and CLI delegation point that owns the
cluster-requiring rows in the testing-strategy table. The live assertions for rows 3-36 close
under Sprint 8.6, where the executable has a real cluster runner and service loops to drive.

#### Deliverables

- `test/integration/Main.hs` Cabal test-suite entry point.
- `daemon-substrate-test test integration` delegates to
  `cabal test daemon-substrate-integration`.
- the cluster is brought up via `hostbootstrap cluster up` (delegating inward to
  `daemon-substrate-test cluster up`) before the live row coverage is executed.

#### Validation

Validated with:

- `cabal test daemon-substrate-integration`

The local integration stanza exits 0. Live kind-cluster integration coverage remains gated on
Sprint 8.6 and Phase 7 Sprint 7.3. Target coverage for that live suite remains:

- worker / orchestrator fan-in / fan-out / result bridge
- MinIO `Store` (blobs / manifests / pointers / CAS) cold + warm + eviction
- worker pod replacement (Linux); MinIO StatefulSet replacement
- reconciler creates declared topics + buckets; idempotent on re-run
- leader election (two orchestrator replicas, only one ticks); leader failover with audit
  replay
- per-`TopicLifecycle`-mode: `Ephemeral`, `ContinuousWithArchive`, `FiniteSession` (including
  session-end → terminate-and-export and session-resume → topic re-open),
  `OnlineLearning`
- MinIO orphan scan: safety window honored, unreachable + past-window objects hard-deleted
- `Daemon.WorkflowState` rehydration on `AcquireClients` reconstructs the in-memory fold to
  byte-identical state from Pulsar replay (row 33; representative of jitML training-state and
  AlphaZero MCTS-tree rehydration, and infernix durable conversation context)
- producer-side dedup: identical idempotency key → exactly one consumer delivery (row 34;
  representative of `infernix.InferenceRequest.client_idempotency_key`)
- engine forced failure: `MockRequest.force_failure = true` → `FailurePayload` propagates to
  caller without retry (row 35; representative of `InferenceResult.status = Failed`)
- Apple-Silicon host-daemon ↔ in-cluster Pulsar handshake survives `cluster down` / `up`
  (row 36; representative of jitML `ForwardToHost` and infernix Apple host daemon)

### Sprint 8.5: `daemon-substrate-haskell-style` stanza (lint + doc validator) [Done]

**Status**: Done
**Implementation**: `test/haskell-style/Main.hs`, `daemon-substrate.cabal`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Tests.hs`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/development/local_dev.md`, `../documents/documentation_standards.md`
(Validation section transitions from forward-looking to current-state),
`phase-0-documentation-and-governance.md` (Sprint 0.5 closes via reference)

#### Objective

Land `daemon-substrate-test test lint`. The sprint owns three gates:

1. `ormolu` formatting check against `src/` and `test/`
2. `hlint` against `src/` and `test/`
3. **Doc validator** implementing the checks named in
   `documents/documentation_standards.md § Validation` (required metadata block, relative-link
   resolution, root-doc metadata, `## Documentation Requirements` retention on phase files,
   root `README.md` reference to both `documents/` and `DEVELOPMENT_PLAN/`)

The doc validator is the deferred Phase 0 Sprint 0.5 obligation. Landing it here closes both
sprints simultaneously.

#### Deliverables

- format / lint orchestration under `src/Daemon/Test/Lint/*`
- `daemon-substrate-haskell-style` cabal stanza wired up
- `src/Daemon/Test/Lint/Docs.hs` implementing the doc-validator checks
- `documents/documentation_standards.md § Validation` rewritten from forward-looking to
  current-state declarative

#### Validation

Validated with:

- `cabal test daemon-substrate-haskell-style`

The existing style suite exits 0 locally. The shared `daemon-substrate-test test ...`
delegate now executes Cabal for every test command; negative lint/doc-validator fixtures
remain future hardening.

### Sprint 8.6: Live command and cluster interpreters [Active]

**Status**: Active
**Implementation**: `src/Daemon/Cluster/Runner.hs`, `src/Daemon/Test/CLI/Cluster.hs`,
`src/Daemon/Test/CLI/Tests.hs`, `src/Daemon/Test/CLI/Service.hs`,
`docker/linux-substrate.Dockerfile`
**Docs to update**: `../documents/reference/cli_surface.md`,
`../documents/engineering/cluster_topology.md`,
`../documents/engineering/hostbootstrap_integration.md`,
`../documents/operations/cluster_bootstrap_runbook.md`, `system-components.md`

**Remaining Work**:

- Linux CPU hostbootstrap container validation and both-cohort kind-cluster `Ready`
  validation remain open.

#### Objective

Turn the executable from parser-plus-local-tests into the real harness entrypoint for both
cohorts: `test ...` runs the selected Cabal suite, `cluster ...` reconciles the live kind
cluster, and `service` runs the actual daemon role loop until terminated.

#### Deliverables

- `daemon-substrate-test test {unit,lifecycle,integration,lint,all}` delegates to Cabal and
  propagates failures through the executable exit code.
- `daemon-substrate-test cluster {up,down,status}` runs the concrete action plan against
  absolute tool paths, builds `daemon-substrate-test:local`, loads it into kind, applies the
  manual StorageClass / PVs, installs the Helm chart, runs Pulsar admin through the broker
  pod, runs MinIO admin through the `mc` sidecar, treats an already-existing kind cluster as
  an idempotent no-op, streams long-running build/load progress, and persists the selected
  edge port.
- Linux CPU project image defaults to `daemon-substrate-test cluster up` when started as a
  `hostbootstrap` service container.
- Apple Silicon `service --role worker` is implemented as a long-running live worker loop.
  The host worker reads the persisted edge-port record, rewrites Pulsar / Pulsar admin /
  MinIO endpoints to localhost, connects through the managed port-forwards, and has been
  validated against a live orchestrator handoff. In-cluster services invoke the executable
  directly with explicit role, live-config, and
  lifecycle-policy arguments so Kubernetes does not dispatch to `/usr/sbin/service`.
- `service --role worker` and `service --role orchestrator` acquire live Pulsar, Pulsar admin,
  MinIO, and mock-engine clients. The orchestrator service normalizes harness topic names to
  persistent Pulsar topics before running the orchestrator and reconciler loops.
- The dependency charts deploy local Harbor, Pulsar, and MinIO StatefulSets with readiness /
  startup probes and PVCs bound to repo-local kind hostPath storage.
- The Pulsar chart runs standalone with a stable advertised broker service and fixed
  BookKeeper port so PVC-backed broker state survives `cluster down && cluster up` cycles.
- The live Pulsar client uses named native consumers for Failover leadership, records
  `ACTIVE_CONSUMER_CHANGE` frames, handles broker-close-on-seek during audit replay, and
  pins loopback broker lookups to the bootstrap connection for single-broker port-forward
  access. It sends admin REST payloads in the shapes required by Pulsar's retention,
  compaction, and deduplication endpoints.
- The live MinIO client treats existing buckets as no-change, configures lifecycle policy
  through S3 XML with checksum headers, and parses S3 list responses for prefix scans.

#### Validation

Validated locally with:

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-lifecycle daemon-substrate-integration
  daemon-substrate-haskell-style`
- built `daemon-substrate-test --help`
- built `daemon-substrate-test test unit`
- built `daemon-substrate-test cluster down`
- `hostbootstrap doctor --spec hostbootstrap.dhall`
- `hostbootstrap build --spec hostbootstrap.dhall`
- `hostbootstrap cluster up --spec hostbootstrap.dhall`
- `launchctl print system/com.hostbootstrap.daemon-substrate`
- `hostbootstrap cluster down --spec hostbootstrap.dhall`
- `helm template daemon-substrate-test ./chart -f chart/values/apple-silicon.yaml`
- `helm template daemon-substrate-test ./chart -f chart/values/linux-cpu.yaml`
- Apple Silicon live `daemon-substrate-test cluster up`, `cluster down && cluster up`
  preserved-state cycle, PV/PVC readiness inspection, Pulsar topic lookup inside the broker
  pod, persisted MinIO / Pulsar data under
  `./.data/kind/apple-silicon/daemon-substrate/`, in-place `cluster up` over an existing
  kind cluster, orchestrator rollout restart, Pulsar subscription stats showing one named
  active Failover consumer for the reconciler leader subscription, managed edge-port
  forwards for Pulsar / Pulsar admin / MinIO, a host worker producing repeated
  `WorkerNoMessage` over `pulsar://127.0.0.1:<pulsarPort>`, and a live smoke event
  (`live-smoke-1780601659`) returning `WorkerSuccess` on `test.response` with payload
  `live-smoke-payload`.

Full live-cluster validation remains open until Linux CPU cohort validation lands.

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/cabal_layout.md` updates with the four-stanza shape.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` updates from "planned" to current-state declarative.

**Development docs to create/update:**
- `../documents/development/testing_strategy.md` updates every coverage row from
  forward-looking to current-state declarative.

**Cross-references to add:**
- `system-components.md` flips `daemon-substrate-test`, `daemon-substrate-unit`,
  `daemon-substrate-lifecycle`, `daemon-substrate-integration`, and
  `daemon-substrate-haskell-style` rows to `Implemented: yes`. Phase 8 closure is the closing
  milestone for the substrate-library buildout.
