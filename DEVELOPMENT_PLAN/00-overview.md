# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Tell the cross-phase narrative — what each phase produces, why this order, and
> the dependency edges between them.

## Foundation

The build, lifecycle, and bootstrap layer is provided by
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) — a host-installed Python CLI plus
four prebuilt base container images. `daemon-substrate` declares its substrate behavior in a
typed `hostbootstrap.dhall` at the repository root and inherits GHC 9.12 + Cabal + kube tools
+ `protoc` + `ormolu` + `hlint` + a warm Haskell store from the base image. The phases below
focus on the Haskell library, the in-cluster reconcilers, and the `hostbootstrap.dhall` plus
thin project Dockerfile that wire the two layers together. What `daemon-substrate` explicitly
does **not** implement: substrate detection, host-prereq install, container lifecycle,
LaunchDaemon / systemd unit creation, multi-language toolchain installation. See
[`../documents/engineering/hostbootstrap_integration.md`](../documents/engineering/hostbootstrap_integration.md).

## The buildout

The plan reads as one ordered buildout from an empty repository to a self-validating shared
Haskell substrate consumed by `infernix` and `jitML`, sitting on top of `hostbootstrap`.

### Phase 0 — documentation and governance

Establish the documentation standards, plan standards, and the metadata-bearing root
documents. Populate the `documents/` and `DEVELOPMENT_PLAN/` trees with the architecture,
engineering, and operations docs the later phases reference.

This phase is open. Its closure requires completion of every documentation obligation called
out by Sprints 0.1 – 0.4 and 0.6. The doc validator (Phase 0 Sprint 0.5) is **deferred to
Phase 8 Sprint 8.5**, where it lands as part of the test-lint gate; Phase 0 closure does not
depend on it.

### Phase 1 — library scaffolding and cabal package

Establish `daemon-substrate.cabal`, `cabal.project` (GHC 9.12 pinned, matching the
`hostbootstrap` base image), the empty `src/Daemon/` module skeleton (including
`Daemon.Sub` — the typed `Subprocess` boundary that later phases shell out through for MinIO,
Harbor, Kubectl, and `SubprocessEngine`; Pulsar is the in-process exception),
and a no-op CI build that proves `cabal build all` succeeds. No public typeclass surface yet;
just the structural shell.

Depends on Phase 0 closing the documentation standards so the cabal layout doc can land
alongside the actual cabal file.

### Phase 2 — capability typeclasses (Pulsar, MinIO, Harbor, Kubectl) + admin surfaces

Land the four transport / cluster-I/O typeclasses (`HasPulsar`, `HasMinIO`, `HasHarbor`,
`HasKubectl`) with subprocess-backed real implementations and filesystem-backed test
implementations. Land the generic content-addressed `Daemon.MinIO.Store` (blobs / manifests /
pointers + CAS). Land the typed admin surfaces (`Daemon.Pulsar.Admin`, `Daemon.MinIO.Admin`)
that the reconciler will drive in Phase 5.

Depends on Phase 1 because typeclass modules need a cabal stanza to live in.

### Phase 3 — BootConfig / LiveConfig / LifecyclePolicy + lifecycle + signal handling

Land `BootConfig role app`, `LiveConfig` (SIGHUP-reloadable), `LifecyclePolicy` Dhall decoders
(`TopicLifecycle` + `BucketLifecycle`), the 7-phase lifecycle state machine
(`Load → Prereq → Acquire → Ready → Serve → Drain → Exit`), the SIGHUP / SIGTERM handlers,
the `/readyz` / `/healthz` / `/metrics` endpoints, and the `runService` entry point.

Depends on Phase 2 because the lifecycle wires through the capability typeclasses.

### Phase 4 — engine typeclass + mock engine + protobuf envelopes + audit topic

Land `HasEngine` (batch-native: `NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))`)
with `SubprocessEngine` / `NativeEngine` variants. Land the mock engine
(`Daemon.Test.MockEngine`) — deterministic SHA-256 placeholder, no real ML, batch-shaped.
Land the substrate-owned protobuf envelopes (`WorkflowEvent` with `deadline_at`,
`WorkflowKind`, and the `payload` oneof; `ControlEnvelope`; `LifecyclePhase` /
`ReadinessReport`; `OrchestratorToWorker`; `AuditEvent` with lineage references whose graph
indexing is deferred) and the generated `Daemon.Proto.*` modules.
Land `Daemon.Audit` — the compacted-topic helper (keyed write + replay on startup) the
reconciler depends on. Land the `Daemon.Wire.*` hand-written ADT layer (Sprint 4.5) that
wraps the generated `Daemon.Proto.*` records so application code stays idiomatic Haskell;
round-trip property tests are the conformance suite.

Depends on Phase 3 because the engine seam reads `BootConfig` and the audit helper reads the
lifecycle phase.

### Phase 5 — base loops: worker, orchestrator, bridge, bootstrap, reconciler

Land the five base loops, `Daemon.Consumer` (consumer-batch primitive with dedup + typed
`HandlerRouter` keyed by `payload_type` URL prefix + transparent `ObjectRef` materialization),
and `Daemon.WorkflowState` (append-only workflow event ownership over Pulsar). Ships
`Daemon.Topology.*` (typed Pulsar topology builders: `RequestResponse`, `FanOut`,
`BatchedFanOut`, `FanIn`, `BatchedFanIn`, `Pipeline`, `Stream`) and `Daemon.Batching.*`
(substrate-owned batcher + multi-bucket scheduler with hard-deadline preemption, WFQ, and
optional bucket-affinity dwell) so consumers compose accelerated-worker topologies without
writing raw Pulsar code:

- `runWorker` — Pulsar consumer with dedup → batch-native `HasEngine` → result publish
- `runOrchestrator` — provision a consumer-supplied `Topology` graph, fan-in / batch /
  fan-out via `Daemon.Topology.*` + `Daemon.Batching.*`, WAN hydration
- `runBridge` — consume one topic, transform, publish another
- `runFanInBootstrap` — request → do work → write to MinIO → publish ready event
- `runReconciler` — leader-elected (Pulsar Failover sub) Pulsar + MinIO lifecycle reconciler,
  running concurrently with `runOrchestrator` in the same orchestrator process

Depends on Phase 4 because the loops dispatch through batch-native `HasEngine` and publish to
the audit topic, and depend on the `Daemon.Wire.*` wrapper layer from Sprint 4.5.

### Phase 6 — cluster bring-up tree (kind cluster and Helm chart)

Land the cluster bring-up tree `src/Daemon/Cluster/{Kind,Storage,Helm,Harbor,Pulsar,MinIO,Workload,EdgePort}.hs`,
the `chart/` directory with Harbor / Pulsar / MinIO chart dependencies and the orchestrator /
worker Deployment templates, and the `dhall/` configs for both roles. ConfigMap rendering
wired up so cluster bring-up materializes the staged Dhall files into the cluster.

Depends on Phase 5 because the chart needs working daemon binaries to deploy.

### Phase 7 — hostbootstrap.dhall and thin project Dockerfile

Land `hostbootstrap.dhall` at the repository root (declaring `Container` for Linux CPU and
`HostDaemon` for Apple Silicon) and the thin `docker/linux-substrate.Dockerfile`
(`FROM ${BASE_IMAGE}` plus the project's own build steps). After this phase, an operator can
run `hostbootstrap cluster up` on either cohort and reach a `Ready` cluster. Substrate
detection, host-prereq install, container / daemon lifecycle, and LaunchDaemon installation
are all handled by `hostbootstrap`; this phase only ships the project-side config and
Dockerfile.

Depends on Phase 6 because the inner reconcilers (kind / Harbor / Pulsar / MinIO /
orchestrator / worker) must exist before the outer entry can deliver a `Ready` cluster.

### Phase 8 — test harness integration

Land the `daemon-substrate-test` executable, the four cabal test stanzas
(`daemon-substrate-unit`, `daemon-substrate-lifecycle`, `daemon-substrate-integration`,
`daemon-substrate-haskell-style`), and the end-to-end coverage described in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md):
cluster lifecycle, orchestrator → worker handoff, MinIO fetch, mock engine result publish,
cache lifecycle, pod replacement, MinIO replacement, lifecycle reconciler workflows across
all four `TopicLifecycle` modes, leader-election failover, orphan-scan safety windows,
audit-topic replay.

Depends on Phase 7 because integration tests need the bootstrap-driven cluster bring-up.

## Cohort obligations

Every phase that touches the test harness (Phase 6 onward) carries both cohort obligations:
Apple Silicon and Linux CPU. A phase cannot move to `Done` until both cohorts have validated
the same phase state. See [development_plan_standards.md § Q](development_plan_standards.md).

## What is intentionally not a phase

- A separate doc-validator phase. The validator is implemented in **Phase 8 Sprint 8.5** as
  part of the test-lint gate; Phase 0 Sprint 0.5 is a deferred-and-cross-referenced
  placeholder rather than its own phase.
- A separate "release" phase. The library is consumed by sibling path; there is no Hackage
  release ceremony.
- A "consumer migration" phase. Wiring `infernix` and `jitML` to consume the library is the
  consumers' work, not the substrate's.
- A GPU cohort. The mock engine performs no accelerator work; a GPU cohort would add cost
  without coverage.
- A "bootstrap scripting" phase. Substrate-specific bootstrap shell scripts, custom Compose
  files, and multi-language Dockerfile layers are owned by
  [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap), not by this repository.
