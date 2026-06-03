# Testing Strategy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [local_dev.md](local_dev.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../engineering/mock_engine.md](../engineering/mock_engine.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md), [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)

> **Purpose**: Canonical home for the `daemon-substrate-test test ...` command surface — what
> each command does, what it asserts, and which cohort owns which obligation. Names the
> integration-coverage table the test harness must satisfy.

## TL;DR

- `daemon-substrate-test test unit` — pure logic, no cluster, runs anywhere.
- `daemon-substrate-test test lifecycle` — daemon-as-process, signals + readiness probes, no
  cluster.
- `daemon-substrate-test test integration` — end-to-end against a real kind cluster.
- `daemon-substrate-test test lint` — `ormolu`, `hlint`, doc and proto lints.
- `daemon-substrate-test test all` — runs the above in order.
- Two cohorts: Apple Silicon, Linux CPU. Both must close for a phase to move to `Done`.
- On both cohorts the operator entrypoint is `hostbootstrap cluster up`; the
  `daemon-substrate-test test ...` commands run inside the resulting environment.

## Command surface

| Command | Cohort coverage | Cluster required | Approximate runtime |
|---------|------------------|------------------|---------------------|
| `daemon-substrate-test test unit` | both | no | seconds |
| `daemon-substrate-test test lifecycle` | both | no | < 1 minute |
| `daemon-substrate-test test integration` | both | yes | minutes |
| `daemon-substrate-test test lint` | both | no | seconds |
| `daemon-substrate-test test all` | both | yes | minutes (lint + unit + lifecycle + integration) |

`daemon-substrate-test test e2e` is reserved for future use. The current harness does not
expose a browser- or HTTP-API-driven surface, so e2e is out of scope until a phase opens it.

## Workflow coverage table

The integration suite must cover every row below. Rows 1–2 are also touched by the
`lifecycle` stanza for signal-handling coverage without a cluster.

| # | Workflow | Validates | jitML uses? | infernix uses? |
|---|----------|-----------|-------------|-----------------|
| 1 | Lifecycle: `Load → Prereq → Acquire → Ready → Serve → Drain → Exit` | `Daemon.Lifecycle`, signal handlers, `/readyz` | yes | yes |
| 2 | `SIGHUP` reloads `LiveConfig` mid-run | LiveConfig swap without dropping in-flight | yes | yes (planned) |
| 3 | Worker consumes a `MockBatch` from `test.batch.<cohort>` (Shared) | `runWorker`, `HasPulsar.subscribe` | yes | yes |
| 4 | Worker dispatches to `HasEngine` mock, publishes `MockResult` | `HasEngine` + result publish | yes | yes |
| 5 | Two worker replicas split a Shared subscription, no duplicate processing | Pulsar shared semantics | yes (Linux) | yes (Linux) |
| 6 | Worker `putBlobIfAbsent` to MinIO, second worker reads it | `Store.putBlob` / `readBlob` | yes | yes |
| 7 | `casPointer` succeeds with correct ETag; fails with stale ETag | `Store.casPointer` | yes | yes |
| 8 | Worker dedup: same `EventId` twice → handler runs once | `Daemon.Consumer` dedup cache | yes | yes |
| 9 | Worker negative-acks; broker redelivers; second attempt succeeds | retry policy | yes | yes |
| 10 | Cache cold path: warm MinIO read populates ephemeral local cache | `MinIO.Cache` | yes | yes |
| 11 | Cache warm path: second request hits local cache | `MinIO.Cache` | yes | yes |
| 12 | Cache eviction under size pressure | LRU / size policy | yes | yes |
| 13 | Orchestrator fan-in: orchestrator batches and fans out to per-cohort worker topic | `runOrchestrator` batch policy | yes | yes |
| 14 | Orchestrator result bridge: worker result → orchestrator → upstream caller | `runBridge` | yes | yes |
| 15 | Orchestrator WAN hydration: hydrate request → mock download → MinIO write → ready event | `runFanInBootstrap` | yes | yes |
| 16 | Orchestrator replica failure: one of two replicas dies; Pulsar redelivers in-flight to survivor | shared-subscription failover | yes | yes |
| 17 | Worker pod replacement (Linux only): `kubectl delete pod`; new pod resumes from Pulsar cursor | pod-restart durability | yes | yes |
| 18 | MinIO StatefulSet replacement: delete MinIO pod; verify cache still serves warm keys; cold fetch repopulates | MinIO durability | yes | yes |
| 19 | Cluster bring-up phases all complete on a fresh `hostbootstrap cluster up` | `Daemon.Cluster.*` | yes | yes |
| 20 | `cluster down → cluster up` preserves `./.data/` and re-reaches `Ready` quickly | persistence | yes | yes |
| 21 | Reconciler creates missing Pulsar topics declared in `LifecyclePolicy` | `runReconciler` + `Daemon.Pulsar.Admin` | yes | yes |
| 22 | Reconciler creates missing MinIO buckets declared in `LifecyclePolicy` | `runReconciler` + `Daemon.MinIO.Admin` | yes | yes |
| 23 | Two orchestrator replicas: only one is the active reconciler (Failover sub) | leader election | yes | yes |
| 24 | Kill the active reconciler replica; standby promotes; reconciliation continues from audit | leader failover | yes | yes |
| 25 | `Ephemeral` topic mode: retention expiry; dedup window honored | `TopicLifecycle Ephemeral` | yes | yes (request topics) |
| 26 | `ContinuousWithArchive` topic mode: hot→cold export; MinIO archive object reachable; MinIO retention triggers delete | `TopicLifecycle ContinuousWithArchive` | n/a | yes (inference history) |
| 27 | `FiniteSession` topic mode: live during session; on session-end → terminate + export to MinIO; on session-resume → topic re-opens | `TopicLifecycle FiniteSession` | yes (training run) | n/a |
| 28 | `OnlineLearning` topic mode: split hot windows for inference vs training streams; rolling archive | `TopicLifecycle OnlineLearning` | yes (planned) | yes (planned) |
| 29 | MinIO orphan scan: object outside the reachable closure AND older than safety window is hard-deleted; reachable objects are not | mark-and-sweep correctness | yes | yes |
| 30 | MinIO orphan scan: object younger than safety window is **never** deleted, even if unreachable | safety window | yes | yes |
| 31 | Lifecycle reconcile is idempotent: 2× back-to-back reconcile = identical end state, no churn | reconcile fixed-point | yes | yes |
| 32 | Audit topic replay: stop reconciler mid-tick; restart; new leader replays audit and does not re-execute completed actions | audit topic correctness | yes | yes |

## What each command exercises

### `test unit`

The `daemon-substrate-unit` cabal stanza. Pure Haskell tests, no external services. Covers:

- protobuf encode / decode round-trips for every substrate-owned envelope (including the
  audit envelope)
- `WorkflowOwner` step-fold semantics against handcrafted event sequences
- `BootConfig` / `LiveConfig` / `LifecyclePolicy` Dhall decoders against fixture Dhall files
  in `test/unit/fixtures/`
- `Store` semantics over `Daemon.Test.FilesystemMinIO`
- `Daemon.MinIO.Cache` eviction policies under simulated key sets
- `Daemon.Consumer.consumerStep` dedup behavior over `Daemon.Test.FilesystemPulsar`
- reconciler tick correctness against filesystem-backed Pulsar + MinIO

### `test lifecycle`

The `daemon-substrate-lifecycle` cabal stanza. Daemon spawned as a real process (no cluster).
Covers:

- 7-phase lifecycle progression observable via `/readyz`
- SIGHUP → `LiveConfig` reload visible in subsequent behavior
- SIGTERM / SIGINT → graceful drain completes within `LiveConfig.drainDeadlineSeconds`

### `test integration`

The `daemon-substrate-integration` cabal stanza. Requires a running kind cluster brought up
by `hostbootstrap cluster up`. Covers rows 3–32 above.

### `test lint`

The `daemon-substrate-haskell-style` cabal stanza. `ormolu` + `hlint` against `src/` plus the
doc validator (the Phase 0 Sprint 0.5 obligation that lands in Phase 8 Sprint 8.5) and the
proto validator.

### `test all`

Runs `lint`, then `unit`, then `lifecycle`, then `integration` in sequence. Stops at the
first failure.

## Cohort obligations

Per [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § Q](../../DEVELOPMENT_PLAN/development_plan_standards.md),
both cohorts (Apple Silicon, Linux CPU) must close before a phase that touches the harness can
move to `Done`. Sprint validation language distinguishes local-cohort closure from
counterpart-cohort pending status.

On both cohorts the operator entrypoint is `hostbootstrap cluster up`; the `daemon-substrate-test
test ...` commands run inside the resulting environment (`./.build/daemon-substrate-test ...`
on Apple Silicon; `hostbootstrap run daemon-substrate-test ...` on Linux CPU). See
[../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

There is no GPU cohort. The mock engine performs no accelerator work; adding a GPU cohort
would cost without coverage.

## What this strategy does not cover

- Real ML model correctness — that is the consumer projects' obligation against their own
  matrices.
- WAN→MinIO weight hydration with real registries (HuggingFace, etc.) — the harness simulates
  this via `runFanInBootstrap` with a mock download function; real hydration is the consumer's
  deployment problem.
- Cross-substrate parity for consumer workloads — the substrate is parity-agnostic.

## Cross-references

- Lifecycle policy story (the source for rows 21–32): [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md)
- Mock engine specification: [../engineering/mock_engine.md](../engineering/mock_engine.md)
- Cabal stanzas: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- CLI surface details: [../reference/cli_surface.md](../reference/cli_surface.md)
- Cluster bring-up: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
