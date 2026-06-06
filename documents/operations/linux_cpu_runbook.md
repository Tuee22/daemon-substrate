# Linux CPU Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Linux CPU operator workflow for the `daemon-substrate-test` harness —
> prerequisites, the in-container build + copy-out model, kind node resource cordoning to the
> per-project budget, in-cluster worker lifecycle, and recovery guidance.

## TL;DR

- On Linux the binary is built **in the project container** (same glibc family as the host) and
  **copied out to `./.build/`** by the Python bootstrapper to run on the host. `./.build/` always
  holds a host-runnable binary.
- `hostbootstrap cluster up` reads the skeletal `hostbootstrap.dhall` (`project`, `dockerfile`,
  `resources`), ensures Docker, builds the thin project image `FROM` the hostbootstrap base, runs
  `check-code`, copies the binary out, and execs the inner `cluster up`.
- The per-project **resource budget** is enforced via **kind node resource cordoning** to the
  declared CPU/memory.
- The worker runs inside kind as a single Deployment replica that owns the node resources for that
  case.
- On a GPU host the CUDA `ensure` reconciler runs and the CUDA-flavored base image is selected;
  the mock engine still performs no CUDA computation.

## Prerequisites

Minimal pre-existing host state:

- Ubuntu 24.04 or a compatible Linux distribution
- passwordless `sudo`
- Docker Engine with socket access for the invoking user

The Python bootstrapper reaches a fail-fast minimum, then reconciles Docker:

```bash
hostbootstrap ensure docker
```

The project container carries `ghc-9.12.4`, Cabal, `kubectl`, `helm`, `kind`, `protoc`, `ormolu`,
`hlint`, and the warm Haskell store via the hostbootstrap base image.

## Bring-up

```bash
hostbootstrap ensure docker
hostbootstrap cluster up
```

On Linux, `cluster up`:

1. Reads the skeletal `hostbootstrap.dhall` and verifies the resource budget.
2. Builds the project image from `docker/Dockerfile` (`FROM ${BASE_IMAGE}`) and runs the
   `check-code` gate.
3. Copies the built `daemon-substrate-test` binary out to `./.build/`.
4. Execs the inner `cluster up`, which generates the project Dhall, creates kind with **node
   resources cordoned to the budget**, deploys Harbor / Pulsar / MinIO, uploads the harness image
   through Harbor, rolls out the coordinator/orchestrator, and rolls out the single in-cluster
   worker.

The first build can take several minutes; the Docker layer cache makes subsequent builds faster.

## Resource cordoning

`hostbootstrap-core` cordons kind node resources to the `resources {cpu, memory}` record in the
skeletal `hostbootstrap.dhall` so in-cluster workloads stay inside the project's slice of the
host. Because the worker owns the resources of its node, the budget is what makes
one-worker-per-case a meaningful test. See
[../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

## In-cluster Worker

Under the Linux CPU `Container` target the worker runs as a Kubernetes Deployment:

- one replica
- `worker.dhall` mounted from `configmap-worker` (rendered from the generated project Dhall)
- subscription to the work topic in `Shared` mode

The operator normally uses status/readiness commands rather than attaching to a container:

```bash
./.build/daemon-substrate-test cluster status
./.build/daemon-substrate-test test integration
```

`test integration` owns the full 3x3 model/workflow matrix and creates isolated `dst-test-*`
clusters for its cases; it is not just a readiness check against this one cluster, and it never
touches a production cluster or `./.data/`. See
[../engineering/test_isolation.md](../engineering/test_isolation.md).

## GPU Host

A GPU-capable Linux host runs `hostbootstrap ensure cuda` and selects the CUDA-flavored
hostbootstrap base image. In this repository the mock engine performs no CUDA work; the GPU path
validates the CUDA `ensure` reconciler, the NVIDIA runtime prerequisite, and the CUDA-flavored
base selection, with the same in-container build + copy-out and kind cordoning as Linux CPU.

## Teardown

```bash
hostbootstrap cluster down
hostbootstrap cluster delete
```

Preserved state:

- `./.data/` durable cluster state
- `./.build/` host-runnable binary
- local Docker layer cache and installed Docker / OS prerequisites

`cluster delete` is the thorough inner teardown path but still preserves `./.data/`.

## Reboot Policy

`hostbootstrap` does not create restart-after-reboot Docker containers. After reboot:

```bash
hostbootstrap cluster up
```

Operators who want boot-time automation can create their own systemd unit outside `hostbootstrap`.

## Recovery From Common Failures

### Docker socket access denied

`ensure docker` verifies socket access early and reports the failing condition. Resolution is
operator-specific, such as fixing Docker group membership and starting a new login session.

### Project image build failure

Re-run `hostbootstrap cluster up`; Docker preserves successful layers.

### Worker replicas stuck `Pending`

The kind topology must have enough capacity within the cordoned budget for the anti-affinity rule.
Check:

```bash
./.build/daemon-substrate-test cluster status
```

If topology is wrong, run `hostbootstrap cluster down` followed by `hostbootstrap cluster up`.

## What This Runbook Does Not Cover

- Real GPU workloads; those are consumer-project obligations.
- Real ML model workloads; see `infernix` and `jitML`.
- Multi-host Linux deployments; the harness is single-host.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Apple equivalent: [apple_silicon_runbook.md](apple_silicon_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
