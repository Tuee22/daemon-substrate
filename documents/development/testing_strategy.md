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
- `daemon-substrate-test test lint` — governed-doc validation plus the direct
  `Daemon.Proto.*` import boundary.
- `daemon-substrate-test test all` — runs the above in order.
- One substrate-keyed `hostbootstrap.dhall` maps Apple Silicon to `HostDaemon`, Linux CPU to
  `Container`, and Linux GPU to `HostBinary`. The operator entrypoint is
  `hostbootstrap cluster up` (`hostbootstrap` installed via `pipx`); HostDaemon workers are
  foreground `hostbootstrap daemon run` processes owned by the test harness or operator; the
  `daemon-substrate-test test ...` commands run inside the resulting environment.
- `--force-target` can exercise all three declared targets on one machine, while full hardware
  validation still uses three machines.
- **Coverage model** is the full **3×3 matrix**: each of the three execution models
  (`Container`, `HostBinary`, `HostDaemon`) exercising each of three ML workflow archetypes —
  (a) continuous batched inference (≈ `infernix`), (b) finite SL / offline-RL training jobs
  (≈ `jitML`), and (c) continuous online RL (MinIO weight updates announced on Pulsar
  inference topics, with distinct training-vs-inference task messages routable to
  same-or-separate stateless engines). `Daemon.Test.Matrix` records the matrix and unit tests
  assert that every model/archetype pair is present.

Current implementation note: Phase 8 implements the executable parser, help surface, Cabal
test delegation, four test stanzas, live cluster runner, deployable dependency charts,
PVC-backed kind state, live service loops, and the integration readiness gate. Apple Silicon
live validation covers cluster bring-up, PVC-backed state preservation, native Pulsar
Failover leadership for the reconciler, live Pulsar/MinIO admin interactions, host-worker
edge-port handoff, and a live request -> orchestrator -> host worker -> response smoke
handoff. Phase 8 Sprint 8.7 adds the execution-model marker used by the integration gate and
the 3×3 matrix audit map. Linux live validation covers hostbootstrap container bring-up,
two preserved-state kind cycles, retained PV reattachment, worker/orchestrator
readiness, edge-port preservation, and the `daemon-substrate-integration` live readiness gate.
Rows 1-36 below
are the workflow audit map tying automated unit coverage, live readiness checks, and
manual live-smoke evidence to consumer-representative behavior; they are not each a
separate integration-test case today.

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

The coverage table below is the audit map for substrate behavior. Rows 1-2 are directly
covered by lifecycle/unit gates without a cluster. Rows 3-36 are covered by a mix of unit
tests, live readiness checks, and documented live-smoke validation; future hardening can
split more rows into dedicated integration-test cases without changing the supported
architecture.

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
| 16 | Orchestrator replica failure (data plane): one of two `Shared`-subscribed replicas dies; Pulsar redelivers in-flight messages to the surviving Shared-mode consumer | Pulsar `Shared`-subscription redelivery (distinct from the `Failover` leader election in row 23) | yes | yes |
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
| 33 | `Daemon.WorkflowState` rehydration: kill a worker mid-stream; new replica reads back the Pulsar log on `AcquireClients` and reconstructs the in-memory fold to byte-identical state before resuming `Serve` | `runWorker` + `Daemon.WorkflowState.rehydrate` semantics (distinct from row 17's Pulsar-cursor resumption) | yes (training optimizer state, AlphaZero MCTS tree) | yes (durable conversation context across coordinator restarts) |
| 34 | Producer-side dedup: the same payload published twice under the same idempotency key produces exactly one consumer delivery | `HasPulsar.publish` idempotent-producer wiring (distinct from row 8's consumer-side dedup cache) | yes (training-run submission) | yes (`client_idempotency_key` on `InferenceRequest`) |
| 35 | Engine forced failure: `MockRequest.force_failure = true` → mock engine returns `EngineNativeError` → worker publishes `WorkerResult { FailurePayload }` → orchestrator routes the failure to the caller without retry | `HasEngine` terminal-failure semantics + `FailurePayload` propagation (distinct from row 9's neg-ack retry path) | yes (Failed / Cancelled status fields) | yes (Completed / Failed / Cancelled status on `InferenceResult`) |
| 36 | HostDaemon worker ↔ in-cluster Pulsar: a caller-owned foreground `hostbootstrap daemon run` process subscribes via the edge port, publishes to `test.result`, is terminated before `cluster down`, and is started after `cluster up` | host-daemon path through `HasPulsar` against the in-cluster broker | yes (jitML `ForwardToHost` Apple inference RPC) | yes (infernix Apple host daemon on `inference.batch.apple-silicon.host`) |

## Consumer surface mapping

The coverage table above validates substrate plumbing. This section ties each row to the
load-bearing surfaces in the two consumer repos so the representativeness claim is auditable:
anyone can ask "does the substrate test harness simulate X?" and answer it by name.

Substrate **does not** validate consumer-owned ML correctness, hardware acceleration, or
real model matrices — those remain `infernix` and `jitML` obligations. See
[../../DEVELOPMENT_PLAN/development_plan_standards.md § P](../../DEVELOPMENT_PLAN/development_plan_standards.md).

### infernix

| Consumer surface | Source in `~/infernix` | Covered by row(s) |
|------------------|------------------------|---------------------|
| Coordinator single-flight dispatch (`inference.request.<mode>` → `inference.batch.<mode>`) | `proto/infernix/runtime/inference.proto`, coordinator role | 13 (orchestrator fan-in), 8 (consumer dedup) |
| Engine model bootstrap (`.ready` sentinel after MinIO put) | `infernix.cabal` engine role | 15 (`runFanInBootstrap`) |
| Result bridge to durable conversation topic | infernix coordinator role | 14 (`runBridge`) |
| Apple host daemon over `inference.batch.apple-silicon.host` | `infernix/CLAUDE.md`, Apple substrate | 36 |
| Producer-side dedup on `client_idempotency_key` | `inference.proto` `InferenceRequest` | 34 |
| Completed / Failed / Cancelled status propagation | `InferenceResult.status` | 35 |
| `ContinuousWithArchive` for inference history | `infernix/README.md` | 26 |
| Durable conversation context across coordinator restarts | conversation log; KV-prefix rebuild | 33 |
| Worker pod replacement preserving Pulsar cursor | engine Deployment + Pulsar Shared sub | 17 |
| MinIO model-weights bucket cold / warm fetch | `infernix-models` bucket | 10, 11, 12 |

### jitML

| Consumer surface | Source in `~/jitML` | Covered by row(s) |
|------------------|---------------------|---------------------|
| Training command + event stream | `proto/jitml/training.proto` | 3, 4, 13, 14 |
| Multi-object checkpoint snapshot (`jitml-snapshots/.../{weights, optimizer, manifest}`) | `jitml.cabal` Store usage | 6, 7 (CAS), 22 (bucket reconciliation) |
| Training optimizer state + AlphaZero MCTS tree rehydration | `WorkflowOwner` step-fold semantics | 33 |
| Apple `ForwardToHost` cluster→host RPC (`inference.command.apple-silicon`) | `jitml/README.md` Apple hybrid mode | 36 |
| `EventId` dedup over `WorkflowOwner` fold | `WorkflowOwner` semantics | 8 |
| `FiniteSession` topic mode (training-run lifecycle) | jitML DEVELOPMENT_PLAN | 27 |
| `OnlineLearning` topic mode (inference + training streams) | jitML DEVELOPMENT_PLAN | 28 |
| MinIO GC / orphan scan with safety window (`gc.event.<substrate>`) | `jitml.cabal` GC handler | 29, 30 |
| Idempotent reconciliation across substrates | jitML phases 13–15 | 31, 32 |
| Idempotent producer for training-run submission | producer dedup key | 34 |
| Engine terminal failure with error propagation | recoverable-vs-terminal error envelopes | 35 |
| MinIO StatefulSet replacement preserving warm cache | snapshots / TensorBoard buckets | 18 |

### Rows that are intentionally substrate-internal

The following rows have no consumer-surface listing because they validate the substrate's own
plumbing rather than any consumer-visible behavior:

- 1 (lifecycle phases), 2 (SIGHUP reload), 5 (Shared subscription split), 19 (cluster
  bring-up), 20 (`.data/` preservation), 21 (topic reconciliation), 23 (leader election),
  24 (leader failover), 25 (`Ephemeral` retention), 32 (audit replay).

These are load-bearing for both consumers indirectly — every consumer daemon goes through
them — but they are not features either consumer's code calls out as their own.

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

The `daemon-substrate-integration` cabal stanza. It requires a running kind cluster brought
up by `hostbootstrap cluster up` or an equivalent inner `daemon-substrate-test cluster up`.
It discovers the repo-local kubeconfig and edge-port record under `./.data/runtime/` for the
`container` model or `./.build/` for host-native models, then reads the persisted execution
model marker when present. The current live gate checks:

- cohort-specific kind node count and node readiness
- Harbor, Pulsar, and MinIO StatefulSet rollouts
- orchestrator Deployment rollout and Linux worker Deployment rollout
- expected app pod readiness
- Harbor, Pulsar, and MinIO PVCs bound to retained PVs
- edge-port record fields for Pulsar, Pulsar admin, and MinIO

Broader workflow rows remain represented by the unit suites and the live-smoke validation
called out in the phase plan.

### `test lint`

The `daemon-substrate-haskell-style` cabal stanza. It enforces:

- governed-document metadata blocks, required broad-doc headings, relative Markdown link
  resolution, root README links to `documents/` and `DEVELOPMENT_PLAN/`, and phase-file
  `## Documentation Requirements` retention
- no direct `Daemon.Proto.*` imports outside the approved wire/boundary modules

### `test all`

Runs `lint`, then `unit`, then `lifecycle`, then `integration` in sequence. Stops at the
first failure.

## Host and model obligations

Per [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § Q](../../DEVELOPMENT_PLAN/development_plan_standards.md),
the harness must validate the three declared hostbootstrap targets: Apple Silicon
`HostDaemon`, Linux CPU `Container`, and Linux GPU `HostBinary`. The current harness records
the 3×3 model × workflow matrix in `Daemon.Test.Matrix`; the integration gate keys node-count
and worker-placement expectations from the selected execution model rather than from raw host
detection.

The operator entrypoint is `hostbootstrap cluster up`; the `daemon-substrate-test test ...`
commands run inside the resulting environment (`hostbootstrap run ...` for the selected
target, or `./.build/daemon-substrate-test ...` after host-native builds). For HostDaemon
targets, the harness must also own a foreground `hostbootstrap daemon run` process. Use
`--force-target` to complete the target matrix on one machine. See
[../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

The mock engine performs no accelerator work. The Linux GPU target validates the hostbootstrap
target/model lifecycle and CUDA-flavored base-image path, not CUDA computation.

## What this strategy does not cover

- Real ML model correctness — that is the consumer projects' obligation against their own
  matrices.
- WAN→MinIO weight hydration with real registries (HuggingFace, etc.) — the harness simulates
  this via `runFanInBootstrap` with a mock download function; real hydration is the consumer's
  deployment problem.
- Cross-substrate parity for consumer workloads — the substrate is parity-agnostic.

## Cross-references

- Lifecycle policy story (the source for rows 21–32): [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md)
- Consumer workload sources (mapped to rows below): `~/infernix` (`infernix.cabal`, `proto/infernix/runtime/inference.proto`); `~/jitML` (`jitml.cabal`, `proto/jitml/*.proto`)
- Mock engine specification: [../engineering/mock_engine.md](../engineering/mock_engine.md)
- Cabal stanzas: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- CLI surface details: [../reference/cli_surface.md](../reference/cli_surface.md)
- Cluster bring-up: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
