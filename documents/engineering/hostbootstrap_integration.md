# hostbootstrap Integration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [../../CLAUDE.md](../../CLAUDE.md), [../../AGENTS.md](../../AGENTS.md), [../development/local_dev.md](../development/local_dev.md), [../development/assistant_workflow.md](../development/assistant_workflow.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [cabal_layout.md](cabal_layout.md), [cluster_topology.md](cluster_topology.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md), [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Define how `daemon-substrate` sits on top of [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) —
> the substrate-keyed `hostbootstrap.dhall` shape this repository ships, the cluster handoff
> contract, and the boundary between what `hostbootstrap` owns and what `daemon-substrate-test`
> owns.

## TL;DR

- `hostbootstrap` is a `pipx`-installed Python CLI plus prebuilt base container images. It is
  the canonical build, lifecycle, and bootstrap layer for this repository.
- `daemon-substrate` ships one `hostbootstrap.dhall` with one entry per hardware substrate:
  `AppleSilicon`, `LinuxCpu`, and `LinuxGpu`.
- Each substrate has exactly one execution model: Apple Silicon uses `HostDaemon`; Linux CPU
  and Linux GPU both use `Container`, with Linux GPU selecting the CUDA-flavored base image.
- `hostbootstrap cluster up/down/delete` forwards the same project command every time:
  `daemon-substrate-test cluster up/down/delete`. There are no explicit handoff commands in
  the Dhall file.
- `HostDaemon` adds one foreground daemon command. After `hostbootstrap cluster up`, the caller
  runs `hostbootstrap daemon run` and owns that process. The caller must terminate it before
  `hostbootstrap cluster down` or `hostbootstrap cluster delete`.
- `hostbootstrap` does not install or edit launchd/systemd units, does not create restart-after-reboot
  Docker containers, and does not provide a development mode. After reboot, the operator runs
  `hostbootstrap cluster up` again.
- `--force-target <apple-silicon|linux-cpu|linux-gpu>` lets one physical host exercise any
  declared hostbootstrap target. It does not stand in for the inner 3x3 integration matrix.

## Current Status

The substrate-keyed `hostbootstrap.dhall`, the single tini-wrapped project container
`ENTRYPOINT`, the `daemon-substrate-test check-code` Dockerfile build gate, the plain
`cluster up/down/delete` handoff, and the direct `daemon-substrate-test --model` debugging
override are implemented repo-side. The old per-model spec files are removed. The target
matrix is:

| Substrate entry | Model | Cluster lifecycle |
|-----------------|-------|-------------------|
| `AppleSilicon` | `HostDaemon` | `.build/daemon-substrate-test cluster up`; daemon foreground process via `hostbootstrap daemon run` |
| `LinuxCpu` | `Container` | `docker run --rm <image> cluster up` |
| `LinuxGpu` | `Container` | `docker run --rm <image> cluster up` with the CUDA-flavored base image |

`cluster down` and `cluster delete` use the same target selection. For `HostDaemon`,
`hostbootstrap` does not stop a daemon process; the operator, service manager, or test harness
that invoked `hostbootstrap daemon run` owns termination.

## Why hostbootstrap

[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) standardizes substrate detection,
host prerequisite checks, the multi-language base toolchain (`ghc-9.12.4`, Cabal, kube tools,
`protoc`, `ormolu`, `hlint`, warm Haskell store), and the Container / HostBinary / HostDaemon
execution models. Adopting it keeps this repository to one typed Dhall config and one thin
project Dockerfile. The same tool is consumed by [`infernix`](https://github.com/Tuee22/infernix)
and [`jitML`](https://github.com/Tuee22/jitML), so the three-project family shares one
infrastructure substrate.

The canonical `hostbootstrap` documentation is the source of truth for its own schema,
commands, and base image inventory:

- [`~/hostbootstrap/README.md`](https://github.com/Tuee22/hostbootstrap/blob/main/README.md)
- [`~/hostbootstrap/documents/engineering/schema.md`](https://github.com/Tuee22/hostbootstrap/blob/main/documents/engineering/schema.md)
- [`~/hostbootstrap/hostbootstrap/dhall/package.dhall`](https://github.com/Tuee22/hostbootstrap/blob/main/hostbootstrap/dhall/package.dhall)

This document only covers how `daemon-substrate` uses those types.

## Ownership Boundary

`hostbootstrap` owns substrate detection, host prerequisite checks, base-image selection,
project artifact builds (`docker build` or templated `cabal install exe:<project>`), one-shot
container runs, host-binary invocation, foreground `HostDaemon` invocation through
`hostbootstrap daemon run`, and forwarding `cluster up/down/delete`.

`daemon-substrate` owns the Haskell library surface (`HasPulsar`, `HasMinIO`, `HasEngine`,
`runWorker`, `runOrchestrator`, `BootConfig role app`), protobuf schemas, the
`daemon-substrate-test` binary, and the in-cluster reconcilers: kind create, Helm install of
Harbor / Pulsar / MinIO, ConfigMap render, Deployment apply, MinIO bucket seeding, and edge-port
discovery.

The seam is intentionally narrow:

| Outer model | Forwarded command | Additional hostbootstrap behavior |
|-------------|-------------------|-----------------------------------|
| `Container` | container entrypoint receives `cluster up/down/delete` | build image, run one-shot `docker run --rm` with declared mounts |
| `HostBinary` | `.build/daemon-substrate-test cluster up/down/delete` | build native binary; no daemon process |
| `HostDaemon` | `.build/daemon-substrate-test cluster up/down/delete` | build native binary; daemon runs only as foreground `hostbootstrap daemon run` |

The substrate-agnostic library rule in
[../architecture/library_consumption_model.md](../architecture/library_consumption_model.md)
is unchanged: consumer-facing `Daemon.*` modules do not branch on host hardware. The harness
CLI chooses worker placement for validation only.

## Canonical `hostbootstrap.dhall`

The repository root has exactly one project config:

```dhall
let projectContainer =
      { dockerfile = "docker/Dockerfile" }

let linuxContainer =
      H.Model.Container
        H.Container::{
        , dockerfile = "docker/Dockerfile"
        , mounts =
          [ H.Mount::{ host = "./.data", container = "/workspace/.data" }
          , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
          ]
        }

let hostDaemon =
      H.Model.HostDaemon
        H.HostDaemon::{
        , daemon = "service --role worker --config dhall/worker.dhall"
        , container = Some projectContainer
        }

in  H.config
      { project = "daemon-substrate-test"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.cluster hostDaemon)
        , H.entry H.Substrate.LinuxCpu (H.cluster linuxContainer)
        , H.entry H.Substrate.LinuxGpu (H.cluster linuxContainer)
        ]
      }
```

`project` matches the command name. Containers expose that command as the tini-wrapped
entrypoint, and host-native models build `exe:daemon-substrate-test` into
`.build/daemon-substrate-test`.

## Target Selection

Normal operation uses the detected host substrate:

| Detected host | Selected entry | Harness model |
|---------------|----------------|---------------|
| macOS arm64 Apple Silicon | `AppleSilicon` | `HostDaemon` |
| Linux without NVIDIA runtime | `LinuxCpu` | `Container` |
| Linux with NVIDIA runtime | `LinuxGpu` | `Container` |

For validation, every lifecycle command that builds or invokes a target accepts
`--force-target`. This lets one physical host run the three declared hostbootstrap targets:

```bash
hostbootstrap cluster up --force-target apple-silicon
hostbootstrap cluster down --force-target apple-silicon
hostbootstrap cluster up --force-target linux-cpu
hostbootstrap cluster down --force-target linux-cpu
hostbootstrap cluster up --force-target linux-gpu
hostbootstrap cluster down --force-target linux-gpu
```

The mock engine remains CPU-only; `LinuxGpu` exists to validate the Linux GPU hostbootstrap
target, NVIDIA runtime prerequisite, CUDA-flavored base-image path, and container lifecycle,
not to exercise CUDA computation in this repository.

## Base Image And Toolchain

`hostbootstrap` selects the base tag from the target substrate. `AppleSilicon` and `LinuxCpu`
use CPU-flavored base images for container artifacts; `LinuxGpu` uses the CUDA-flavored base
for the one-shot project container. The base ships
`ghc-9.12.4`, Cabal, kube tools (`kubectl`, `helm`, `kind`), `protoc`, `ormolu`, `hlint`, and
a warm Haskell store.

The GHC pin for this repository is exactly **`ghc-9.12.4`**, matching the base. The warm-store
`cabal.project.freeze` import applies to **container builds only**; host-native builds do not
use the warm store. See [cabal_layout.md](cabal_layout.md).

## Project Dockerfile

`docker/Dockerfile` is intentionally thin:

```dockerfile
# check=skip=InvalidDefaultArgInFrom
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
COPY . .
RUN cabal install --project-file=cabal.project.container --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test
RUN daemon-substrate-test check-code

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/daemon-substrate-test"]
```

The Dockerfile carries no default `CMD`. `hostbootstrap` forwards the command arguments for
`run` and `cluster` invocations. It also does not declare restart policy; containers are
one-shot `docker run --rm` invocations.

## Operator Entrypoints

`hostbootstrap` is installed via `pipx` only:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

Per clone:

```bash
hostbootstrap doctor
hostbootstrap cluster up
hostbootstrap daemon run
hostbootstrap cluster down
hostbootstrap cluster delete
```

`hostbootstrap cluster up` builds the selected target if needed and forwards
`daemon-substrate-test cluster up`. `hostbootstrap cluster down` forwards
`daemon-substrate-test cluster down`. `hostbootstrap cluster delete` forwards
`daemon-substrate-test cluster delete`. `.data/` is preserved by all outer lifecycle commands.
For the AppleSilicon `HostDaemon` target, run `hostbootstrap daemon run` in a separate terminal,
test harness process, launchd unit, or systemd unit after cluster bring-up. Stop that foreground
process before cluster teardown.

This repository intentionally does not rely on reboot persistence from hostbootstrap. After a
reboot, run `hostbootstrap cluster up` again and restart any foreground `hostbootstrap daemon run`
process. Operators who want automatic boot-time startup can create their own launchd/systemd unit
outside this repository and outside hostbootstrap.

## What This Repository Does Not Ship

- per-host bootstrap shell scripts
- Compose files
- multi-language project Dockerfile layers
- per-model `hostbootstrap-*.dhall` files
- explicit handoff commands in Dhall
- launchd/systemd unit files or code that edits them
- restart-after-reboot Docker containers
- hostbootstrap development mode

See [`legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
for obsolete surfaces that were removed during earlier phases.

## Cross-references

- Operator runbooks: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md),
  [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md),
  [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
- First-run developer flow: [../development/local_dev.md](../development/local_dev.md)
- Cluster topology: [cluster_topology.md](cluster_topology.md)
- Cabal layout: [cabal_layout.md](cabal_layout.md)
- Bootstrap config phase: [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md)
- Integration matrix phase: [../../DEVELOPMENT_PLAN/phase-8-test-harness-integration.md](../../DEVELOPMENT_PLAN/phase-8-test-harness-integration.md)
