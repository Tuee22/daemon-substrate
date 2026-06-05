# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md), [../documents/engineering/hostbootstrap_integration.md](../documents/engineering/hostbootstrap_integration.md)

> **Purpose**: Authoritative inventory of every component the substrate produces or consumes —
> public module surfaces, typeclasses, protobuf schemas, daemon roles, lifecycle phases, test
> harness pieces, chart workloads, bootstrap entrypoints.

> Note: items below describe the current implemented inventory for the closed phase plan. See
> [README.md](README.md) for current per-phase status.

## Workflow terminology

Three closely related "workflow" names appear across the plan and documents. They are
distinct concepts; do not interchange them:

- **`WorkflowEvent`** — the protobuf envelope in `proto/daemon_substrate/workflow.proto`. The
  on-the-wire shape every consumer-defined event is wrapped in before publication to Pulsar.
  Carries `event_id`, `produced_at`, `deadline_at`, `workflow_kind` (`WorkflowKind` enum:
  `Training | Inference | Evaluation | Ingestion | Audit | Custom`), `payload_type` URL, and
  a `payload` oneof of `inline_bytes` vs `object_ref`. See
  [`../documents/reference/proto_surface.md`](../documents/reference/proto_surface.md).
- **`Daemon.WorkflowState`** — the Haskell module landing in Phase 5 Sprint 5.1. An
  append-to-Pulsar then in-memory fold abstraction that consumers use to track per-key state
  derived from a `WorkflowEvent` stream; rehydrates on `AcquireClients`.
- **`WorkflowOwner`** — the conceptual role of "the daemon process that owns the fold for a
  given workflow key". Not its own typeclass; the term names a responsibility within
  `runWorker` / `runOrchestrator` consumer step semantics.

## Topology and batching primitives

Substrate ships typed Pulsar topology builders (`Daemon.Topology.*`) so consumers compose
their orchestrator workflow graph from `RequestResponse`, `FanOut`, `BatchedFanOut`, `FanIn`,
`BatchedFanIn`, `Pipeline`, `Stream` rather than writing raw Pulsar client code. The batched
variants integrate the substrate-owned batching subsystem (`Daemon.Batching.*`) — the
in-cluster orchestrator's core responsibility for keeping accelerated workers saturated.
See [`../documents/engineering/orchestration_topologies.md`](../documents/engineering/orchestration_topologies.md)
and [`../documents/engineering/batching.md`](../documents/engineering/batching.md).

The `HasEngine` typeclass is **batch-native**: workers accept
`NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))`. Per-request dispatch is
the singleton-batch case; multi-element batches flow when the worker is fed by an upstream
`BatchedFanOut`.

## Public Haskell module surface

| Module | Phase | Implemented |
|--------|-------|-------------|
| `Daemon.Sub` | 1 | yes |
| `Daemon.Pulsar` | 2 | yes |
| `Daemon.Pulsar.Native` | 2 | yes |
| `Daemon.Pulsar.Admin` | 2 | yes |
| `Daemon.Pulsar.Admin.Http` | 2 | yes |
| `Daemon.MinIO` | 2 | yes |
| `Daemon.MinIO.Cache` | 2 | yes |
| `Daemon.MinIO.Store` | 2 | yes |
| `Daemon.MinIO.Admin` | 2 | yes |
| `Daemon.Harbor` | 2 | yes |
| `Daemon.Kubectl` | 2 | yes |
| `Daemon.Config.BootConfig` | 3 | yes |
| `Daemon.Config.LiveConfig` | 3 | yes |
| `Daemon.Config.LifecyclePolicy` | 3 | yes |
| `Daemon.Lifecycle` | 3 | yes |
| `Daemon.Lifecycle.Endpoints` | 3 | yes |
| `Daemon.Signal` | 3 | yes |
| `Daemon.Engine` | 4 | yes |
| `Daemon.Audit` | 4 | yes |
| `Daemon.Proto.PulsarApi` | 2 | yes |
| `Daemon.Consumer` | 5 | yes |
| `Daemon.Worker` | 5 | yes |
| `Daemon.Orchestrator` | 5 | yes |
| `Daemon.Bridge` | 5 | yes |
| `Daemon.Bootstrap` | 5 | yes |
| `Daemon.Reconciler` | 5 | yes |
| `Daemon.WorkflowState` | 5 | yes |
| `Daemon.Proto.*` | 4 (substrate-generated modules) | yes |
| `Daemon.Wire.*` | 4 (Sprint 4.5) | yes |
| `Daemon.Topology.*` (non-batched) | 5 (Sprint 5.1) | yes |
| `Daemon.Topology.Batched*` | 5 (Sprint 5.1.5) | yes |
| `Daemon.Batching.*` | 5 (Sprint 5.1.5) | yes |
| `Daemon.Cluster.*` | 6 (Sprint 6.1) | yes |

Test-harness-internal modules (`Daemon.Cluster.*`, `Daemon.Test.Filesystem*`,
`Daemon.Test.EchoEngines`, `Daemon.Test.MockEngine`, etc.) land across the implementation
phases; they are exposed by the library for the `daemon-substrate-test` executable but are not
part of the consumer-facing surface.
`Daemon.Cluster.*` is implemented in Phase 6 Sprint 6.1 as deterministic cluster action plans
for kind, manual storage, Helm, Harbor, Pulsar, MinIO, workload resources, and edge-port
selection. The live test-harness interpreter lands after the chart and executable surfaces.
`Daemon.Test.MockEngine` is implemented in Phase 4 Sprint 4.3 as a MinIO/cache-backed
`NativeEngine` for encoded `MockRequest` payloads.

`Daemon.Pulsar.Native` and `Daemon.Pulsar.Admin.Http` are the production Pulsar
implementations. Unlike the MinIO / Harbor / Kubectl production impls (which shell out through
`Daemon.Sub`), the Pulsar pair runs **in-process** — the native binary protocol over TCP for the
data plane and the admin REST API for the admin plane. This is the one deliberate exception to
the subprocess boundary; see
[development_plan_standards.md § M](development_plan_standards.md) and
[`../documents/engineering/pulsar_native_client.md`](../documents/engineering/pulsar_native_client.md).

## Typeclasses

| Typeclass | Module | Phase | Notes |
|-----------|--------|-------|-------|
| `HasPulsar` | `Daemon.Pulsar` | 2 | |
| `HasMinIO` | `Daemon.MinIO` | 2 | `Daemon.MinIO.Cache` adds `pin` / `unpin` / `isPinned` in Sprint 2.3 |
| `HasHarbor` | `Daemon.Harbor` | 2 | |
| `HasKubectl` | `Daemon.Kubectl` | 2 | |
| `HasEngine` | `Daemon.Engine` | 4 | batch-native: `NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))` |

## Engine handle variants

| Variant | Constructor | Use case |
|---------|-------------|----------|
| `SubprocessEngine` | `Daemon.Engine.SubprocessEngine { ... }` | subprocess-per-request (consumer pattern: infernix Python adapters) |
| `NativeEngine`     | `Daemon.Engine.NativeEngine { ... }`     | in-process FFI (consumer pattern: jitML Metal kernels; test-harness mock engine) |

## Daemon roles and base loops

| Role | Base loop(s) | Where it runs |
|------|--------------|---------------|
| Worker | `Daemon.Worker.runWorker` | one per physical node; in-cluster Deployment (Linux) or host-native (Apple) |
| Orchestrator | `Daemon.Orchestrator.runOrchestratorWithReconciler` over `runOrchestrator` + `Daemon.Reconciler.runReconciler` | always in-cluster; default `replicas: 2` |

Additional base loops exported for consumer use (not their own role):

| Loop | Module | Purpose |
|------|--------|---------|
| `runBridge` | `Daemon.Bridge` | consume one topic, transform payload, publish another |
| `runFanInBootstrap` | `Daemon.Bootstrap` | request → do work → write to MinIO → publish ready event with dedup |

## Lifecycle phases

| Phase | Order | Description |
|-------|-------|-------------|
| `Load`     | 1 | decode `BootConfig` + `LiveConfig` + `LifecyclePolicy` from Dhall |
| `Prereq`   | 2 | construct capability clients (Pulsar / MinIO / Harbor / Kubectl) |
| `Acquire`  | 3 | probe clients reachable; subscribe to topics; rehydrate `WorkflowOwner`s |
| `Ready`    | 4 | `/readyz` 200; signal handlers armed |
| `Serve`    | 5 | base loops running (consumer loop, reconciler tick, HTTP routes) |
| `Drain`    | 6 | SIGTERM received; finish in-flight; stop polling; surrender Failover subs |
| `Exit`     | 7 | terminal |

The Haskell `Daemon.Lifecycle.LifecyclePhase` (Phase 3 Sprint 3.4) and the protobuf
`LifecyclePhase` enum in `proto/daemon_substrate/lifecycle.proto` (Phase 4 Sprint 4.1) are
the same enum: the protobuf is the wire serialization of the Haskell type and must have
identical variant order to the table above.

## Protobuf schemas

| File | Messages | Owner |
|------|----------|-------|
| `proto/daemon_substrate/workflow.proto` | `WorkflowEvent` (with `deadline_at`, `WorkflowKind` enum, `payload` oneof of `inline_bytes` vs `object_ref`), `WorkflowKind`, `ObjectRef` | substrate |
| `proto/daemon_substrate/control.proto` | `ControlEnvelope`, `Drain`, `Reload` | substrate |
| `proto/daemon_substrate/orchestrator_worker.proto` | `OrchestratorToWorker`, `WorkerResult`, `SuccessPayload`, `FailurePayload` | substrate |
| `proto/daemon_substrate/lifecycle.proto` | `LifecyclePhase` enum, `ReadinessReport` | substrate |
| `proto/daemon_substrate/audit.proto` | `AuditEvent` (with `source_refs` / `result_refs` lineage; graph indexing deferred), `ResourceRef`, `ReconcileAction` | substrate |
| `proto/daemon_substrate_test/mock.proto` | `MockRequest`, `MockBatch`, `MockResult` | test harness |
| `proto/PulsarApi.proto` | vendored Pulsar wire-protocol schema (`BaseCommand` + sub-commands); compiled into generated `Proto.PulsarApi` / `Proto.PulsarApi_Fields` and re-exported as `Daemon.Proto.PulsarApi` for `Daemon.Pulsar.Native` | vendored (Apache Pulsar) |

## Pulsar topics (test harness)

| Topic | Producer | Subscriber | Subscription mode |
|-------|----------|------------|-------------------|
| `test.request` | upstream user / test driver (public ingress) | orchestrator (×N) | `Shared` |
| `test.batch.apple-silicon` | orchestrator | host worker | `Shared` |
| `test.batch.linux-cpu` | orchestrator | in-cluster worker (×2) | `Shared` |
| `test.result` | worker | orchestrator (×N) | `Shared` |
| `test.control.orchestrator` | test driver | orchestrator | `Failover` |
| `test.control.worker` | orchestrator | worker | `Failover` |
| `control.reconcile.leader.daemon-substrate-test` | (any orchestrator replica) | orchestrator (×N; only one active) | `Failover` (leader election for `runReconciler`) |
| `audit.reconcile.daemon-substrate-test` | reconciler leader | (consumers / debug) | compacted topic, key = `<kind>:<id>` |
| `test.session.control` | test driver | reconciler leader | `Failover` (session start/end events for `FiniteSession`-mode topics) |
| `test.session.workload.<session-id>` | session producer / consumer | session consumer | `Shared` (created on `session-start`, terminated on `session-end`) |

## MinIO buckets (test harness)

| Bucket | Purpose | Layout prefixes |
|--------|---------|-----------------|
| `daemon-substrate-test-weights` | mock model weight blobs (deterministic byte patterns) | `blobs/`, `manifests/`, `pointers/` |
| `daemon-substrate-test-artifacts` | mock input / output binary artifacts | `mock/input/`, `mock/output/` |
| `daemon-substrate-test-archives` | exported Pulsar archives for `ContinuousWithArchive` / `FiniteSession` / `OnlineLearning` test cases | `archives/<topic>/<startTime>-<endTime>.archive` |

Orphan scan is exercised against `daemon-substrate-test-weights` (the bucket with the
content-addressed `blobs/` + `manifests/` + `pointers/` layout). Safety window default = 60
minutes; the harness uses a tight 30-second window so tests can exercise expiration.

## Chart workloads

| Workload | Type | Cohorts |
|----------|------|---------|
| `harbor` (chart dependency) | StatefulSet | both |
| `pulsar` (chart dependency) | StatefulSet | both |
| `minio` (chart dependency) | StatefulSet | both |
| `daemon-substrate-test-orchestrator` | Deployment, `replicas: 2`, **no** anti-affinity (horizontally scalable; cardinality bounded by Pulsar `Shared` subscription); WAN egress permitted | both |
| `daemon-substrate-test-worker` | Deployment, `replicas: 2`, required pod anti-affinity | linux-cpu only (apple-silicon runs worker on host) |

The chart surface is implemented in Phase 6 Sprint 6.2 under `chart/`. It renders the
orchestrator Deployment for both cohorts and conditionally renders the worker Deployment only
for Linux CPU. The Harbor / Pulsar / MinIO entries are local dependency charts that now render
deployable StatefulSets with readiness / startup probes and PVCs bound to the manual PVs.
The harness image is built as `daemon-substrate-test:local` and loaded directly into kind
before Helm rollout.

The worker's `requiredDuringScheduling` anti-affinity on `kubernetes.io/hostname` means the
linux-cpu kind cluster must provision **at least two nodes**, or only one worker pod
schedules. The kind node count is declared in
[`../documents/engineering/cluster_topology.md`](../documents/engineering/cluster_topology.md)
and materialized by `Daemon.Cluster.Kind` (Phase 6 Sprint 6.1).

## Cabal stanzas

| Stanza | Type | Source dir |
|--------|------|------------|
| `daemon-substrate` | library | `src/` |
| `daemon-substrate-test` | executable | `app/test/` |
| `daemon-substrate-unit` | test-suite, `exitcode-stdio-1.0` | `test/unit/` |
| `daemon-substrate-lifecycle` | test-suite, `exitcode-stdio-1.0` | `test/lifecycle/` |
| `daemon-substrate-integration` | test-suite, `exitcode-stdio-1.0` | `test/integration/` |
| `daemon-substrate-haskell-style` | test-suite, `exitcode-stdio-1.0` | `test/haskell-style/` |

The `daemon-substrate-test` executable is implemented in Phase 8 Sprint 8.1 with the documented
`cluster`, `test`, and `service` command parser. Phase 8 Sprint 8.6 adds live Cabal delegation
for `test ...`, concrete kind / kubectl / helm / Docker execution for `cluster ...`, live
Pulsar and MinIO admin operations through dependency pods, PVC-backed dependency state, and
live worker / orchestrator service loops. Managed Apple edge-port forwarding, host-worker
handoff, live request -> orchestrator -> host worker -> response handoff, Linux
hostbootstrap container bring-up, two preserved-state Linux `cluster down` / `cluster up`
cycles, and the `daemon-substrate-integration` live readiness gate are validated.

## Bootstrap entrypoints

The outer bootstrap layer is owned by [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap);
this repository ships only the project-side config and the thin project Dockerfile. See
[`../documents/engineering/hostbootstrap_integration.md`](../documents/engineering/hostbootstrap_integration.md)
for the integration shape.

The bootstrap shape declares one substrate entry per hostbootstrap target in the single root
`hostbootstrap.dhall`; `--force-target` can select a non-detected entry for validation:

| Entrypoint | Target | Model | Delegates to |
|------------|--------|-------|--------------|
| `hostbootstrap cluster up` on Apple Silicon | `AppleSilicon` | `HostDaemon` | `.build/daemon-substrate-test cluster up`; host worker runs separately via foreground `hostbootstrap daemon run` |
| `hostbootstrap cluster up` on Linux CPU | `LinuxCpu` | `Container` | one-shot project container receiving `cluster up` |
| `hostbootstrap cluster up` on Linux GPU | `LinuxGpu` | `HostBinary` | native `.build/daemon-substrate-test cluster up` |
| `hostbootstrap cluster up --force-target <target>` | forced target | target model | same as the selected target |

## Project-side bootstrap files

| File | Purpose |
|------|---------|
| `hostbootstrap.dhall` | typed config consumed by `hostbootstrap`; maps `AppleSilicon` to `HostDaemon`, `LinuxCpu` to `Container`, and `LinuxGpu` to `HostBinary` |
| `docker/Dockerfile` | thin project Dockerfile (`FROM ${BASE_IMAGE}` plus the project's own build steps, a tini-wrapped `ENTRYPOINT`, and a `RUN daemon-substrate-test check-code` build gate); no default `CMD`; the heavy toolchain is in the base |
| `cabal.project.container` | container-only Cabal project file importing `/opt/basecontainer/haskell-deps/cabal.project.freeze` |

The intermediate per-model spec files and resident container `CMD` are removed. Phase 8 keeps
the direct `cluster --model` debugging override, persisted execution-model records, and
`Daemon.Test.Matrix`; normal hostbootstrap handoff forwards plain `cluster up/down/delete`.

## Base image

`hostbootstrap` publishes CPU and CUDA base images. Apple Silicon and Linux CPU consume the CPU
base for container artifacts; Linux GPU consumes the CUDA base for the HostBinary build
container and optional project image.

| Tag | Used by | Provides |
|-----|---------|----------|
| `docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64` / `-arm64` | `AppleSilicon`, `LinuxCpu` container artifacts | `ghc-9.12.4`, Cabal, kube tools (`kubectl`, `helm`, `kind`), `protoc`, `ormolu`, `hlint`, warm Haskell store |
| `docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64` / `-arm64` | `LinuxGpu` HostBinary build container and optional project image | CPU toolchain plus CUDA-flavored base selection |

The Pulsar client is in-process pure Haskell (`Daemon.Pulsar.Native` over the native binary
protocol; `Daemon.Pulsar.Admin.Http` over admin REST), so the base image needs **no** Node
runtime and **no** `pulsar-admin` CLI for Pulsar access — the GHC-ecosystem `network` and
`http-client` libraries from the warm Haskell store suffice.

## Dhall configs

| File | Contents | Read by |
|------|----------|---------|
| `dhall/orchestrator.dhall` | Orchestrator `BootConfig` with harness app topic graph | `daemon-substrate-test service --role orchestrator` |
| `dhall/worker.dhall` | Worker `BootConfig` with harness cohort, work topic, result topic, and cache directory | `daemon-substrate-test service --role worker` |
| `dhall/live.dhall` | Shared `LiveConfig` stub with retry, dedup cache, drain deadline, batching, and scheduler policy | `daemon-substrate-test service --role <role>` |
| `dhall/lifecycle-policy.dhall` | Orchestrator `LifecyclePolicy` with all four `TopicLifecycle` modes and harness bucket declarations | `daemon-substrate-test service --role orchestrator` |

Lifecycle policy shape (`TopicLifecycle`, `BucketLifecycle`, `LifecyclePolicy`) lives in
`Daemon.Config.LifecyclePolicy`; consumers compose it into their orchestrator Dhall. See
[`../documents/architecture/lifecycle_policy.md`](../documents/architecture/lifecycle_policy.md).

The chart packages the same role, live, and lifecycle Dhall files under `chart/files/` and
mounts them through the orchestrator/worker ConfigMaps.

## CLI surface

See [`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md) for the
authoritative `daemon-substrate-test` command surface, including `check-code`.

## Update rule

When architecture changes (a new module, a new typeclass, a new chart workload, a new
protobuf message, a new bootstrap script), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single
source of truth for the substrate component set.
