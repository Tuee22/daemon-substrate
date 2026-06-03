# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the substrate produces or consumes —
> public module surfaces, typeclasses, protobuf schemas, daemon roles, lifecycle phases, test
> harness pieces, chart workloads, bootstrap entrypoints.

> Note: items below describe the **target** inventory the substrate is being built toward.
> A given item is `Implemented` only when the relevant phase document marks it `Done`. See
> [README.md](README.md) for current per-phase status.

## Public Haskell module surface

| Module | Phase | Implemented |
|--------|-------|-------------|
| `Daemon.Pulsar` | 2 | no |
| `Daemon.MinIO` | 2 | no |
| `Daemon.MinIO.Cache` | 2 | no |
| `Daemon.Engine` | 2 | no |
| `Daemon.Lifecycle` | 3 | no |
| `Daemon.Config` | 3 | no |
| `Daemon.Worker` | 4 | no |
| `Daemon.Orchestrator` | 4 | no |
| `Daemon.WorkflowState` | 4 | no |
| `Daemon.Proto.*` | 2 (generated) | no |

Test-harness-internal modules (`Daemon.Cluster.*`, `Daemon.Test.Mock`, etc.) land in Phases 4
and 5; they are exposed by the library for the `daemon-substrate-test` executable but are not
part of the consumer-facing surface.

## Typeclasses

| Typeclass | Module | Phase |
|-----------|--------|-------|
| `HasPulsar` | `Daemon.Pulsar` | 2 |
| `HasMinIO` | `Daemon.MinIO` | 2 |
| `HasEngine` | `Daemon.Engine` | 2 |

## Engine handle variants

| Variant | Constructor | Use case |
|---------|-------------|----------|
| `SubprocessEngine` | `Daemon.Engine.SubprocessEngine { ... }` | subprocess-per-request (consumer pattern: infernix Python adapters) |
| `NativeEngine`     | `Daemon.Engine.NativeEngine { ... }`     | in-process FFI (consumer pattern: jitML Metal kernels; test-harness mock engine) |

## Daemon roles

| Role | Base loop | Where it runs |
|------|-----------|---------------|
| Worker | `Daemon.Worker.runWorker` | one per physical node; in-cluster Deployment (Linux) or host-native (Apple) |
| Orchestrator | `Daemon.Orchestrator.runOrchestrator` | always off-cluster |

## Lifecycle phases

| Phase | Order | Description |
|-------|-------|-------------|
| `Bootstrap`     | 1 | load Dhall config; nothing networked yet |
| `AcquireClients`| 2 | construct Pulsar / MinIO clients; rehydrate any `WorkflowOwner`s |
| `ProbeClients`  | 3 | verify both reachable (listObjects + dummy subscribe) |
| `Ready`         | 4 | `/readyz` 200; signal SIGUSR1 ack |
| `Draining`      | 5 | SIGTERM received; finish in-flight; stop polling |
| `Exit`          | 6 | terminal |

## Protobuf schemas

| File | Messages | Owner |
|------|----------|-------|
| `proto/daemon_substrate/workflow.proto` | `WorkflowEvent`, `ObjectRef` | substrate |
| `proto/daemon_substrate/control.proto` | `ControlEnvelope`, `Drain`, `Reload` | substrate |
| `proto/daemon_substrate/orchestrator_worker.proto` | `OrchestratorToWorker`, `WorkerResult`, `SuccessPayload`, `FailurePayload` | substrate |
| `proto/daemon_substrate/lifecycle.proto` | `LifecyclePhase` enum, `ReadinessReport` | substrate |
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

## MinIO buckets (test harness)

| Bucket | Purpose |
|--------|---------|
| `daemon-substrate-test-weights` | mock model weight blobs (deterministic byte patterns) |
| `daemon-substrate-test-artifacts` | mock input / output binary artifacts |

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
| `daemon-substrate-integration` | test-suite, `exitcode-stdio-1.0` | `test/integration/` |
| `daemon-substrate-haskell-style` | test-suite, `exitcode-stdio-1.0` | `test/haskell-style/` |

## Bootstrap entrypoints

| Script | Cohort | Delegates to |
|--------|--------|--------------|
| `bootstrap/apple-silicon.sh` | apple-silicon | `./.build/daemon-substrate-test cluster up` |
| `bootstrap/linux-cpu.sh` | linux-cpu | `docker compose run --rm daemon-substrate daemon-substrate-test cluster up` |

## Dhall configs

| File | Role | Read by |
|------|------|---------|
| `dhall/orchestrator.dhall` | Orchestrator BootConfig | `daemon-substrate-test service --role orchestrator` |
| `dhall/worker.dhall` | Worker BootConfig | `daemon-substrate-test service --role worker` |

## CLI surface

See [`../documents/reference/cli_surface.md`](../documents/reference/cli_surface.md) for the
authoritative `daemon-substrate-test` command surface.

## Update rule

When architecture changes (a new module, a new typeclass, a new chart workload, a new
protobuf message, a new bootstrap script), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single
source of truth for the substrate component set.
