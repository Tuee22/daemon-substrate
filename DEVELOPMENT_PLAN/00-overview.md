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
out by Sprints 0.1 – 0.4. The doc validator (Phase 0 Sprint 0.5) is **deferred to Phase 7
Sprint 7.4**, where it lands as part of the test-lint gate; Phase 0 closure does not depend
on it.

### Phase 1 — library scaffolding and cabal package

Establish `daemon-substrate.cabal`, `cabal.project` (GHC 9.12 pinned, matching the
`hostbootstrap` base image), the empty `src/Daemon/` module skeleton, and a no-op CI build
that proves `cabal build all` succeeds. No public typeclass surface yet; just the structural
shell.

Depends on Phase 0 closing the documentation standards so the cabal layout doc can land
alongside the actual cabal file.

### Phase 2 — typeclasses: Pulsar, MinIO, Engine

Land the public typeclass surface: `HasPulsar`, `HasMinIO`, `HasEngine` (with both
`SubprocessEngine` and `NativeEngine` variants). Ship reference mock instances under the test
tree so the typeclasses can be exercised in unit tests without external services.

Also lands the `proto/` schemas listed in
[`../documents/reference/proto_surface.md`](../documents/reference/proto_surface.md) and the
generated `Daemon.Proto.*` modules.

Depends on Phase 1 because typeclass modules need a cabal stanza to live in.

### Phase 3 — daemon lifecycle and config

Land `BootConfig role app`, `DaemonRuntime`, `LifecyclePhase`, the signal handlers, the
`/readyz` and `/healthz` route shapes, and the Dhall decoder for `BootConfig`. This is the
scaffolding that the worker and orchestrator base loops sit inside.

Depends on Phase 2 because the lifecycle wires through `HasPulsar` / `HasMinIO` instances.

### Phase 4 — worker and orchestrator base loops + mock engine

Land `runWorker` and `runOrchestrator`. Land the test harness's mock engine implementation
(`NativeEngine` variant that returns placeholder bytes; mocks MinIO reads; mocks local cache
I/O). Land the `daemon-substrate-unit` test stanza coverage for the workflow-state and
consumer-step logic.

Depends on Phase 3 because the base loops use the lifecycle scaffolding.

### Phase 5 — kind cluster and Helm chart

Land `src/Daemon/Cluster/Kind.hs` (cluster bring-up / teardown / status), the `chart/`
directory with Harbor / Pulsar / MinIO chart dependencies and the orchestrator / worker
Deployment templates, and the `dhall/` configs for both roles. ConfigMap rendering wired up
so cluster bring-up materializes the staged Dhall files into the cluster.

Depends on Phase 4 because the chart needs working daemon binaries to deploy.

### Phase 6 — bootstrap and outer container

Land `hostbootstrap.dhall` at the repository root (declaring `Container` for Linux CPU and
`HostDaemon` for Apple Silicon) and the thin `docker/linux-substrate.Dockerfile`
(`FROM ${BASE_IMAGE}` plus the project's own build steps). After this phase, an operator can
run `hostbootstrap cluster up` on either cohort and reach a `Ready` cluster. Substrate
detection, host-prereq install, container / daemon lifecycle, and LaunchDaemon installation
are all handled by `hostbootstrap`; this phase only ships the project-side config and
Dockerfile.

Depends on Phase 5 because the inner reconcilers (kind / Harbor / Pulsar / MinIO /
orchestrator / worker) must exist before the outer entry can deliver a `Ready` cluster.

### Phase 7 — test harness integration

Land the `daemon-substrate-test` executable, the `daemon-substrate-integration` cabal test
stanza, and the end-to-end coverage described in
[`../documents/development/testing_strategy.md`](../documents/development/testing_strategy.md):
cluster lifecycle, orchestrator → worker handoff, MinIO fetch, mock engine result publish,
cache lifecycle, pod replacement, MinIO replacement.

Depends on Phase 6 because integration tests need the bootstrap-driven cluster bring-up.

## Cohort obligations

Every phase that touches the test harness (Phase 5 onward) carries both cohort obligations:
Apple Silicon and Linux CPU. A phase cannot move to `Done` until both cohorts have validated
the same phase state. See [development_plan_standards.md § Q](development_plan_standards.md).

## What is intentionally not a phase

- A separate doc-validator phase. The validator is implemented in **Phase 7 Sprint 7.4** as
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
