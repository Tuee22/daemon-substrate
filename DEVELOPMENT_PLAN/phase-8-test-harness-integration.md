# Phase 8: Test Harness Integration

**Status**: Authoritative source
**Supersedes**: `phase-7-test-harness-integration.md` (renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the `daemon-substrate-test` executable, the four cabal test stanzas, the
> live cluster interpreters, and the integration readiness gate that proves the harness reaches
> the supported kind topology on both cohorts with the mock engine deployed.

## Phase Status

**Status**: Done

Sprints 8.1 through 8.6 closed against the original host-keyed bootstrap:
`daemon-substrate-test test ...` delegates to Cabal, `cluster ...` executes concrete kind /
kubectl / helm / Docker image build and kind image-load actions, the local Harbor / Pulsar /
MinIO dependency charts are deployable, Pulsar and MinIO admin actions run through the live
pods, the chart mounts PVC-backed state into the dependency pods, the Linux project
Dockerfile starts `cluster up` by default and keeps the service container resident after a
successful run, and the harness `service` command runs the live worker / orchestrator loops.
Apple Silicon preserved-state kind bring-up, in-place `cluster up` idempotency, managed
edge-port forwarding, host-worker handoff, and a live request -> orchestrator -> host worker
-> response workflow handoff are validated. Linux hostbootstrap container bring-up,
two-cycle preserved-state kind bring-up, Ready workload state, and the
`daemon-substrate-integration` live readiness gate are validated. That work remains valid and
is not being rewritten.

Sprint 8.7 is closed against the acceleration-keyed bootstrap shape: `daemon-substrate-test`
now exposes `check-code`, cluster commands accept an explicit execution model supplied by the
hostbootstrap spec, `detectClusterCohort` OS branching is removed, the integration readiness
gate keys node and worker expectations from the persisted execution-model marker, and
`Daemon.Test.Matrix` records the 3×3 execution-model × workflow-archetype coverage map.

**Remaining work**: none.

## Phase Objective

Make the test harness real. The substrate's tests are the direct validation that the Haskell
library surfaces, local lifecycle, cluster action plans, live cluster topology, and harness
entrypoints work together. After Phase 8 closes, `daemon-substrate-test test all` on either
cohort runs lint, unit, lifecycle, and integration gates; the integration stanza requires a
running hostbootstrap-managed cluster and asserts node topology, dependency rollouts,
daemon workload readiness, retained PVCs, and the edge-port record. The workflow coverage
table in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md)
remains the audit map that ties automated unit coverage, live readiness validation, and
manual live-smoke evidence to consumer-representative behaviors.

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

The local unit suite exits 0, and the full Phase 8 validation batch has run on both cohorts.

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

The local lifecycle suite exits 0.

### Sprint 8.4: `daemon-substrate-integration` stanza [Done]

**Status**: Done
**Implementation**: `test/integration/Main.hs`, `daemon-substrate.cabal`,
`src/Daemon/Test/CLI/Types.hs`, `src/Daemon/Test/CLI/Tests.hs`
**Docs to update**: `../documents/development/testing_strategy.md`, `system-components.md`

#### Objective

Land the `daemon-substrate-integration` Cabal stanza and CLI delegation point that owns the
cluster-requiring harness readiness gate. The stanza starts as a Cabal entrypoint in this
sprint and gains the live kind-cluster assertions under Sprint 8.6, where the executable has
a real cluster runner and service loops to drive.

#### Deliverables

- `test/integration/Main.hs` Cabal test-suite entry point.
- `daemon-substrate-test test integration` delegates to
  `cabal test daemon-substrate-integration`.
- the cluster is brought up via `hostbootstrap cluster up` (delegating inward to
  `daemon-substrate-test cluster up`) before the live readiness gate is executed.

#### Validation

Validated with:

- `cabal test daemon-substrate-integration`
- Linux live run from the project image on Docker's `kind` network:
  `cabal test daemon-substrate-integration --builddir=/tmp/daemon-substrate-cabal`

The integration stanza now discovers the repo-local kubeconfig, requires the expected
cohort-specific node count, waits for Harbor / Pulsar / MinIO StatefulSets and daemon
Deployments to be rolled out, asserts expected pod readiness, checks the three retained PVCs
are `Bound`, and verifies the edge-port record contains Pulsar, Pulsar admin, and MinIO
ports. The broader workflow table remains the audit map for unit coverage plus live-smoke
coverage:

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

Land `daemon-substrate-test test lint`. The sprint owns the local style gate:

1. **Doc validator** implementing the checks named in
   `documents/documentation_standards.md § Validation` (required metadata block, required
   broad-doc headings, relative-link resolution, root-doc metadata, `## Documentation
   Requirements` retention on phase files, root `README.md` reference to both `documents/` and
   `DEVELOPMENT_PLAN/`)
2. **Generated-protobuf import boundary**: no direct `Daemon.Proto.*` imports outside approved
   wire/boundary modules

The doc validator closes the Phase 0 Sprint 0.5 obligation; this sprint and Phase 0 Sprint 0.5
close together.

#### Deliverables

- `daemon-substrate-haskell-style` cabal stanza wired up
- `test/haskell-style/Main.hs` implementing the doc-validator and direct-proto-import checks
- `documents/documentation_standards.md § Validation` rewritten from forward-looking to
  current-state declarative

#### Validation

Validated with:

- `cabal test daemon-substrate-haskell-style`

The existing style suite exits 0 locally. The shared `daemon-substrate-test test ...`
delegate now executes Cabal for every test command.

### Sprint 8.6: Live command and cluster interpreters [Done]

**Status**: Done
**Implementation**: `src/Daemon/Cluster/Runner.hs`, `src/Daemon/Test/CLI/Cluster.hs`,
`src/Daemon/Test/CLI/Tests.hs`, `src/Daemon/Test/CLI/Service.hs`,
`docker/linux-substrate.Dockerfile`
**Docs to update**: `../documents/reference/cli_surface.md`,
`../documents/engineering/cluster_topology.md`,
`../documents/engineering/hostbootstrap_integration.md`,
`../documents/operations/cluster_bootstrap_runbook.md`, `system-components.md`

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
  `hostbootstrap` service container and remains resident after successful reconciliation.
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
- Linux live validation with:
  - `hostbootstrap doctor --spec hostbootstrap.dhall` on Ubuntu 24.04 amd64, detected as
    `linux-gpu` and mapped by this repo to the CPU-flavored harness container
  - `hostbootstrap build --spec hostbootstrap.dhall`
  - `hostbootstrap cluster up --spec hostbootstrap.dhall`
  - two consecutive `docker exec daemon-substrate daemon-substrate-test cluster down` /
    `cluster up` preserved-state cycles
  - `kubectl get pods -A` showing Harbor, Pulsar, MinIO, two orchestrator pods, and two
    worker pods Running with zero restarts
  - `kubectl get pvc,pv` showing Harbor, Pulsar, and MinIO PVCs bound to retained PVs
  - `/workspace/.data/runtime/edge-port.json` preserving `9090`, `9091`, and `9092`
  - `docker inspect daemon-substrate` showing the service container still running with
    restart count `0`
  - `daemon-substrate-test test all`
  - `cabal test daemon-substrate-integration --builddir=/tmp/daemon-substrate-cabal` from
    the project image on Docker's `kind` network, validating the live readiness gate against
    the current workspace.

### Sprint 8.7: 3×3 model × workflow matrix + check-code subcommand [Done]

**Status**: Done
**Implementation**: `src/Daemon/Test/CLI/*`, `src/Daemon/Test/Matrix.hs`,
`src/Daemon/Cluster/*`, `test/integration/*`, `hostbootstrap-hostbinary.dhall`,
`hostbootstrap-hostdaemon.dhall`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/reference/cli_surface.md`, `../documents/engineering/hostbootstrap_integration.md`,
`../documents/architecture/daemon_roles.md`,
`../documents/architecture/library_consumption_model.md`,
`../documents/architecture/pulsar_minio_ssot.md`, `../../README.md`, `system-components.md`

#### Objective

Extend the harness from the earlier two-cohort coverage to the full **3×3 matrix**:
each of the three execution models (`Container`, `HostBinary`, `HostDaemon`) exercising each of
three ML workflow archetypes — (a) continuous batched inference (≈ `infernix`), (b) finite
SL / offline-RL training jobs (≈ `jitML`), and (c) continuous online RL (MinIO weight updates
announced on Pulsar inference topics; distinct training-vs-inference task messages routable to
same-or-separate stateless engines). Land the `check-code` subcommand and refactor the test
suite onto the per-model spec files. `daemon-substrate` is the reference scaffolding for
`infernix` and `jitML`.

#### Deliverables

- `daemon-substrate-test check-code` subcommand delegates to the static
  `daemon-substrate-haskell-style` Cabal gate for use as the Dockerfile `RUN … check-code`
  build gate.
- `Daemon.Test.Matrix` defines the three execution models, three workflow archetypes, the
  nine matrix cases, and the audit-row mapping for each archetype.
- `daemon-substrate-test cluster up` accepts `--model
  <container|host-binary|host-daemon>` and persists the selected execution model beside the
  edge-port record; the Dockerfile and HostBinary spec pass the model explicitly.
- `daemon-substrate-integration` keys readiness expectations from the persisted execution
  model rather than a host-keyed cohort split; `detectClusterCohort` Apple-vs-Linux branching
  is removed.
- the workflow coverage table in `../documents/development/testing_strategy.md` updated to map
  the three archetypes onto the existing audit rows.

#### Validation

- `cabal build all`
- `cabal test daemon-substrate-unit`
- `cabal test daemon-substrate-haskell-style`
- built `daemon-substrate-test --help`
- built `daemon-substrate-test check-code`
- static search confirms `detectClusterCohort` is absent from `src/`

#### Remaining Work

(none)

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/cabal_layout.md` updates with the four-stanza shape and the
  `ghc-9.12.4` / container-only-freeze notes.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` documents the `check-code` build-gate subcommand
  and the `--spec` per-model selection.

**Development docs to create/update:**
- `../documents/development/testing_strategy.md` distinguishes the current automated gates
  from the workflow coverage audit map, records which live readiness checks are enforced
  by `daemon-substrate-integration`, and frames the target 3×3 model × workflow matrix.

**Architecture docs to create/update:**
- `../documents/architecture/daemon_roles.md`,
  `../documents/architecture/library_consumption_model.md`, and
  `../documents/architecture/pulsar_minio_ssot.md` describe the three ML workflow archetypes
  as the scaffolding contract for `infernix` and `jitML`.

**Cross-references to add:**
- `system-components.md` keeps the `daemon-substrate-test`, `daemon-substrate-unit`,
  `daemon-substrate-lifecycle`, `daemon-substrate-integration`, and
  `daemon-substrate-haskell-style` rows accurate, and records the `check-code` subcommand and
  the 3×3 matrix as implemented work.
