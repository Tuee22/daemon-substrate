# Linux CPU Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Linux CPU outer-container operator workflow for the `daemon-substrate-test`
> harness — prerequisites, image build, container invocation, in-cluster worker lifecycle, and
> recovery guidance.

## TL;DR

- Linux is always exercised through the outer container. There is no host-native Linux
  workflow.
- The substrate is brought up by `hostbootstrap cluster up`, which builds a thin project
  container `FROM` the `hostbootstrap` base tag (per the `Container` model declared in
  `hostbootstrap.dhall`) and runs it long-running with `service = True`.
- If hostbootstrap detects a GPU-capable Linux host as `linux-gpu`, this repository still
  selects the CPU-flavored harness container. That compatibility entry does not create a GPU
  test cohort.
- The container carries the compiled `daemon-substrate-test` binary, GHC (from the base), the
  staged Dhall, and the `kind` binary.
- The worker daemon runs *inside* the kind cluster as a two-replica Deployment with pod
  anti-affinity. There is no on-host worker on Linux.
- `./.data/` is the only durable bind mount; the Docker socket is mounted so the container can
  drive its own `kind` cluster.

## Prerequisites

Minimal pre-existing host state:

- A reasonably current Linux distribution (Ubuntu 24.04 is the reference; other modern
  glibc-based distros work)
- Python 3.12 with `hostbootstrap` installed (see
  [../development/local_dev.md](../development/local_dev.md))
- Docker Engine with the Compose plugin
- `docker buildx`
- The invoking user has socket access to `/var/run/docker.sock` (`hostbootstrap doctor`
  verifies this and reports actionable guidance if not)

`hostbootstrap doctor` will install Docker Engine and the Compose plugin on Ubuntu via `apt`
when missing. It does not modify your user's group membership; that step is the operator's
responsibility.

GHC, Cabal, `kubectl`, `helm`, `kind`, and `protoc` are baked into the `hostbootstrap` base
image; no host-level Haskell toolchain is required.

## Bring-up

```bash
hostbootstrap doctor          # one-time: install Docker prereqs
hostbootstrap cluster up      # build container, start service, bring cluster up
```

`hostbootstrap cluster up` is a restartable reconciler. On Linux CPU it:

1. Verifies / installs Docker prerequisites via `hostbootstrap doctor`
2. Builds the thin project container via `docker/linux-substrate.Dockerfile`, which `FROM`s
   the `hostbootstrap` base tag and bakes in `daemon-substrate-test`
3. Runs the container long-running (`service = True`, `--restart unless-stopped`) with the
   declared mounts: `./.data` for durable state, `/var/run/docker.sock` so the container can
   drive `kind`
4. The container starts `daemon-substrate-test cluster up`, attaches itself to Docker's
   `kind` network, exports kind's internal kubeconfig, reconciles the kind cluster (Harbor,
   Pulsar, MinIO, orchestrator, worker Deployment), and then stays resident for diagnostics

The base image is pulled by default. Pass `hostbootstrap cluster up --build-base` to build the
base locally from source.

The first container build takes several minutes (project build only; the heavy toolchain is in
the pulled base). Docker's layer cache makes subsequent builds fast.

## In-cluster worker daemon

There is no host worker on Linux. The worker runs as a Kubernetes Deployment:

- Two replicas (the kind cluster has three worker nodes)
- `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on
  `kubernetes.io/hostname`
- Reads `worker.dhall` from the mounted `configmap-worker` at
  `/etc/daemon-substrate/worker.dhall`
- Subscribes to `test.batch.linux-cpu` in `Shared` mode (the two pods fan out among
  themselves)

The third worker node intentionally has no Worker pod assigned. A third replica would remain
`Pending` because of the anti-affinity rule; the integration suite asserts this.

### Driving the worker

The operator does not interact with the worker process directly. To inspect:

```bash
hostbootstrap run kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig \
    get pods -l app=daemon-substrate-test-worker
hostbootstrap run kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig \
    logs -l app=daemon-substrate-test-worker --tail=100
```

## Teardown

```bash
hostbootstrap cluster down     # tear down; preserves ./.data/
hostbootstrap cluster delete   # thorough teardown; still preserves ./.data/
```

Preserves:

- `./.data/` (durable cluster state) — `hostbootstrap` never deletes this
- the project container image (`cluster delete` may rebuild it on next `up`)
- installed Docker / OS prerequisites

## Recovery from common failures

### Docker socket access denied

`hostbootstrap doctor` verifies socket access early and reports:

```
operator '<user>' does not have socket access to /var/run/docker.sock
```

Resolution is operator-specific (add user to `docker` group, log out and back in, etc.).
`hostbootstrap doctor` does not modify group membership.

### Project image build failure

If the build fails partway through, Docker preserves the successful layers. Re-run
`hostbootstrap cluster up` to resume. If a base-image upstream change broke the build,
`hostbootstrap cluster up --build-base` forces a base rebuild before the project build.

### Kind cluster unreachable from project container

The container joins Docker's private `kind` network during `cluster up` and `cluster status`
before using the repo-local kubeconfig. If Docker reports the container is not attached to
that network, rerun `daemon-substrate-test cluster up` from inside the service container or
restart the outer service with `hostbootstrap cluster down && hostbootstrap cluster up`.

### Worker replicas stuck `Pending`

Either the kind cluster has fewer than two worker nodes (it should have three), or the
anti-affinity rule is firing because both nodes already host a Worker pod. Inspect:

```bash
hostbootstrap run kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig \
    describe nodes
```

A third Worker replica is *expected* to remain `Pending`; the harness asserts that explicitly.
Only investigate if fewer than two replicas are `Running`.

## What this runbook does not cover

- GPU workloads — the test harness has no CUDA cohort.
- Real ML model workloads — see `infernix` and `jitML` for those.
- Multi-host Linux deployments — the harness is single-host.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Apple equivalent: [apple_silicon_runbook.md](apple_silicon_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
