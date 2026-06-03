# Testing Strategy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [local_dev.md](local_dev.md), [../engineering/cabal_layout.md](../engineering/cabal_layout.md), [../engineering/mock_engine.md](../engineering/mock_engine.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)

> **Purpose**: Canonical home for the `daemon-substrate-test test ...` command surface — what
> each command does, what it asserts, and which cohort owns which obligation.

## TL;DR

- `daemon-substrate-test test unit` — pure logic, no cluster, runs anywhere.
- `daemon-substrate-test test integration` — end-to-end against a real kind cluster, both
  cohorts.
- `daemon-substrate-test test lint` — `ormolu`, `hlint`, doc and proto lints.
- `daemon-substrate-test test all` — runs the above in order.
- Two cohorts: Apple Silicon, Linux CPU. Both must close for a phase to move to `Done`.

## Command surface

| Command | Cohort coverage | Cluster required | Approximate runtime |
|---------|------------------|------------------|---------------------|
| `daemon-substrate-test test unit` | both | no | seconds |
| `daemon-substrate-test test integration` | both | yes | minutes |
| `daemon-substrate-test test lint` | both | no | seconds |
| `daemon-substrate-test test all` | both | yes | minutes (lint + unit + integration) |

`daemon-substrate-test test e2e` is reserved for future use. The current harness does not
expose a browser- or HTTP-API-driven surface, so e2e is out of scope until a phase opens it.

## What each command exercises

### `test unit`

The `daemon-substrate-unit` cabal stanza. Pure Haskell tests, no external services. Covers:

- protobuf encode / decode round-trips for every substrate-owned envelope
- `WorkflowOwner` step-fold semantics against handcrafted event sequences
- `BootConfig` Dhall decoders against fixture Dhall files in `test/unit/fixtures/`
- `Daemon.MinIO.Cache` eviction policies under simulated key sets
- `Daemon.Consumer.consumerStep` dedup behavior over duplicated event IDs

### `test integration`

The `daemon-substrate-integration` cabal stanza. Requires a running kind cluster brought up by
`daemon-substrate-test cluster up`. The command preflights cluster readiness and fails fast if
the cluster is not up. Covers:

- **Cluster lifecycle**: up / status / down idempotency; `./.data/` and `./.build/`
  preservation across down→up
- **Orchestrator → worker handoff**: orchestrator publishes a `MockBatch` to
  `test.batch.<cohort>`, both worker replicas consume from the `Shared` subscription, only
  one processes each message
- **MinIO fetch**: worker reads the requested `mock/v1/<weight_key>` from
  `daemon-substrate-test-weights`, populates the local cache, repeat request hits the cache
- **Result publication**: worker publishes `MockResult` on `test.result`; orchestrator
  consumes; result hash matches the deterministic SHA-256 expectation
- **Failure / retry**: `MockRequest{ force_failure = true }` causes worker to negatively
  acknowledge; broker redelivers; second attempt succeeds when the flag is cleared
- **Dedup**: same `MockRequest` sent twice results in one `MockResult` (consumer-side dedup
  inside the dedup window)
- **Pod replacement**: kill the worker pod with `kubectl delete pod`; verify k8s replaces it;
  verify the new pod resumes from the Pulsar cursor without reprocessing acknowledged
  messages
- **MinIO replacement**: delete the MinIO StatefulSet pod; verify recovery; verify cache
  still serves warm keys; verify cold fetch re-populates from the recovered MinIO

### `test lint`

`ormolu` and `hlint` against `src/`. Also runs:

- doc validator (when implemented; until then, a forward-referenced check)
- proto validator: every file in `proto/` compiles, every generated module under
  `src/Daemon/Proto/` matches its source

### `test all`

Runs `lint`, then `unit`, then `integration` in sequence. Stops at the first failure.

## Cohort obligations

Per [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § Q](../../DEVELOPMENT_PLAN/development_plan_standards.md),
both cohorts (Apple Silicon, Linux CPU) must close before a phase that touches the harness can
move to `Done`. Sprint validation language distinguishes local-cohort closure from
counterpart-cohort pending status.

There is no GPU cohort. The mock engine performs no accelerator work; adding a GPU cohort
would cost without coverage.

## What this strategy does not cover

- Real ML model correctness — that is the consumer projects' obligation against their own
  matrices.
- WAN→MinIO weight hydration with real registries (HuggingFace, etc.) — the harness simulates
  this by seeding MinIO at `cluster up`; real hydration is the consumer's deployment problem.
- Cross-substrate parity for consumer workloads — the substrate is parity-agnostic.

## Cross-references

- Mock engine specification: [../engineering/mock_engine.md](../engineering/mock_engine.md)
- Cabal stanzas: [../engineering/cabal_layout.md](../engineering/cabal_layout.md)
- CLI surface details: [../reference/cli_surface.md](../reference/cli_surface.md)
- Cluster bring-up: [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
