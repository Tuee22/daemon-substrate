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
- The library exposes substrate-agnostic typeclasses (`HasPulsar`, `HasMinIO`, `HasEngine`),
  role base loops (`runWorker`, `runOrchestrator`), and a typed `BootConfig role app` shape.
- The consumer brings the engine, the substrate-specific code (Metal FFI, CUDA FFI, etc.), the
  Dhall layout, the protobuf payload types, and the application data type plugged into
  `BootConfig`.

## Dependency mechanism

The supported consumption mechanism is `cabal.project` `path:`. Consumers clone
`daemon-substrate` as a sibling repository and reference it relatively:

```cabal
packages:
  .
  ../daemon-substrate

with-compiler: ghc-9.14.1
```

GHC pin (`9.14.1`) is shared across `daemon-substrate`, `infernix`, and `jitML`. Mismatched
compiler pins are not supported.

Alternative mechanisms — git submodules, vendoring with copy-paste, a published Hackage / git
dependency — are not part of the supported contract. If they become necessary, the plan changes
together with the implementation.

## Library surface

The library exposes these public modules (names finalized in the relevant phase):

| Module | Purpose | Owner |
|--------|---------|-------|
| `Daemon.Pulsar` | `HasPulsar` typeclass and `SubscriptionMode` (`Shared`, `KeyShared`, `Exclusive`, `Failover`) | library |
| `Daemon.MinIO` | `HasMinIO` typeclass with CAS / ETag semantics | library |
| `Daemon.MinIO.Cache` | non-authoritative ephemeral cache wrapper | library |
| `Daemon.Engine` | `HasEngine` typeclass and the `SubprocessEngine` / `NativeEngine` sum | library |
| `Daemon.Lifecycle` | `DaemonRuntime`, `LifecyclePhase`, signal handling | library |
| `Daemon.Config` | `BootConfig role app`, Dhall decoders, role tag | library |
| `Daemon.Worker` | `runWorker` base loop | library |
| `Daemon.Orchestrator` | `runOrchestrator` base loop | library |
| `Daemon.WorkflowState` | append-only workflow event ownership over Pulsar topics | library |
| `Daemon.Proto.*` | protobuf envelopes for substrate-owned messages | library |

## What the library owns

- Pulsar and MinIO transport plumbing (the typeclasses, the substrate-default subscription
  semantics, the ETag handling).
- The role-specific base loops (`runWorker`, `runOrchestrator`).
- The `BootConfig role app` shape, Dhall decoders, and the typed plug for consumer-specific
  configuration.
- Workflow event ownership patterns over Pulsar (the `WorkflowOwner` shape: replay on
  AcquireClients, append-then-step on write).
- Lifecycle scaffolding: phases, readiness signaling, signal handlers.
- Substrate-owned protobuf envelopes (orchestrator-to-worker control, worker status, generic
  workflow events).

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
  and substrate-agnostic; only the harness under `src/Daemon/Cluster/*`, `bootstrap/`,
  `docker/`, and `chart/` may branch on cohort, and only for cluster bring-up purposes.)
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
The harness lives outside `src/Daemon/*` — under `bootstrap/`, `docker/`, `chart/`,
`src/Daemon/Cluster/*`, and the `daemon-substrate-test` executable. Consumers do not run the
harness; it exists for `daemon-substrate`'s own validation. See
[../development/testing_strategy.md](../development/testing_strategy.md).

## Cross-references

- Daemon role definitions: [daemon_roles.md](daemon_roles.md)
- Pulsar / MinIO split: [pulsar_minio_ssot.md](pulsar_minio_ssot.md)
- Cabal package layout: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- Plan-level surface contract: [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)
