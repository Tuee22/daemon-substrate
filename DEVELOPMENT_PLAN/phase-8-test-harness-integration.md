# Phase 8: Test Harness Integration

**Status**: Authoritative source
**Supersedes**: `phase-7-test-harness-integration.md` (renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the `daemon-substrate-test` executable, the four cabal test stanzas, the
> live cluster interpreters, and the executable 3x3 integration gate that proves the supported
> execution-model/workflow matrix with the mock engine deployed.

## Phase Status

**Status**: Active

Sprints 8.1 through 8.6 closed the executable, live cluster, and service-loop surfaces:
`daemon-substrate-test test ...` delegates to Cabal, `cluster ...` executes concrete kind /
kubectl / helm / Docker image build and the current image-publication actions, the local Harbor / Pulsar /
MinIO dependency charts are deployable, Pulsar and MinIO admin actions run through the live
pods, the chart mounts PVC-backed state into the dependency pods, and the harness `service`
command runs the live worker / orchestrator loops.
Apple Silicon preserved-state kind bring-up, in-place `cluster up` idempotency, managed
edge-port forwarding, host-worker handoff, and a live request -> orchestrator -> host worker
-> response workflow handoff are validated. Linux hostbootstrap container bring-up,
two-cycle preserved-state kind bring-up, Ready workload state, and the
`daemon-substrate-integration` live readiness gate are useful validation evidence. They do not
close the reopened one-worker topology or executable 3x3 integration requirements.

Sprint 8.7 is closed against the substrate-keyed bootstrap shape: `daemon-substrate-test`
exposes `check-code`, cluster commands accept a direct `--model` debugging override, plain
hostbootstrap handoff resolves the selected target/model, `cluster delete` is implemented,
`detectClusterCohort` OS branching is removed, the integration readiness gate keys node and
worker expectations from the persisted execution-model marker, and `Daemon.Test.Matrix`
records the 3×3 execution-model × workflow-archetype audit map.

### Remaining Work

- `daemon-substrate-integration` must become the executable 3x3 matrix runner. One invocation
  must create and tear down a fresh kind cluster nine times: every execution model
  (`Container`, `HostBinary`, `HostDaemon`) crossed with every workflow archetype.
- Each matrix case must deploy Harbor / Pulsar / MinIO, upload the already-built harness image
  through Harbor, deploy the two-replica coordinator/orchestrator and exactly one worker, run
  workflow assertions, verify status, and tear the cluster down before the next case.
- Each case must run under the **test `ClusterProfile`** — a `dst-test-<model>-<archetype>`
  cluster name and a `.test_data/<case>/` runtime tree — so a case can never touch the
  production `.data/` cluster, and teardown is wrapped in a guaranteed `finally` with a
  `dst-test-` delete-guard so a partial run cannot delete the production cluster.
- The runner must invoke `hostbootstrap` recursively per case (the project binary extending
  `hostbootstrap-core`) and consume the per-case Dhall the binary generates, rather than a
  single static `dhall/*.dhall` set.
- `test all` must run unit tests through the compiled binary and then run the full integration
  matrix without requiring a preexisting cluster.

The `ClusterProfile`, `.test_data` isolation, binary-generated per-case Dhall, and recursive
`hostbootstrap-core` invocation depend on the upstream `hostbootstrap` re-baseline and are owned
by [phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md](phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md).
Sprint 8.8 lands the in-repo runner skeleton against the current bootstrap shape; Phase 9
rewires it onto the host-driven, profile-isolated model once `hostbootstrap-core` lands.

## Phase Objective

Make the test harness real. The substrate's tests are the direct validation that the Haskell
library surfaces, local lifecycle, cluster action plans, live cluster topology, and harness
entrypoints work together. After Phase 8 closes, `daemon-substrate-test test all` on any
supported physical machine runs lint, unit, lifecycle, and the full nine-case integration
matrix. The integration stanza owns cluster lifecycle for every case; it does not depend on a
preexisting hostbootstrap-managed cluster. The workflow coverage table in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md)
is the executable matrix contract, not just an audit map.

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
[../documents/reference/cli_surface.md](../documents/reference/cli_surface.md):
`cluster {up,down,delete,status}`, `test {unit,lifecycle,integration,lint,all}`, `service --role <r>
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

The local unit suite exits 0. Historical Phase 8 validation ran on the then-current supported
hostbootstrap targets; Sprint 8.8 owns the reopened executable 3x3 validation batch.

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
- Apple-Silicon host-daemon ↔ in-cluster Pulsar handshake survives a caller-owned foreground
  daemon process across `cluster down` / `up` cycles (row 36; representative of jitML
  `ForwardToHost` and infernix Apple host daemon)

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
`docker/Dockerfile`
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
  propagates failures through the executable exit code. For container-model integration runs,
  `test integration` and `test all` attach the current project container to Docker's `kind`
  network before Cabal delegation so the internal kind kubeconfig resolves the API server.
- `daemon-substrate-test cluster {up,down,delete,status}` runs the concrete action plan against
  absolute tool paths, builds `daemon-substrate-test:local`, loads it into kind, applies the
  manual StorageClass / PVs, installs the Helm chart, runs Pulsar admin through the broker
  pod, runs MinIO admin through the `mc` sidecar, treats an already-existing kind cluster as
  an idempotent no-op, streams long-running build/load progress, and persists the selected
  edge port.
- Linux CPU project image exposes `daemon-substrate-test` as the tini-wrapped entrypoint;
  `hostbootstrap` forwards `cluster up/down/delete` as one-shot container commands.
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
- `hostbootstrap doctor`
- `hostbootstrap build --force-target apple-silicon`
- `hostbootstrap cluster up --force-target apple-silicon`
- `hostbootstrap daemon run --force-target apple-silicon` as the foreground host worker
- `hostbootstrap cluster down --force-target apple-silicon`
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
  - `hostbootstrap doctor` on Ubuntu 24.04 amd64
  - `hostbootstrap build --force-target linux-cpu`
  - `hostbootstrap cluster up --force-target linux-cpu`
  - two consecutive `hostbootstrap cluster down --force-target linux-cpu` /
    `hostbootstrap cluster up --force-target linux-cpu` preserved-state cycles
  - `kubectl get pods -A` showing Harbor, Pulsar, MinIO, two orchestrator pods, and two
    worker pods Running with zero restarts
  - `kubectl get pvc,pv` showing Harbor, Pulsar, and MinIO PVCs bound to retained PVs
  - `./.data/runtime/edge-port.json` preserving `9090`, `9091`, and `9092`
  - `daemon-substrate-test test all` / `hostbootstrap run --force-target linux-cpu test all`
  - `cabal test daemon-substrate-integration --builddir=/tmp/daemon-substrate-cabal` from
    the project image on Docker's `kind` network, validating the live readiness gate against
    the current workspace.

### Sprint 8.7: 3×3 audit map + check-code subcommand [Done]

**Status**: Done
**Implementation**: `src/Daemon/Test/CLI/*`, `src/Daemon/Test/Matrix.hs`,
`src/Daemon/Cluster/*`, `test/integration/*`, `hostbootstrap.dhall`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/reference/cli_surface.md`, `../documents/engineering/hostbootstrap_integration.md`,
`../documents/architecture/daemon_roles.md`,
`../documents/architecture/library_consumption_model.md`,
`../documents/architecture/pulsar_minio_ssot.md`, `../../README.md`, `system-components.md`

#### Objective

Extend the harness from the earlier two-cohort coverage to the direct inner **3×3 audit map**:
each of the three execution models (`Container`, `HostBinary`, `HostDaemon`) exercising each of
three ML workflow archetypes — (a) continuous batched inference (≈ `infernix`), (b) finite
SL / offline-RL training jobs (≈ `jitML`), and (c) continuous online RL (MinIO weight updates
announced on Pulsar inference topics; distinct training-vs-inference task messages routable to
same-or-separate stateless engines). Land the `check-code` subcommand and refactor the test
suite onto the single substrate-keyed hostbootstrap config, whose Linux CPU and Linux GPU
targets both use the `Container` model. `daemon-substrate` is the reference scaffolding for
`infernix` and `jitML`.

#### Deliverables

- `daemon-substrate-test check-code` subcommand delegates to the static
  `daemon-substrate-haskell-style` Cabal gate for use as the Dockerfile `RUN … check-code`
  build gate.
- `Daemon.Test.Matrix` defines the three execution models, three workflow archetypes, the
  nine matrix cases, and the audit-row mapping for each archetype.
- `daemon-substrate-test cluster up/down/delete/status` accepts `--model
  <container|host-binary|host-daemon>` for direct debugging and persists the selected execution
  model beside the edge-port record; plain hostbootstrap handoff resolves the model from the
  selected target.
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

#### Follow-on Work

The static audit map is implemented, but it does not satisfy the executable 3x3 integration
contract. Sprint 8.8 owns the remaining live matrix runner.

### Sprint 8.8: Executable 3x3 integration runner [Active]

**Status**: Active
**Implementation**: `src/Daemon/Test/Matrix.hs`, `src/Daemon/Test/CLI/Cluster.hs`,
`src/Daemon/Test/CLI/Tests.hs`, `src/Daemon/Test/CLI/Service.hs`,
`test/integration/Main.hs`, `src/Daemon/Cluster/*`, `chart/files/*.dhall`,
`dhall/*.dhall`, `test/unit/Main.hs`
**Docs to update**: `../documents/development/testing_strategy.md`,
`../documents/reference/cli_surface.md`, `../documents/engineering/cluster_topology.md`,
`../documents/engineering/hostbootstrap_integration.md`,
`../documents/operations/cluster_bootstrap_runbook.md`, `../../README.md`,
`system-components.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make `daemon-substrate-test test integration` run the complete execution-model × workflow
matrix on every supported physical host. A single integration invocation runs nine independent
cases. Each case creates a fresh kind cluster, deploys Harbor / Pulsar / MinIO, uploads the
already-built harness image through Harbor, deploys the two-replica coordinator/orchestrator
service and exactly one worker, executes the workflow assertions for that cell, verifies
cluster status, and tears the cluster down before the next case.

#### Deliverables

- integration runner that iterates `Daemon.Test.Matrix.harnessMatrixCases`
- fresh cluster name/runtime paths per matrix case so cases cannot share live state
- case lifecycle wrapper: `cluster up`, status/assertions, `cluster down/delete` cleanup
- no redundant host/project Docker rebuild when an equivalent artifact is already available
- per-case Harbor deployment and harness image upload
- one compiled `daemon-substrate-test` binary used for both long-running roles; Dhall config
  selects coordinator/orchestrator vs worker behavior and all Pulsar topic bindings
- coordinator/orchestrator Deployment with `replicas: 2` in every case
- exactly one worker in every case, either one in-cluster Deployment replica or one
  caller-owned host-daemon process
- coordinator/orchestrator idempotently creates missing Pulsar topics declared in
  `LifecyclePolicy`; worker/inference daemon does not create workflow topics
- workflow assertions for continuous batched inference, finite training / offline RL, and
  continuous online RL
- unit tests, invoked through `daemon-substrate-test test unit`, covering matrix enumeration,
  per-case cluster naming/path isolation, one-worker topology, coordinator topic-creation
  ownership, and teardown ordering

#### Validation

- `cabal build all --enable-tests`
- `daemon-substrate-test test unit`
- `daemon-substrate-test test integration` on at least one development host, showing nine
  fresh cluster create/assert/teardown cycles
- `hostbootstrap run --force-target apple-silicon test integration`
- `hostbootstrap run --force-target linux-cpu test integration`
- `hostbootstrap run --force-target linux-gpu test integration`
- `daemon-substrate-test test all`

#### Remaining Work

Sprint 8.8 is not implemented in the current repo state. The existing integration stanza still
checks a single preexisting live environment rather than owning nine fresh cluster lifecycles.

Sprint 8.8 owns the in-repo runner against the current bootstrap shape. The
`ClusterProfile` + `.test_data/<case>/` isolation, the centralized cluster-name/`hostPath`
derivation, and the recursive `hostbootstrap-core` invocation per case are owned by
[phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md](phase-9-hostbootstrap-core-integration-and-host-driven-3x3.md),
which is blocked on the upstream `hostbootstrap-core` phases.

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/cabal_layout.md` updates with the four-stanza shape and the
  `ghc-9.12.4` / container-only-freeze notes.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` documents the `check-code` build-gate subcommand,
  `cluster delete`, direct inner `--model` debugging, and outer `--force-target` selection.

**Development docs to create/update:**
- `../documents/development/testing_strategy.md` distinguishes the current implemented gates
  from the target executable 3x3 matrix, records the nine-cluster lifecycle contract, and
  states that the current readiness-only integration stanza is reopened work.

**Architecture docs to create/update:**
- `../documents/architecture/daemon_roles.md`,
  `../documents/architecture/library_consumption_model.md`, and
  `../documents/architecture/pulsar_minio_ssot.md` describe the three ML workflow archetypes
  as the scaffolding contract for `infernix` and `jitML`.

**Cross-references to add:**
- `system-components.md` keeps the `daemon-substrate-test`, `daemon-substrate-unit`,
  `daemon-substrate-lifecycle`, `daemon-substrate-integration`, and
  `daemon-substrate-haskell-style` rows accurate, records the `check-code` subcommand, and
  tracks the executable 3x3 matrix as active work until Sprint 8.8 closes.
