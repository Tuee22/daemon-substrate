# Library Consumption Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [daemon_roles.md](daemon_roles.md), [pulsar_minio_ssot.md](pulsar_minio_ssot.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define how downstream Haskell projects (`infernix`, `jitML`, future consumers)
> depend on, configure, and extend `daemon-substrate`, and what the library does versus what
> the consumer owns.

## TL;DR

- Consumers depend on `daemon-substrate` as a **Haskell library** via `cabal.project`'s
  `path:` mechanism. No binary, no Docker image, no published package.
- The library exposes substrate-agnostic typeclasses (`HasPulsar`, `HasMinIO`, `HasHarbor`,
  `HasKubectl`, `HasEngine`), five base loops (`runWorker`, `runOrchestrator`, `runBridge`,
  `runFanInBootstrap`, `runReconciler`), the `BootConfig role app` / `LiveConfig` /
  `LifecyclePolicy` configuration shapes, and the `runService` entry point.
- The consumer brings the engine, the substrate-specific code (Metal FFI, CUDA FFI, etc.), the
  Dhall layout, the protobuf payload types, the application data type plugged into
  `BootConfig`, the `OrchestratorBehavior` callbacks (fan-in / batch / fan-out / hydrate /
  bridge), and the `LifecyclePolicy` declaring which Pulsar topics and MinIO buckets it
  wants the substrate to manage.

## Dependency mechanism

The supported consumption mechanism is `cabal.project` `path:`. Consumers clone
`daemon-substrate` as a sibling repository and reference it relatively:

```cabal
packages:
  .
  ../daemon-substrate

with-compiler: ghc-9.12
```

GHC pin (`9.12`) is shared across `daemon-substrate`, `infernix`, and `jitML`, and matches the
GHC the [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image ships.
Mismatched compiler pins are not supported.

Consumers also depend on `hostbootstrap` for their own build, lifecycle, and bootstrap layer.
The dependency is at the *infrastructure* layer, not the Haskell-library layer:
`daemon-substrate`'s library surface is unchanged whether or not a consumer uses
`hostbootstrap`. See
[`../engineering/hostbootstrap_integration.md`](../engineering/hostbootstrap_integration.md)
for how `daemon-substrate` itself adopts `hostbootstrap`.

Alternative mechanisms — git submodules, vendoring with copy-paste, a published Hackage / git
dependency — are not part of the supported contract. If they become necessary, the plan changes
together with the implementation.

## Library surface

The library exposes these public modules (names finalized in the relevant phase):

| Module | Purpose | Owner |
|--------|---------|-------|
| `Daemon.Sub` | typed `Subprocess` boundary; every shell-out goes through here | library |
| `Daemon.Pulsar` | `HasPulsar` typeclass and `SubscriptionMode` (`Shared`, `KeyShared`, `Exclusive`, `Failover`) | library |
| `Daemon.Pulsar.Admin` | typed Pulsar admin operations (create / delete / terminate / set retention / export / import) | library |
| `Daemon.MinIO` | `HasMinIO` typeclass with CAS / ETag semantics | library |
| `Daemon.MinIO.Cache` | non-authoritative ephemeral cache wrapper | library |
| `Daemon.MinIO.Store` | generic content-addressed store (blobs / manifests / pointers + CAS) | library |
| `Daemon.MinIO.Admin` | typed MinIO bucket operations (create / lifecycle / list / delete) | library |
| `Daemon.Harbor` | `HasHarbor` typeclass (image registry operations) | library |
| `Daemon.Kubectl` | `HasKubectl` typeclass (cluster resource operations) | library |
| `Daemon.Engine` | `HasEngine` typeclass and the `SubprocessEngine` / `NativeEngine` sum | library |
| `Daemon.Config.BootConfig` | `BootConfig role app`, Dhall decoders, role tag | library |
| `Daemon.Config.LiveConfig` | SIGHUP-reloadable runtime config (retry policy, dedup cache, drain deadline) | library |
| `Daemon.Config.LifecyclePolicy` | Dhall decoders for `TopicLifecycle` / `BucketLifecycle` / `LifecyclePolicy` | library |
| `Daemon.Lifecycle` | 7-phase machine (`Load → Prereq → Acquire → Ready → Serve → Drain → Exit`), `runService` entry | library |
| `Daemon.Signal` | SIGHUP / SIGTERM / SIGINT handling | library |
| `Daemon.Audit` | compacted-topic helper for reconciler audit log | library |
| `Daemon.Consumer` | consumer-batch primitive + `HandlerRouter` + dedup cache | library |
| `Daemon.Worker` | `runWorker` base loop | library |
| `Daemon.Orchestrator` | `runOrchestrator` base loop | library |
| `Daemon.Bridge` | `runBridge` base loop (transform one topic, publish another) | library |
| `Daemon.Bootstrap` | `runFanInBootstrap` base loop (request → MinIO → ready event) | library |
| `Daemon.Reconciler` | `runReconciler` base loop (leader-elected Pulsar + MinIO lifecycle) | library |
| `Daemon.WorkflowState` | append-only workflow event ownership over Pulsar topics | library |
| `Daemon.Proto.*` | protobuf envelopes for substrate-owned messages (workflow, control, orchestrator↔worker, lifecycle, audit) | library |

## What the library owns

- Pulsar, MinIO, Harbor, and Kubectl transport / cluster-I/O plumbing (the typeclasses, the
  substrate-default subscription semantics, the ETag handling, the typed subprocess seam).
- The five base loops (`runWorker`, `runOrchestrator`, `runBridge`, `runFanInBootstrap`,
  `runReconciler`).
- The `BootConfig role app` / `LiveConfig` / `LifecyclePolicy` configuration shapes, Dhall
  decoders, and the typed plug for consumer-specific configuration.
- Workflow event ownership patterns over Pulsar (the `WorkflowOwner` shape: replay on
  `Acquire`, append-then-step on write).
- Lifecycle scaffolding: 7-phase machine, readiness / health / metrics HTTP endpoints, signal
  handlers, `runService` entry point.
- **Full lifecycle ownership of Pulsar topics and MinIO buckets / objects** declared in the
  consumer's `LifecyclePolicy` — the reconciler creates / configures / archives / deletes
  topics and buckets, runs MinIO orphan-scan with safety windows, and audits every action to a
  compacted Pulsar topic. See [lifecycle_policy.md](lifecycle_policy.md).
- The generic content-addressed `Daemon.MinIO.Store` (blobs / manifests / pointers with CAS).
- Substrate-owned protobuf envelopes (orchestrator-to-worker, worker status, generic workflow
  events, audit events).

## What the consumer owns

- The **engine**: the actual computation that runs against the hardware. Wrapped in either
  `SubprocessEngine` (process per request) or `NativeEngine` (in-process FFI).
- All **substrate-specific code**: Metal FFI, CUDA FFI, Apple host topology, GPU device
  enumeration, anything that talks to acceleration hardware directly.
- The **orchestrator's application logic.** `daemon-substrate` provides the orchestrator base
  loop (`runOrchestrator`), the role plumbing, and the lifecycle scaffolding. Consumer-specific
  orchestrator behavior — which upstream Pulsar topics to subscribe to, how to batch, which
  per-cohort worker topics to fan out to, which WAN registries to hydrate weights from, what
  the response envelopes look like — is supplied through the typed `BootConfig role app` plug
  and the consumer's own `app`-side code. `infernix` and `jitML` may carry completely
  different orchestrator behavior and Dhall shapes; the substrate prescribes the *shape* any
  orchestrator must fit into, not the *behavior* it performs.
- The **application data type** plugged into `BootConfig role app` (consumer-specific routing,
  engine selection, model registry).
- The **Dhall on-disk layout** and loader. The library defines the shape; the consumer decides
  where Dhall files live and how they're staged.
- Consumer-specific **protobuf payloads** that ride the substrate-owned envelopes.
- The consumer's own deployment artifacts: Helm charts, bootstrap scripts, Dockerfiles, kind
  setup. The substrate's own test harness is *not* a model for consumer deployment; consumers
  reuse infernix's or jitML's existing patterns.
- WAN-side concerns: model registry credentials, HuggingFace tokens, dataset acquisition.

## What is forbidden in library code

- branching on **cohort identifier** anywhere under `src/Daemon/*`. (`apple-silicon` and
  `linux-cpu` are *test-harness cohort* identifiers — used by the harness for cluster
  bootstrap, Pulsar topic suffixes, and Dhall file selection. The library proper is cohort-
  and substrate-agnostic; only the harness under `src/Daemon/Cluster/*`, `hostbootstrap.dhall`,
  `docker/linux-substrate.Dockerfile`, and `chart/` may branch on cohort, and only for
  cluster bring-up purposes.)
- environment-variable reads (`lookupEnv`, `getEnv`, `getEnvironment`, `setEnv`)
- `proc "<bare-command-name>"` invocations (anything resolved via `$PATH`)
- direct WAN access (the substrate never talks to HuggingFace, S3, or any external endpoint;
  the consumer's Orchestrator does)
- carrying authoritative state outside Pulsar and MinIO

These rules match the consumer projects' own doctrines so the library never relaxes a
constraint the consumer enforces.

## Substrate-aware test harness

The library code is substrate-agnostic; the *test harness* that proves the library works is
necessarily substrate-aware for cluster bootstrap (Apple host build vs Linux outer container).
The harness lives outside `src/Daemon/*` — under `hostbootstrap.dhall`,
`docker/linux-substrate.Dockerfile`, `chart/`, `src/Daemon/Cluster/*`, and the
`daemon-substrate-test` executable. The substrate-specific bring-up itself is delegated to
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap); see
[`../engineering/hostbootstrap_integration.md`](../engineering/hostbootstrap_integration.md).
Consumers do not run the harness; it exists for `daemon-substrate`'s own validation. See
[../development/testing_strategy.md](../development/testing_strategy.md).

## Cross-references

- Daemon role definitions: [daemon_roles.md](daemon_roles.md)
- Pulsar / MinIO split: [pulsar_minio_ssot.md](pulsar_minio_ssot.md)
- Cabal package layout: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- Plan-level surface contract: [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)
