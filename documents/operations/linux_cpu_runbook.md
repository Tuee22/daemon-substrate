# Linux CPU Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_bootstrap_runbook.md](cluster_bootstrap_runbook.md), [apple_silicon_runbook.md](apple_silicon_runbook.md), [../development/local_dev.md](../development/local_dev.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Linux CPU operator workflow for the `daemon-substrate-test` harness —
> prerequisites, project container build, one-shot cluster handoff, in-cluster worker lifecycle,
> and recovery guidance.

## TL;DR

- Linux CPU selects the `LinuxCpu` entry in `hostbootstrap.dhall`, which uses the `Container`
  model.
- `hostbootstrap cluster up` builds a thin project image `FROM` the hostbootstrap base image and
  runs `docker run --rm <image> cluster up` through the tini-wrapped
  `daemon-substrate-test` entrypoint.
- The container is not a reboot-persistent service and does not remain resident for diagnostics.
  Run `hostbootstrap cluster up` after reboot.
- The worker runs inside kind as a Deployment with pod anti-affinity.
- Linux GPU hosts select the separate `LinuxGpu` entry, which uses `HostBinary`; use
  `--force-target linux-cpu` when intentionally validating the Linux CPU container path on a GPU
  host.

## Prerequisites

Minimal pre-existing host state:

- Ubuntu 24.04 or a compatible Linux distribution
- `pipx` with `hostbootstrap` installed via `pipx`
- Docker Engine with socket access for the invoking user

`hostbootstrap doctor` verifies Docker reachability and reports actionable errors. The project
container carries `ghc-9.12.4`, Cabal, `kubectl`, `helm`, `kind`, `protoc`, `ormolu`, `hlint`,
and the warm Haskell store via the hostbootstrap base image.

## Bring-up

```bash
hostbootstrap doctor
hostbootstrap cluster up
```

For forced validation:

```bash
hostbootstrap cluster up --force-target linux-cpu
```

On Linux CPU, `cluster up`:

1. Builds `daemon-substrate-test:linux-cpu-<arch>` from `docker/Dockerfile`.
2. Runs the image as a one-shot container with `./.data` and `/var/run/docker.sock` mounted.
3. Forwards `cluster up` to the project entrypoint.
4. Lets the inner reconciler create kind, deploy Harbor / Pulsar / MinIO, roll out the
   orchestrator, and roll out the in-cluster worker Deployment.

The first build can take several minutes. Docker layer cache makes subsequent builds faster.

## In-cluster Worker

Under the Linux CPU `Container` target the worker runs as a Kubernetes Deployment:

- two replicas
- required pod anti-affinity on `kubernetes.io/hostname`
- `worker.dhall` mounted from `configmap-worker`
- subscription to `test.batch.linux-cpu` in `Shared` mode

The operator normally uses the harness status/readiness commands rather than attaching to a
resident container:

```bash
hostbootstrap run cluster status
daemon-substrate-test test integration
```

## Linux GPU Target

A GPU-capable Linux host normally selects `LinuxGpu`, not `LinuxCpu`. In this repository the
mock engine performs no CUDA work; the `LinuxGpu` target validates the HostBinary lifecycle and
CUDA-flavored hostbootstrap base selection. To exercise it:

```bash
hostbootstrap cluster up --force-target linux-gpu
hostbootstrap cluster down --force-target linux-gpu
```

## Teardown

```bash
hostbootstrap cluster down
hostbootstrap cluster delete
```

Preserved state:

- `./.data/` durable cluster state
- local Docker layer cache
- installed Docker / OS prerequisites

`cluster delete` is the thorough inner teardown path but still preserves `./.data/`.

## Reboot Policy

`hostbootstrap` does not create restart-after-reboot Docker containers. After reboot:

```bash
hostbootstrap cluster up
```

Operators who want boot-time automation can create their own systemd unit outside
`hostbootstrap`.

## Recovery From Common Failures

### Docker socket access denied

`hostbootstrap doctor` verifies socket access early and reports the failing Docker condition.
Resolution is operator-specific, such as fixing Docker group membership and starting a new login
session.

### Project image build failure

Re-run `hostbootstrap cluster up`; Docker preserves successful layers. If the base image needs
to be rebuilt locally, use `hostbootstrap cluster up --build-base --base-context ~/hostbootstrap`.

### Worker replicas stuck `Pending`

The Linux CPU kind topology must have enough worker nodes for the anti-affinity rule. Run:

```bash
hostbootstrap run cluster status
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
