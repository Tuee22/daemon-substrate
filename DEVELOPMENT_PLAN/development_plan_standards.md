# daemon-substrate Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md)

> **Purpose**: Define how the `daemon-substrate` development plan is organized, updated, and kept
> aligned with implementation, validation, and the governed `documents/` suite.

## Core Principles

### A. Continuous Execution-Ordered Narrative

The plan reads as one ordered buildout from empty repository to a stable shared substrate consumed
by `infernix` and `jitML`.

- Each phase is written after the previous phase in dependency order.
- When later implementation lands before an earlier phase's final closure obligation, the later
  phase explicitly names the open dependency in its `Phase Status` or `Current Repo Assessment`
  text instead of pretending the prerequisite is fully closed.
- Phase 0 is always documentation and governance. No code-writing phase may be marked `Active` or
  `Done` before Phase 0 closes.
- Newly discovered gaps are handled by adding explicit follow-on work, not by leaving stale
  completion claims in older documents.
- A reader unfamiliar with the repo should be able to follow the plan from top to bottom without
  reconstructing hidden dependencies.

### B. Detailed, Implementation-Oriented Content

The plan is intentionally concrete.

- Include real files, module paths, typeclass signatures, and validation gates where they
  materially clarify what must be built.
- Examples do not need to be verbatim implementation, but they must not contradict the supported
  architecture.
- When the plan cites `infernix` or `jitML` as the consumer projects, it explicitly distinguishes
  substrate concerns owned by this repository from consumer-specific features, runtime surfaces,
  or validation requirements that remain out of scope for `daemon-substrate`.

### C. Honest Completion Tracking

Status describes the current repository state, not the intended future state.

| Status | Meaning |
|--------|---------|
| `Done` | Implemented and validated; no remaining work |
| `Active` | Partially closed; remaining work is listed explicitly |
| `Blocked` | Waiting on a named prerequisite |
| `Planned` | Ready to start; dependencies are already satisfied |

Rules:

- `Done` requires passing validation, aligned docs, and no remaining work within the scope owned
  by that phase or sprint.
- `Active` requires a `Remaining Work` section.
- `Blocked` requires a `Blocked by` line naming the prerequisite phase or sprint.
- `Planned` must not hide unmet blockers.
- If Phase 0 is still open, later code-writing phases use `Blocked`, not `Planned`.
- A later phase may remain `Done` while an earlier phase is still `Active` or `Blocked` only when
  the earlier open item is a clearly named external dependency, and the later phase calls that
  dependency out explicitly in its phase-status or current-assessment text.

### D. Declarative Current-State Language

Plan documents describe the intended supported architecture in present-tense declarative language.

- Say what the library exposes, owns, validates, and requires of consumers.
- Do not turn phase docs into migration diaries.
- Cleanup history belongs in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### E. One Canonical Folder Model

The authoritative plan lives in this exact layout:

```text
DEVELOPMENT_PLAN/
├── development_plan_standards.md
├── README.md
├── 00-overview.md
├── system-components.md
├── phase-0-documentation-and-governance.md
├── phase-1-library-scaffolding-and-cabal-package.md
├── phase-2-typeclasses-pulsar-minio-engine.md
├── phase-3-daemon-lifecycle-and-config.md
├── phase-4-worker-and-orchestrator-base-loops.md
├── phase-5-kind-cluster-and-helm-chart.md
├── phase-6-bootstrap-and-outer-container.md
├── phase-7-test-harness-integration.md
└── legacy-tracking-for-deletion.md
```

Phase numbering may grow as later work is scoped. Adding or renaming a phase requires updating
this file, `README.md`, `00-overview.md`, and `system-components.md` in the same change.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative inventory for:

- public Haskell module surfaces under `Daemon.*`
- typeclasses exposed to consumers (`HasPulsar`, `HasMinIO`, `HasEngine`)
- protobuf schemas under `proto/`
- daemon role inventory (Worker, Orchestrator) and their lifecycle hooks
- shared lifecycle phases and their order
- serialization boundaries between the library and its consumers

When the substrate architecture changes, update the component inventory in the same change.

### G. Phase Document Requirements

Each phase document must contain sprint-level sections in this format:

```markdown
## Sprint X.Y: Name [STATUS]

**Status**: Done | Active | Planned | Blocked
**Implementation**: `path/to/file` (required for Done, recommended for Active)
**Blocked by**: sprint id(s) (required for Blocked)
**Docs to update**: `documents/...`, `README.md`

### Objective

### Deliverables

### Validation

### Remaining Work
```

Additional sections such as `Module Surface`, `Typeclass Contract`, `Protobuf Schema`, or
`Lifecycle Hooks` are encouraged when they clarify closure criteria.

### H. Documentation Requirements Section

Every phase document ends with a `## Documentation Requirements` section.

Use this format:

```markdown
## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/X.md` - technical contract or implementation note

**Reference docs to create/update:**
- `documents/reference/Y.md` - public typeclass or protobuf surface

**Cross-references to add:**
- align the relevant plan and README entry points
```

Bootstrap rule preserved for ordered-plan readability:

- Before Phase 0 closes, paths under `documents/` do not necessarily exist yet. They still appear
  in `Docs to update` and `Documentation Requirements` because the plan must make documentation
  obligations explicit before the suite exists.
- When a phase creates or materially rewrites a broad engineering document, the owning sprint or
  phase calls out the intended document structure when it matters to closure criteria:
  - add a `TL;DR` or `Executive Summary` when the topic is broad
  - include an explicit `Current status` note when implemented behavior and target direction
    appear in the same document
  - include a `Validation` section when the document defines a contract that tests or lint must
    prove
  - answer these questions directly: what is the rule, what is current versus target, how is it
    validated, and what is library-internal detail versus consumer-facing contract

### I. Explicit Cleanup and Removal Ledger

[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the authoritative cleanup
ledger for obsolete module paths, duplicate guidance, and stale compatibility surfaces.

- If an obsolete or duplicate surface still exists, it must appear in the ledger.
- Each item names its location, why it is slated for removal, and the owning phase or sprint.
- When cleanup lands, move the item from pending to completed.

### J. README and Documents Harmony

The plan and the governed `documents/` suite must agree on current-state implementation status.
The root `README.md` is exempt from current-state status parity because it is intentionally
written as the finished-library orientation document.

- `00-overview.md`, all phase files, and `system-components.md` use the same phase names and
  current-state claims.
- `README.md` still reflects the authoritative intended library shape, public typeclass surface,
  daemon role model, configuration substrate, and validation direction described by the plan,
  even when those capabilities are not fully implemented yet.
- `README.md`, `AGENTS.md`, and `CLAUDE.md` are governed root documents. When a sprint owns
  root-document governance, it explicitly states which file is canonical for a topic and which
  files are orientation or automation entry documents only.
- Root-document governance work calls out the metadata rules those files must follow, including
  explicit `Status`, `Supersedes`, and `Canonical homes` markers that distinguish canonical
  guidance from reference-only guidance.
- Root documents that are not canonical for a topic summarize and link to the canonical
  `documents/` home instead of restating the full contract.
- Once Phase 0 has landed, `documents/documentation_standards.md` governs the docs suite while
  this file remains authoritative for the plan itself.

### K. Daemon Role Contract

`daemon-substrate` supports two distinct daemon roles. Every base-loop sprint must name which
role it targets, and every typeclass or lifecycle hook must declare whether it is role-specific
or shared.

**Worker** — one stateless daemon per physical node, owns all acceleration hardware on that node.

- Workers may run as a Kubernetes Deployment (with `requiredDuringScheduling` pod anti-affinity
  on `kubernetes.io/hostname`) or as a host-level daemon outside the cluster. The library code
  is identical in both cases.
- Workers are **stateless**. The library does not provide, and worker base loops must not use,
  `flock(2)`, PID files, lockfiles, or any OS-level concurrency guard. The one-worker-per-queue
  invariant is enforced by Pulsar's at-most-once delivery on shared subscriptions, not by the
  filesystem.
- Workers may keep an ephemeral local cache for blobs they have already fetched from MinIO. The
  cache is non-durable (loss of the cache must not lose data), exclusive to the daemon (no other
  process reads or writes it), and aggressively pruned by the worker itself.
- On crash, restart, or reschedule, a worker recovers everything it needs by re-reading its Dhall
  config, re-subscribing to its assigned Pulsar topics, and re-fetching blobs from MinIO. There
  is no node-local authoritative state.

**Orchestrator** — always runs **in-cluster** as a horizontally scalable Kubernetes
Deployment, responsible for fan-in / batching / fan-out / result collection and for hydrating
MinIO from the WAN before worker dispatch.

- Orchestrators deploy with `replicas: N` (default `N ≥ 2`). No node affinity, no pod
  anti-affinity — Orchestrators are not hardware-bound.
- Cardinality is bounded by **Pulsar's `Shared` subscription semantics**, not by replica count.
  All replicas attach to the fan-in topic under the same subscription name in `Shared` mode;
  Pulsar's at-most-one-active-consumer-per-message guarantee prevents work duplication. A
  replica can die at any time; Pulsar redelivers its in-flight messages to survivors.
- Orchestrators are the only daemons permitted to fetch model weights and datasets from the WAN
  (HuggingFace, Civitai, public dataset registries). Workers never touch the WAN; they only ever
  read from MinIO.
- Orchestrators are stateless under the same rules as workers; on replica loss Pulsar replays
  in-flight messages; on full cluster restart Pulsar replays everything; no replica-local
  authoritative state.
- **Upstream users of the overall compute workflow interact with it exclusively through
  Pulsar.** The orchestrator's fan-in topic is the public ingress. The substrate exposes no
  separate HTTP / gRPC / REST surface.
- Project-specific orchestrator logic and Dhall shapes are the consumer's responsibility.
  `daemon-substrate` provides the orchestrator base loop (`runOrchestrator`) and the role-tag
  plumbing; consumer-specific behavior (which upstream topics to consume, how to batch, which
  worker topics to fan out to, what WAN sources to hydrate from) is supplied through the typed
  `BootConfig role app` plug.

All work — inference and training alike — is end-to-end driven by Pulsar protobuf messages.
MinIO is static blob storage; it never carries workflow state.

### L. Substrate-Agnostic Library, Substrate-Aware Test Harness

The library code itself is substrate-agnostic. Consumers (`infernix`, `jitML`, and any later
consumer) configure their own substrate (Apple Silicon / Linux CPU / Linux CUDA, etc.) and hand
the library a typed record at startup.

- The library under `src/Daemon/*` exposes substrate-agnostic typeclasses (`HasPulsar`,
  `HasMinIO`, `HasEngine`) and lifecycle scaffolding. Library modules must not branch on
  substrate.
- Any substrate-specific *consumer* code (Metal FFI, CUDA FFI, Apple host topology) lives in the
  consumer, not in this repository.
- The library may expose engine-shape variants (`SubprocessEngine`, `NativeEngine`) as a
  deliberate sum because the two execution models (subprocess-per-request vs in-process FFI) are
  fundamentally different; the consumer picks the variant that fits its engine.

The repository's own **test harness** is necessarily substrate-aware for cluster-bootstrap
purposes, and this is the only allowed seam where substrate identifiers appear:

- `bootstrap/apple-silicon.sh` and `bootstrap/linux-cpu.sh` are substrate-specific.
- `docker/linux-substrate.Dockerfile` and `compose.yaml` are substrate-specific.
- `src/Daemon/Cluster/*` (kind cluster setup) and the `chart/` directory carry per-substrate
  variation.
- The `daemon-substrate-test` binary's `cluster` subcommands accept substrate selection via the
  staged Dhall configuration.

Even the test harness still exercises the library through the same substrate-agnostic typeclass
surface — the substrate seam ends at the cluster boundary; everything past Pulsar/MinIO is
substrate-blind.

### M. Configuration via Dhall

The library consumes typed configuration. Consumers load Dhall at startup and pass the decoded
record into the library entry points.

- The library defines the shape of `BootConfig role app` (where `role` selects Worker or
  Orchestrator and `app` is a consumer-specific plug); the on-disk layout of the Dhall file is
  the consumer's responsibility.
- No library module may call `lookupEnv`, `getEnv`, `getEnvironment`, `setEnv`, or `unsetEnv`.
- No library module may call `proc "<bare-command-name>"` where the command name resolves through
  `$PATH`. Any external invocation reads the absolute path from a typed config field passed in
  by the consumer.
- Tests pass typed `BootConfig` fixtures rather than constructing one from environment state.
- The doctrine matches the consumer projects' configuration doctrine; this section exists to
  state that the library does not loosen it.

### N. Haskell Quality Gate Contract

Static quality and compiler hygiene are first-class repository requirements.

- The canonical Haskell source formatter is `ormolu`.
- `hlint` runs against the supported Haskell source roots; the configured rule set is committed
  in `.hlint.yaml` when it exists.
- The library builds with strict compiler warnings as errors on supported paths.
- The plan distinguishes mechanically enforced hard-gate inputs from editor-only guidance and
  keeps review guidance separate from hard validation rules.
- The lint and format toolchain bootstrap, the validator implementation, and the CI wiring are
  owned by an explicit sprint. Until that sprint closes, contributors run formatters and
  warnings checks by hand.

### O. Imported Practices and Explicit Non-Adoption

When the plan cites another repository or doctrine, it must distinguish imported governance ideas
from unsupported product features, runtime surfaces, or validation requirements.

- `daemon-substrate` borrows the governance shape (metadata blocks, phase plan structure,
  completion tracking, declarative current-state language) from `infernix` and `jitML`.
- `daemon-substrate` borrows the `HasPulsar` and `HasMinIO` typeclass shapes from `jitML`'s
  capabilities layer.
- `daemon-substrate` does **not** adopt `infernix`'s `infernix service` CLI surface,
  `jitML`'s JIT Metal codegen pipeline, either project's Helm chart, either project's substrate
  matrix, or either project's hardware cohort validation cadence. Those concerns live in the
  consumers.
- Non-adopted external doctrine items must not be treated as current blockers, deliverables, or
  completion criteria unless the repository later implements them and updates the plan, governed
  docs, and validation surface in the same change.

### P. Integration and E2E Coverage Contract

The repository ships its own end-to-end test harness — a self-managed kind cluster, mock
orchestrator and worker daemons, a mock engine — purely to prove the library substrate works.
Consumers are not expected to run it; it exists for `daemon-substrate`'s own validation.

- `daemon-substrate-test integration` exercises: cluster lifecycle (`up` / `status` / `down`),
  orchestrator-to-worker handoff via Pulsar, worker reads of mock weight blobs from MinIO, mock
  engine result publication back through Pulsar, ephemeral local cache lifecycle.
- The mock engine returns placeholder result bytes and performs mock MinIO reads and mock cache
  read/writes. It is representative of the workflow shape but is storage- and compute-light by
  design. The plan must not describe the mock engine as if it were a real ML backend.
- Coverage does **not** include a model matrix, an inference correctness oracle, or any
  hardware-accelerator validation. Those are consumer responsibilities (`infernix` and `jitML`
  validate against their own model matrices).
- `daemon-substrate-test e2e` is reserved for browser- or HTTP-API-driven coverage if and when
  the test harness exposes such a surface; it remains out of scope until an explicit phase opens
  it.
- Supported validation removes any simulated cluster, simulated transport, or generic
  result-success fallback behavior from the harness. Test results name the cohort they exercised
  and do not imply coverage that was not run.

### Q. Hardware Cohort Validation Cadence

Phase work that touches the test harness is planned around two hardware cohorts.

Definitions:

- **Apple cohort:** Apple Silicon host-native workflow through `./bootstrap/apple-silicon.sh`
  or direct `./.build/daemon-substrate-test ...` commands.
- **Linux CPU cohort:** Linux outer-container workflow through `./bootstrap/linux-cpu.sh` or the
  Compose-launched `docker compose run --rm daemon-substrate daemon-substrate-test ...` command
  surface.

There is intentionally no GPU cohort. The mock engine performs no accelerator work, so a CUDA or
Metal cohort would add cost without exercising any library surface the CPU cohort does not
already cover. Consumers (`infernix`, `jitML`) carry their own GPU cohort obligations against
their own model matrices.

Rules:

- Sprint development and first validation should be possible on the machine that owns the changed
  path. A phase must not require alternating between Apple Silicon and Linux CPU after every
  sprint.
- Sprint `Validation` sections distinguish local cohort gates from counterpart cohort closure
  when hardware-specific evidence is required.
- A phase may stay `Active` with an explicit `Apple cohort pending` or `Linux CPU cohort
  pending` residual after one cohort validates, but it cannot move to `Done` until both cohorts
  have run their full-suite gates against the same phase state.
- The paired closure batch is the preferred switching boundary: finish a coherent phase slice on
  one machine, record that evidence, then run the counterpart machine's full validation once for
  the batch.
