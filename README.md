# daemon-substrate

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [documents/README.md](documents/README.md), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md), [documents/engineering/hostbootstrap_integration.md](documents/engineering/hostbootstrap_integration.md)

> **Purpose**: Orient new readers and consumers (`infernix`, `jitML`) to the shape, scope, and
> intent of the shared substrate library, and point at the canonical homes for documentation and
> development planning.

A shared Haskell library for stateless ML daemons that run hardware-accelerated workloads on multi-node Kubernetes clusters.

`daemon-substrate` is the common substrate shared by [`infernix`](https://github.com/Tuee22/infernix) (LLM and multimodal inference) and [`jitML`](https://github.com/Tuee22/jitML) (supervised and reinforcement-learning training). Both projects need to solve the same set of distributed-systems problems before they can do anything useful with a GPU; this library is where those problems get solved once.

## The problem

Running a distributed ML workload — inference or training — on a multi-node Kubernetes cluster that has heterogeneous acceleration hardware (NVIDIA GPUs on Linux nodes, Apple Metal on macOS hosts) raises a set of recurring infrastructure problems that are independent of what the workload actually does. `daemon-substrate` exists because both `infernix` and `jitML` need exactly the same answers to these problems.

### a. Distributed state via Pulsar and MinIO

The substrate leans hard on two first-class distributed services managed by Kubernetes:

- **Apache Pulsar** is the source of truth for *work in motion*. That means inference requests, training commands, and the sequence-model state that some workloads carry between steps — LLM conversation context, the move history of an AlphaZero-family adversarial game, the trajectory of an RL episode. Pulsar topics are protobuf-encoded and durable; everything that matters is recoverable by replaying them.
- **MinIO** is the source of truth for *large static binary blobs* — model weights, datasets, images, audio, video, training checkpoints. These are content-addressed and immutable once written.

The two services are complementary: Pulsar payloads stay small and message-shaped, and they reference MinIO objects by URL when a workload needs a large blob. `jitML` already has an extensive MinIO specification for training checkpoints; `daemon-substrate` lifts that shape so `infernix` can adopt it for model weights and large inference outputs.

### b. One stateless worker daemon per physical node

Every physical node in the cluster runs at most one *worker daemon*. The worker owns all of the acceleration hardware on its node — every CUDA GPU on a Linux node, the Apple Metal device on a macOS host. The worker is responsible for getting the most out of that hardware from a single process; running two workers on the same node duplicates weights in memory and contends for the accelerator without adding throughput.

The worker is **stateless**. It is configured by a single Dhall file that names the Pulsar topics it subscribes to and publishes to, the MinIO endpoint it reads from, and the engines it is allowed to dispatch to. On crash, restart, or reschedule, it recovers everything it needs by replaying Pulsar and re-reading from MinIO. There is no node-local authoritative state.

### c. Two deployment shapes, one daemon

A worker may run either as a Kubernetes Deployment (with `requiredDuringScheduling` pod anti-affinity on `kubernetes.io/hostname` to enforce the one-per-node invariant) or as a host-level daemon outside the cluster (the supported shape on Apple Silicon, where Metal is not visible from inside the Kubernetes Linux VM). The daemon code is identical in both cases. The Dhall config tells it which transport endpoints to use and where its ephemeral cache lives.

### d. Ephemeral local cache — non-durable, exclusive, aggressively pruned

A worker may keep a local on-disk cache so it does not have to refetch every blob from MinIO on every request. On Kubernetes this is an `emptyDir` volume; on a host daemon it is a `.cache/` directory under the daemon's working tree. The cache is:

- **Non-durable.** Loss of the cache must not lose data. The authoritative copy is always in MinIO.
- **Exclusive to the daemon.** Only the single worker on that node ever touches it. No other process reads or writes.
- **Aggressively pruned.** The worker is responsible for keeping the cache bounded — by size, by LRU, by whatever policy fits its workload. Disk pressure is the worker's problem.

There are **no locks, no `flock(2)` guards, no PID files, no OS-level concurrency controls** of any kind. Pulsar's at-most-once delivery semantics on a shared subscription ensure that multiple workers reading the same workqueue cannot double-process a request. Each worker populates and prunes its own cache from MinIO based on the workflow Pulsar hands it. The set of topics a worker subscribes to is driven by its Dhall config.

### e. In-cluster orchestrator daemon

Separate from the worker — which may run on-cluster or off — there is an **orchestrator daemon** that always runs **in-cluster, as a horizontally scalable Kubernetes Deployment**. It is stateless and needs no hardware acceleration. Cardinality is bounded by Pulsar's `Shared` subscription semantics, not by replica count: multiple replicas consume the fan-in queue in parallel, and Pulsar's at-most-once-per-active-consumer guarantee ensures no two replicas ever both process the same message. A replica can die at any time; Pulsar redelivers its in-flight messages to surviving replicas. Replicas are typically `replicas: 2` for production HA.

It is responsible for:

1. **Fanning in** Pulsar workflow requests from upstream users (which topics it listens on is in its own Dhall config). **Upstream users interact with the overall compute workflow exclusively through Pulsar** — the orchestrator's fan-in topic is the public ingress. The substrate exposes no separate HTTP / gRPC / REST surface.
2. **Batching** inference and training requests when the workload benefits from it.
3. **Fanning out** the batched work to the Pulsar topics that feed one or more workers.
4. **Collecting results** off the per-worker response topics and **fanning back** to the original upstream requesters.
5. **Hydrating MinIO from the WAN** — downloading model weights from upstream registries (HuggingFace, Civitai, etc.) into MinIO before any worker is dispatched against them. The orchestrator is the only component permitted to reach the WAN; workers never touch external networks.

Orchestrator logic and Dhall configuration shape are project-specific — `infernix` and `jitML` may carry different orchestrator behavior. `daemon-substrate` provides the base loop, the role plumbing, and the typed `BootConfig role app` plug; the consumer supplies the application-specific behavior.

All work — inference and training alike — is end-to-end driven by Pulsar protobuf messages. MinIO is purely a static blob store; it never carries workflow state.

### f. Crash recovery via Pulsar replay

Any number of worker or orchestrator crashes recover by replaying the relevant Pulsar topics. Because Pulsar is the only authoritative store for in-motion state and MinIO is the only authoritative store for static blobs, and because workers hold no authoritative local state, restart-and-replay is sufficient for full recovery — at every layer, on every substrate.

### g. Dhall configures slowly changing data

Each daemon takes a single Dhall configuration file at startup that declares:

- Which Pulsar topics it subscribes to and publishes to.
- Which engines it is allowed to dispatch to, and which engine handles which class of work.
- Connection details for Pulsar and MinIO.

Both `infernix` and `jitML` already have established Dhall specifications for engine and routing configuration; `daemon-substrate` provides the shared types they both decode against.

## Consuming `daemon-substrate`

`daemon-substrate` is consumed as a **Haskell library** — not as a binary, not as a Docker image, not as a published artifact. Consumers depend on it by cloning the repository alongside their own and pointing `cabal.project` at the sibling path:

```cabal
packages:
  .
  ../daemon-substrate

with-compiler: ghc-9.12.4
```

The library exposes a small surface that consumers wire into their own daemon entry points:

- `HasPulsar`, `HasMinIO`, `HasEngine` typeclasses for the substrate seams (`HasEngine` is batch-native: `NonEmpty req -> m (NonEmpty (Either EngineError EngineResponse))`)
- `runWorker` and `runOrchestrator` as the two role-specific base loops
- `BootConfig role app` as the typed Dhall-decoded configuration shape consumers parameterize with their own application data; `LiveConfig` carries the SIGHUP-reloadable `BatchingPolicy` + `SchedulerPolicy`
- Three layered Pulsar abstractions consumers compose instead of writing raw Pulsar client code:
  - **Envelope layer** — substrate-owned protobuf envelopes (`WorkflowEvent` with `deadline_at`, `WorkflowKind`, and a `payload` oneof; `ControlEnvelope`; `AuditEvent`; etc.), wrapped by hand-written `Daemon.Wire.*` ADTs for idiomatic application code. Consumer payloads carried inside are opaque to the substrate; dispatch is by `payload_type` URL prefix. See [`documents/reference/proto_surface.md`](documents/reference/proto_surface.md).
  - **Topology layer** — typed builders for `RequestResponse` / `FanOut` / `BatchedFanOut` / `FanIn` / `BatchedFanIn` / `Pipeline` / `Stream`. See [`documents/engineering/orchestration_topologies.md`](documents/engineering/orchestration_topologies.md).
  - **Batching layer** — the in-cluster orchestrator's substrate-owned batcher and multi-bucket scheduler (hard-deadline preemption + weighted fair queueing + optional bucket-affinity dwell), with a small `BatchingHooks` consumer extension for payload-aware combinability and bucketing. See [`documents/engineering/batching.md`](documents/engineering/batching.md).
- `Daemon.MinIO.Store` for content-addressed blobs and `Daemon.MinIO.Cache` (with a `pin` / `unpin` / `isPinned` API) for hot-set protection
- shared lifecycle, signal-handling, and readiness scaffolding

`infernix` and `jitML` provide their own engines, their own substrates (Apple Metal, CUDA, etc.), and their own model weights; `daemon-substrate` provides everything that sits between Pulsar/MinIO and the engine boundary. The two consumers are sealed loops over shared substrate primitives — they share infrastructure but not domain artifacts; the substrate does not mediate consumer-to-consumer protocol.

## Test harness

The production architecture described in sections (a–g) above is how *consumers* (`infernix`, `jitML`, future ones) deploy the substrate. The repository's own test harness exists to validate the substrate library shape and uses a **mock engine** that performs no real ML, no GPU work, and no Metal or CUDA calls — even on Apple Silicon. The harness exercises Pulsar / MinIO / lifecycle / cache plumbing, not hardware acceleration.

The repository ships a self-managed end-to-end test harness purely to prove that the library substrate works. The harness builds a separate `daemon-substrate-test` binary and brings up a real kind cluster with real Harbor, real Pulsar, and real MinIO — exactly mirroring how `infernix` and `jitML` validate their own integration. The harness uses a **mock worker engine** that returns placeholder result bytes, mocks reads from MinIO (mock weight blobs, mock binary artifacts), and mocks the local cache: representative of the workflow shape but storage- and compute-light by design.

Upstream callers of the workflow (the test driver, in the harness; real users, in production) **interact with the orchestrator exclusively through Pulsar** by publishing to the fan-in topic. The substrate exposes no separate HTTP / gRPC / REST surface for upstream callers.

The harness runs the same `H.Accel.Cpu` target on every host. The execution model is chosen by spec file, not by host:

- **Container** (`hostbootstrap.dhall`, default) — `hostbootstrap cluster up` builds a thin project container `FROM` the `hostbootstrap` base image and runs `daemon-substrate-test cluster up` inside it.
- **HostBinary** (`hostbootstrap-hostbinary.dhall`) — `hostbootstrap` builds `./.build/daemon-substrate-test` natively and invokes it per command on the host.
- **HostDaemon** (`hostbootstrap-hostdaemon.dhall`) — `hostbootstrap` runs `daemon-substrate-test service --role worker` as a managed long-lived service (launchd on Apple, systemd on Linux).

Consumers do **not** run the harness — it exists for `daemon-substrate`'s own validation only. The cluster bootstrap flow, the operator-facing commands, and the coverage obligations are documented in [`documents/development/testing_strategy.md`](documents/development/testing_strategy.md) and [`documents/operations/cluster_bootstrap_runbook.md`](documents/operations/cluster_bootstrap_runbook.md).

### One CPU target on every host; three execution models

`daemon-substrate` is **CPU-only** — the mock engine performs no GPU, Metal, or CUDA work — so the harness declares exactly one acceleration target: `H.Accel.Cpu`. `hostbootstrap` detects the host and matches it to the target by capability subsumption: an `apple-silicon` host satisfies `{Cpu, Metal}`, a `linux-cpu` host satisfies `{Cpu}`, and a `linux-gpu` host satisfies `{Cpu, Cuda}`. A single `Cpu` target therefore runs on **every** host — Apple, linux-cpu, and linux-gpu, on both amd64 and arm64 — with no host-keyed cohort split.

The substrate exercises the same library across the three `hostbootstrap` execution **models**:

- **Container** — the harness binary runs inside a thin project container `FROM` the `hostbootstrap` base image.
- **HostBinary** — the harness binary runs natively on the host, invoked per command.
- **HostDaemon** — the harness binary runs as a managed long-lived service (launchd on Apple, systemd on Linux) from one declaration.

Because one spec carries one model, the three models are driven by separate spec files selected with `hostbootstrap … --spec <file>`: `hostbootstrap.dhall` (Container, the default), `hostbootstrap-hostbinary.dhall` (HostBinary), and `hostbootstrap-hostdaemon.dhall` (HostDaemon). A `Cpu` HostDaemon now runs on Apple (launchd) and Linux (systemd) from one declaration.

### Reference scaffolding: the 3×3 model × workflow matrix

`daemon-substrate` is the reference scaffolding for `infernix` and `jitML`. The harness target is a full **3×3 matrix**: each of the three execution models (Container, HostBinary, HostDaemon) exercising each of three ML workflow archetypes —

- **(a) continuous batched inference** (≈ `infernix`),
- **(b) finite supervised-learning / offline-RL training jobs** (≈ `jitML`),
- **(c) continuous online RL** — MinIO weight updates announced on Pulsar inference topics, with distinct training-vs-inference task messages routable to same-or-separate stateless engines.

## Foundation

`daemon-substrate`'s build, lifecycle, and bootstrap layer is provided by
[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) — a host-installed Python CLI plus
prebuilt base container images that standardize host detection, host-prereq install,
multi-language toolchain (`ghc-9.12.4`, Cabal, kube tools, `protoc`, `ormolu`, `hlint`, warm Haskell
store), and the Container / HostBinary / HostDaemon execution models. `daemon-substrate` declares its own
behavior as a single `H.Accel.Cpu` target in a typed `hostbootstrap.dhall` at the repository
root; the operator entrypoint is `hostbootstrap cluster up`. The boundary between what
`hostbootstrap` owns and what `daemon-substrate-test` owns is described in
[`documents/engineering/hostbootstrap_integration.md`](documents/engineering/hostbootstrap_integration.md).

`hostbootstrap` is installed via `pipx` only:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

`infernix` and `jitML` are also `hostbootstrap` consumers, so the three-project family shares
one infrastructure substrate.

## Current Status

[`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md) is the authoritative current-state status for this repository. The phase plan, sprint status, and per-phase remaining work all live there. This README describes the intended library shape and contract; the plan describes how much of it actually exists today.

The single-`Cpu`-target `hostbootstrap.dhall`, the three per-model spec files, the tini-wrapped container `ENTRYPOINT` with the `daemon-substrate-test check-code` build gate, and the 3×3 model × workflow matrix are implemented repo-side and tracked as closed work in `DEVELOPMENT_PLAN/`.

## License

MIT. See [LICENSE](LICENSE).
