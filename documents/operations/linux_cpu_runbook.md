# Linux CPU Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [../development/local_dev.md](../development/local_dev.md)

> **Purpose**: Linux CPU outer-container operator workflow for the `daemon-substrate-test`
> harness — prerequisites, image build, compose invocation, in-cluster worker lifecycle, and
> recovery guidance.

## TL;DR

- Linux is always exercised through the outer container. There is no host-native Linux
  workflow.
- The launcher image `daemon-substrate-linux-cpu:local` carries the compiled binary, GHC, the
  staged Dhall, and the kind binary.
- The worker daemon runs *inside* the kind cluster as a two-replica Deployment with
  pod anti-affinity. There is no on-host worker on Linux.
- `./.data/` is the only bind mount; it carries durable cluster state.

## Prerequisites

Minimal pre-existing host state:

- A reasonably current Linux distribution (Ubuntu 24.04 is the reference; other modern
  glibc-based distros work)
- Docker Engine with the Compose plugin
- `docker buildx`
- The invoking user has socket access to `/var/run/docker.sock` (the bootstrap script
  verifies this and reports actionable guidance if not)

The bootstrap script will install Docker Engine and the Compose plugin on Ubuntu via `apt`
when missing. It does not modify your user's group membership; that step is the operator's
responsibility.

## Bring-up

```bash
./bootstrap/linux-cpu.sh up
```

This restartable reconciler:

1. Verifies / installs Docker prerequisites
2. Builds the launcher image `daemon-substrate-linux-cpu:local` via
   `docker/linux-substrate.Dockerfile`
3. Delegates to the binary inside the container:
   `docker compose run --rm daemon-substrate daemon-substrate-test cluster up`
4. Stages Dhall configs at `./.data/runtime/conf/cluster/` (visible inside the container at
   `/workspace/.data/runtime/conf/cluster/`)
5. Brings up the kind cluster including the worker Deployment (two replicas with
   anti-affinity)

The launcher image build takes several minutes on first run. The bootstrap script reports
this and recommends operators not abort early — Docker's layer cache makes subsequent builds
fast.

## In-cluster worker daemon

There is no host worker on Linux. The worker runs as a Kubernetes Deployment:

- Two replicas (the kind cluster has three worker nodes)
- `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on
  `kubernetes.io/hostname`
- Reads `daemon-substrate-worker.dhall` from the mounted `configmap-worker` at
  `/etc/daemon-substrate/worker.dhall`
- Subscribes to `test.batch.linux-cpu` in `Shared` mode (the two pods fan out among
  themselves)

The third worker node intentionally has no Worker pod assigned. A third replica would remain
`Pending` because of the anti-affinity rule; the integration suite asserts this.

### Driving the worker

The operator does not interact with the worker process directly. To inspect:

```bash
docker compose run --rm daemon-substrate kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig get pods -l app=daemon-substrate-test-worker
docker compose run --rm daemon-substrate kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig logs -l app=daemon-substrate-test-worker --tail=100
```

## Teardown

```bash
docker compose run --rm daemon-substrate daemon-substrate-test cluster down
```

Or the bootstrap delegate:

```bash
./bootstrap/linux-cpu.sh down
```

Preserves:

- `./.data/` (durable cluster state)
- `daemon-substrate-linux-cpu:local` (the launcher image)
- installed Docker / OS prerequisites

## Recovery from common failures

### Docker socket access denied

The bootstrap script verifies socket access early and reports:

```
operator '<user>' does not have socket access to /var/run/docker.sock
```

Resolution is operator-specific (add user to `docker` group, log out and back in, etc.). The
bootstrap script does not modify group membership.

### Launcher image build failure

If the build fails partway through, Docker preserves the successful layers. Re-run
`./bootstrap/linux-cpu.sh up` to resume. If a base-image upstream change broke the build,
`docker compose build --no-cache daemon-substrate` forces a clean rebuild.

### Kind cluster unreachable from launcher container

The launcher container joins Docker's private `kind` network on first `cluster status`
invocation. If the launcher container was started before the kind network existed, restart
it: `docker compose down && docker compose run --rm daemon-substrate daemon-substrate-test
cluster status`.

### Worker replicas stuck `Pending`

Either the kind cluster has fewer than two worker nodes (it should have three), or the
anti-affinity rule is firing because both nodes already host a Worker pod. Inspect:

```bash
docker compose run --rm daemon-substrate kubectl --kubeconfig /workspace/.data/runtime/daemon-substrate.kubeconfig describe nodes
```

A third Worker replica is *expected* to remain `Pending`; the harness asserts that explicitly.
Only investigate if fewer than two replicas are `Running`.

## What this runbook does not cover

- GPU workloads — the test harness has no CUDA cohort.
- Real ML model workloads — see `infernix` and `jitML` for those.
- Multi-host Linux deployments — the harness is single-host.

## Cross-references

- General cluster bootstrap: [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md)
- Apple equivalent: [apple_silicon_runbook.md](apple_silicon_runbook.md)
- Local development loop: [../development/local_dev.md](../development/local_dev.md)
