# Daemon Roles

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [pulsar_minio_ssot.md](pulsar_minio_ssot.md), [library_consumption_model.md](library_consumption_model.md), [../engineering/cluster_topology.md](../engineering/cluster_topology.md), [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define the two daemon roles `daemon-substrate` supports — **Worker** and
> **Orchestrator** — including their responsibilities, runtime locations, and the invariants each
> role guarantees.

## TL;DR

- A consumer of `daemon-substrate` runs one or more **Worker** daemons (per physical node, on or
  off cluster) and an **Orchestrator** daemon (always off cluster).
- Workers are stateless and own the acceleration hardware on their node. Orchestrators are
  stateless and own request fan-in, batching, fan-out, result fan-back, and WAN→MinIO weight
  hydration.
- Pulsar (workflow) and MinIO (static blobs) are the only authoritative state for both roles.
  Restart-and-replay is the recovery model.
- There are no OS-level concurrency guards in either role. Pulsar subscription semantics enforce
  cardinality at the broker layer.

## Worker

A Worker is a stateless daemon that owns the acceleration hardware on a single physical node.

### Where it runs

- **In-cluster**: as a Kubernetes Deployment with `requiredDuringSchedulingIgnoredDuringExecution`
  pod anti-affinity on `kubernetes.io/hostname`, ensuring at most one Worker pod per node.
- **On-host**: as a long-running process outside any cluster. This is the only supported shape
  on Apple Silicon, where Metal is not visible from inside the Kubernetes Linux VM.

The Haskell code path is identical in both cases. The Dhall config tells the Worker which
Pulsar service URL to connect to and where its ephemeral local cache lives (`emptyDir` on
Kubernetes, `.cache/` under the daemon's working tree on host).

### Responsibilities

- Subscribe to the assigned Pulsar work topics (declared by the consumer's Dhall config).
- Dispatch decoded requests to the engine (provided by the consumer via `HasEngine`).
- Fetch any model weights or blob inputs the engine needs from MinIO, caching locally if
  beneficial.
- Publish engine results back to Pulsar.
- Acknowledge or negatively acknowledge the request based on engine outcome.

### Statelessness

The Worker holds no authoritative state. On crash, restart, or reschedule, it rebuilds its
working set entirely from:

1. its Dhall config (assigned topics, MinIO endpoint, engine selection),
2. unacknowledged messages replayed by Pulsar, and
3. blobs re-fetched on demand from MinIO.

The local cache is non-durable and exclusive — see [Ephemeral cache](#ephemeral-cache).

### Ephemeral cache

A Worker may keep a local on-disk cache to avoid refetching MinIO blobs on every request. The
cache is:

- **Non-durable.** Loss of the cache must not lose data. The authoritative copy is in MinIO.
- **Exclusive to the daemon.** No other process reads or writes it.
- **Aggressively pruned** by the Worker itself — by size, LRU, or any policy that fits its
  workload. Disk pressure is the Worker's problem.

### No OS-level concurrency guards

The Worker uses no `flock(2)`, no PID files, no lockfiles, no other OS-level concurrency
guards. The one-Worker-per-queue invariant is enforced by Pulsar's at-most-once delivery on
shared subscriptions, not by the filesystem. Running two Worker processes on the same node by
accident produces wasted work and contended hardware but never corrupts state.

## Orchestrator

An Orchestrator is a stateless daemon that always runs **in-cluster** as a horizontally
scalable Kubernetes Deployment.

### Where it runs

In the same Kubernetes cluster that hosts the Workers (and Harbor, Pulsar, MinIO). Deployed
as a Kubernetes `Deployment` with `replicas: N` (default `N ≥ 2` for production HA; the test
harness uses 2). No node affinity, no pod anti-affinity — the Orchestrator carries no
hardware-bound resources, so multiple replicas on one node is fine.

Cardinality is bounded by **Pulsar's `Shared` subscription semantics**, not by replica count.
All replicas subscribe to the fan-in topic with the same subscription name in `Shared` mode;
Pulsar distributes messages across the active consumer set. The at-most-one-active-consumer-
per-message guarantee ensures no two replicas ever both process the same request. A replica
can die at any time; Pulsar redelivers its in-flight messages to surviving replicas without
operator intervention.

The Orchestrator is the only component permitted to reach the WAN — egress is opened for
orchestrator pods only; worker pods are firewalled to local in-cluster services.

### Public ingress

**Upstream users of the overall compute workflow interact with it exclusively through
Pulsar.** The Orchestrator's fan-in topic is the public ingress. The substrate exposes no
separate HTTP / gRPC / REST surface for upstream callers; the consumer can layer one on top
if they want, but it is not part of the substrate's contract.

### Responsibilities

1. **Fan in** Pulsar workflow requests from upstream users. The topic set is declared in the
   Orchestrator's own Dhall config.
2. **Batch** requests where the workload benefits from coalescence (large-batch inference,
   gradient accumulation, etc.).
3. **Fan out** the batched work to the Pulsar topics that feed one or more Workers.
4. **Collect results** off the per-worker response topics and **fan back** to the original
   upstream requesters on the response topics they expect.
5. **Hydrate MinIO from the WAN.** Download model weights from upstream registries (HuggingFace,
   Civitai, public dataset registries) into MinIO before any Worker is dispatched against them.
   Workers never touch the WAN; they only ever read from MinIO.

### Statelessness

Same as the Worker, with the multi-replica twist: any replica can be killed at any time, and
Pulsar redelivers its un-acknowledged messages to the surviving replicas. There is no
sticky-leadership concept, no replica-local authoritative state, no inter-replica coordination
required.

### Consumer-supplied logic

Orchestrator behavior is consumer-specific: which upstream topics to subscribe to, how to
batch, which worker topics to fan out to, what WAN sources to hydrate from. `daemon-substrate`
provides the base loop (`runOrchestrator`), the lifecycle scaffolding, and the typed
`BootConfig role app` plug. Consumers (`infernix`, `jitML`) supply their own application
logic and Dhall shape via the `app` type parameter. The substrate does not prescribe a
canonical orchestrator behavior; it prescribes the shape any orchestrator must fit into.

## What is not a daemon role

The substrate has no separate "frontend", "API gateway", "result aggregator", or "control
plane" daemon. Those concerns either live in the consumer (which owns its own user-facing
surfaces) or in the Orchestrator (fan-in / fan-back is the Orchestrator's job).

## Cross-references

- Pulsar/MinIO split: [pulsar_minio_ssot.md](pulsar_minio_ssot.md)
- How consumers wire roles into their daemons: [library_consumption_model.md](library_consumption_model.md)
- How the test harness deploys both roles: [../engineering/cluster_topology.md](../engineering/cluster_topology.md)
- Plan-level role contract: [`../../DEVELOPMENT_PLAN/development_plan_standards.md` § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)
