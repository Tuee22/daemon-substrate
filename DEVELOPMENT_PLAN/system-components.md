# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md), [../documents/engineering/hostbootstrap_integration.md](../documents/engineering/hostbootstrap_integration.md)

> **Purpose**: Authoritative inventory of every component the substrate produces or consumes —
> public module surfaces, typeclasses, protobuf schemas, daemon roles, lifecycle phases, test
> harness pieces, chart workloads, bootstrap entrypoints.

> Note: items below describe the **target** inventory the substrate is being built toward.
> A given item is `Implemented` only when the relevant phase document marks it `Done`. See
> [README.md](README.md) for current per-phase status.

## Public Haskell module surface

| Module | Phase | Implemented |
|--------|-------|-------------|
| `Daemon.Sub` | 1 | no |
| `Daemon.Pulsar` | 2 | no |
| `Daemon.Pulsar.Admin` | 2 | no |
| `Daemon.MinIO` | 2 | no |
| `Daemon.MinIO.Cache` | 2 | no |
| `Daemon.MinIO.Store` | 2 | no |
| `Daemon.MinIO.Admin` | 2 | no |
| `Daemon.Harbor` | 2 | no |
| `Daemon.Kubectl` | 2 | no |
| `Daemon.Config.BootConfig` | 3 | no |
| `Daemon.Config.LiveConfig` | 3 | no |
| `Daemon.Config.LifecyclePolicy` | 3 | no |
| `Daemon.Lifecycle` | 3 | no |
| `Daemon.Signal` | 3 | no |
| `Daemon.Engine` | 4 | no |
| `Daemon.Audit` | 4 | no |
| `Daemon.Consumer` | 5 | no |
| `Daemon.Worker` | 5 | no |
| `Daemon.Orchestrator` | 5 | no |
| `Daemon.Bridge` | 5 | no |
| `Daemon.Bootstrap` | 5 | no |
| `Daemon.Reconciler` | 5 | no |
| `Daemon.WorkflowState` | 5 | no |
| `Daemon.Proto.*` | 4 (generated) | no |

Test-harness-internal modules (`Daemon.Cluster.*`, `Daemon.Test.Filesystem*`,
`Daemon.Test.MockEngine`, etc.) land in Phases 2 and 6; they are exposed by the library for
the `daemon-substrate-test` executable but are not part of the consumer-facing surface.

## Typeclasses

| Typeclass | Module | Phase |
|-----------|--------|-------|
| `HasPulsar` | `Daemon.Pulsar` | 2 |
| `HasMinIO` | `Daemon.MinIO` | 2 |
| `HasHarbor` | `Daemon.Harbor` | 2 |
| `HasKubectl` | `Daemon.Kubectl` | 2 |
| `HasEngine` | `Daemon.Engine` | 4 |

## Engine handle variants

| Variant | Constructor | Use case |
|---------|-------------|----------|
| `SubprocessEngine` | `Daemon.Engine.SubprocessEngine { ... }` | subprocess-per-request (consumer pattern: infernix Python adapters) |
| `NativeEngine`     | `Daemon.Engine.NativeEngine { ... }`     | in-process FFI (consumer pattern: jitML Metal kernels; test-harness mock engine) |

## Daemon roles and base loops

| Role | Base loop(s) | Where it runs |
|------|--------------|---------------|
| Worker | `Daemon.Worker.runWorker` | one per physical node; in-cluster Deployment (Linux) or host-native (Apple) |
| Orchestrator | `Daemon.Orchestrator.runOrchestrator` + `Daemon.Reconciler.runReconciler` (concurrent threads in the same process) | always in-cluster; default `replicas: 2` |

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

## Protobuf schemas

| File | Messages | Owner |
|------|----------|-------|
| `proto/daemon_substrate/workflow.proto` | `WorkflowEvent`, `ObjectRef` | substrate |
| `proto/daemon_substrate/control.proto` | `ControlEnvelope`, `Drain`, `Reload` | substrate |
| `proto/daemon_substrate/orchestrator_worker.proto` | `OrchestratorToWorker`, `WorkerResult`, `SuccessPayload`, `FailurePayload` | substrate |
| `proto/daemon_substrate/lifecycle.proto` | `LifecyclePhase` enum, `ReadinessReport` | substrate |
| `proto/daemon_substrate/audit.proto` | `AuditEvent`, `ResourceRef`, `ReconcileAction` | substrate |
| `proto/daemon_substrate_test/mock.proto` | `MockRequest`, `MockBatch`, `MockResult` | test harness |

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

## Cabal stanzas

| Stanza | Type | Source dir |
|--------|------|------------|
| `daemon-substrate` | library | `src/` |
| `daemon-substrate-test` | executable | `app/test/` |
| `daemon-substrate-unit` | test-suite, `exitcode-stdio-1.0` | `test/unit/` |
| `daemon-substrate-lifecycle` | test-suite, `exitcode-stdio-1.0` | `test/lifecycle/` |
| `daemon-substrate-integration` | test-suite, `exitcode-stdio-1.0` | `test/integration/` |
| `daemon-substrate-haskell-style` | test-suite, `exitcode-stdio-1.0` | `test/haskell-style/` |

## Bootstrap entrypoints

The outer bootstrap layer is owned by [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap);
this repository ships only the project-side config and the thin project Dockerfile. See
[`../documents/engineering/hostbootstrap_integration.md`](../documents/engineering/hostbootstrap_integration.md)
for the integration shape.

| Entrypoint | Cohort | Model | Delegates to |
|------------|--------|-------|--------------|
| `hostbootstrap cluster up` (via `hostbootstrap.dhall` `H.Substrate.AppleSilicon` entry) | apple-silicon | `HostDaemon` | LaunchDaemon running `./.build/daemon-substrate-test service --role worker` |
| `hostbootstrap cluster up` (via `hostbootstrap.dhall` `H.Substrate.LinuxCpu` entry) | linux-cpu | `Container` (`service = True`) | project container running `daemon-substrate-test cluster up` |

## Project-side bootstrap files

| File | Purpose |
|------|---------|
| `hostbootstrap.dhall` | typed per-substrate config consumed by `hostbootstrap`; declares Container / HostDaemon model and mounts |
| `docker/linux-substrate.Dockerfile` | thin project Dockerfile (`FROM ${BASE_IMAGE}` plus the project's own build steps); the heavy toolchain is in the base |

## Base image

| Tag | Used by | Provides |
|-----|---------|----------|
| `docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64` / `-arm64` | Linux CPU cohort | GHC 9.12, Cabal, kube tools (`kubectl`, `helm`, `kind`), `protoc`, `ormolu` / `fourmolu`, `hlint`, warm Haskell store |

## Dhall configs

| File | Contents | Read by |
|------|----------|---------|
| `dhall/orchestrator.dhall` | Orchestrator `BootConfig` + `LiveConfig` + `LifecyclePolicy` | `daemon-substrate-test service --role orchestrator` |
| `dhall/worker.dhall` | Worker `BootConfig` + `LiveConfig` | `daemon-substrate-test service --role worker` |

Lifecycle policy shape (`TopicLifecycle`, `BucketLifecycle`, `LifecyclePolicy`) lives in
`Daemon.Config.LifecyclePolicy`; consumers compose it into their orchestrator Dhall. See
[`../documents/architecture/lifecycle_policy.md`](../documents/architecture/lifecycle_policy.md).

## CLI surface

See [`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md) for the
authoritative `daemon-substrate-test` command surface.

## Update rule

When architecture changes (a new module, a new typeclass, a new chart workload, a new
protobuf message, a new bootstrap script), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single
source of truth for the substrate component set.
