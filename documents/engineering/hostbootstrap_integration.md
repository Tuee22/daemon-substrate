# hostbootstrap Integration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [../../CLAUDE.md](../../CLAUDE.md), [../../AGENTS.md](../../AGENTS.md), [../development/local_dev.md](../development/local_dev.md), [../development/assistant_workflow.md](../development/assistant_workflow.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [cabal_layout.md](cabal_layout.md), [cluster_topology.md](cluster_topology.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md), [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Define how `daemon-substrate` sits on top of [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) —
> the model-per-substrate mapping, the canonical `hostbootstrap.dhall` shape this repository
> ships, and the boundary between what `hostbootstrap` owns and what `daemon-substrate-test`
> owns.

## TL;DR

- `hostbootstrap` is a host-installed Python CLI plus four prebuilt base container images. It
  is the canonical infrastructure layer for this repository.
- `daemon-substrate` declares its substrate behavior in a typed `hostbootstrap.dhall` at the
  repository root.
- Apple Silicon → `HostDaemon` model (host-native worker wrapped in a system-scope
  LaunchDaemon).
- Linux CPU → `Container` model (`service = True`, with `.data` and Docker-socket bind
  mounts).
- `hostbootstrap cluster up` is the operator entrypoint on both cohorts. The Container or
  HostDaemon process it launches is `daemon-substrate-test`, which then owns in-cluster
  reconciliation.

## Why hostbootstrap

[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) standardizes substrate detection,
host-prereq install, the multi-language base toolchain (GHC 9.12, Cabal, kube tools, protoc,
fourmolu, hlint, warm Haskell store), and container / daemon lifecycle at the OS level — the
exact surface `daemon-substrate-test` would otherwise hand-roll. Adopting it collapses what
would have been substrate-specific bootstrap scripts and a custom Dockerfile family into one
declarative Dhall file plus a thin project Dockerfile. The same tool is consumed by
[`infernix`](https://github.com/Tuee22/infernix) and [`jitML`](https://github.com/Tuee22/jitML),
so the three-project family shares one infrastructure substrate.

The canonical `hostbootstrap` documentation is the source of truth for its own types,
commands, and base image inventory:

- [`~/hostbootstrap/README.md`](https://github.com/Tuee22/hostbootstrap/blob/main/README.md)
- [`~/hostbootstrap/documents/engineering/schema.md`](https://github.com/Tuee22/hostbootstrap/blob/main/documents/engineering/schema.md)
- [`~/hostbootstrap/hostbootstrap/dhall/package.dhall`](https://github.com/Tuee22/hostbootstrap/blob/main/hostbootstrap/dhall/package.dhall)

This document only covers how `daemon-substrate` uses those types.

## Ownership boundary

> `hostbootstrap` owns: substrate detection, host prereqs, the base image (toolchain), build
> orchestration (`docker build`, `cabal install`), container / daemon lifecycle at the OS
> level (Container run, HostDaemon LaunchDaemon / systemd unit), and `.data` preservation
> across `cluster down` / `cluster delete`.
>
> `daemon-substrate` owns: the Haskell library surface (`HasPulsar`, `HasMinIO`, `HasEngine`,
> `runWorker`, `runOrchestrator`, `BootConfig role app`), protobuf schemas, the
> `daemon-substrate-test` binary, and the **in-cluster reconcilers** (kind create, Helm
> install of Harbor / Pulsar / MinIO, ConfigMap render, Deployment apply, MinIO bucket
> seeding, edge-port discovery).
>
> The seam: `hostbootstrap`'s `Container` model runs `daemon-substrate-test cluster up`;
> `hostbootstrap`'s `HostDaemon` model runs `daemon-substrate-test service --role worker
> --config dhall/worker.dhall`. Everything above the seam stays in Haskell.

The seam is the only place substrate identifiers cross from `hostbootstrap` into
`daemon-substrate`. The substrate-agnostic library rule in
[../architecture/library_consumption_model.md](../architecture/library_consumption_model.md) is
unchanged: `src/Daemon/*` never branches on substrate.

## Cohort to model mapping

| Cohort | hostbootstrap substrate | hostbootstrap model | What it launches |
|--------|--------------------------|---------------------|------------------|
| Apple Silicon | `H.Substrate.AppleSilicon` | `H.Model.HostDaemon` | `./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall` as a system-scope LaunchDaemon |
| Linux CPU | `H.Substrate.LinuxCpu` | `H.Model.Container` (`service = True`) | `daemon-substrate-test cluster up` inside the project container, which then reconciles the in-cluster kind topology |

There is intentionally no Linux GPU cohort in the harness. Consumers (`infernix`, `jitML`)
carry their own GPU cohort obligations against their own model matrices.

## Canonical `hostbootstrap.dhall`

The repository ships one `hostbootstrap.dhall` at the root. The CLI bundles and injects the
typed schema as `H`; the file has no import line.

```dhall
H.config
  { project = "daemon-substrate"
  , substrates =
    [ H.entry H.Substrate.LinuxCpu
        ( H.Model.Container
            H.Container::{
            , dockerfile = "docker/linux-substrate.Dockerfile"
            , service = True
            , mounts =
              [ H.Mount::{ host = "./.data", container = "/workspace/.data" }
              , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
              ]
            }
        )
    , H.entry H.Substrate.AppleSilicon
        ( H.Model.HostDaemon
            H.HostDaemon::{
            , build =
                H.Build::{
                , cabal = "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:daemon-substrate-test"
                , host = H.HostReqs::{ ghc = True }
                }
            , daemon = ".build/daemon-substrate-test service --role worker --config dhall/worker.dhall"
            }
        )
    ]
  }
```

This document is the canonical home for the shape; the file itself lands in
[`phase-7-hostbootstrap-and-project-dockerfile.md`](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md).

## Base image and toolchain

`hostbootstrap` selects the per-substrate base tag from
`docker.io/tuee22/hostbootstrap:basecontainer-{cpu,cuda}-{amd64,arm64}`. The Linux CPU cohort
uses `basecontainer-cpu-amd64` (or `-arm64` on Apple-hosted Linux runners). The base ships
GHC 9.12, Cabal, kube tools (`kubectl`, `helm`, `kind`), `protoc`, `ormolu` / `fourmolu`,
`hlint`, and a warm Haskell store.

The GHC pin for this repository is **9.12**, matching the base. See
[cabal_layout.md](cabal_layout.md).

## Project Dockerfile

`docker/linux-substrate.Dockerfile` is intentionally thin:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# project-specific build steps only
WORKDIR /workspace
COPY . .
RUN cabal install --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test
```

`hostbootstrap` resolves `BASE_IMAGE` to the correct per-substrate tag and passes it via
`docker build --build-arg`. The Dockerfile carries no toolchain installation logic — every
heavy layer is in the base.

## Operator entrypoints (both cohorts)

After installing `hostbootstrap` into host Python (one-time):

```bash
python -m pip install "git+https://github.com/Tuee22/hostbootstrap.git#egg=hostbootstrap"
```

Per-clone:

```bash
hostbootstrap doctor          # detect substrate; install host prereqs
hostbootstrap cluster up      # build + bring the project up
hostbootstrap cluster status  # heartbeat-driven status (delegates inward)
hostbootstrap cluster down    # tear down; preserves ./.data/
```

`hostbootstrap doctor` replaces every responsibility the previously-planned
`bootstrap/apple-silicon.sh` and `bootstrap/linux-cpu.sh` carried (Homebrew / ghcup / Colima /
Docker Engine / Compose verification and install).

`hostbootstrap cluster up`:

- **Linux CPU**: builds the project container `FROM` the base; runs it with `service = True`,
  the `.data` and `docker.sock` mounts; the container starts `daemon-substrate-test cluster
  up`, which reconciles the kind cluster + Harbor / Pulsar / MinIO / orchestrator (and the
  worker Deployment) inside.
- **Apple Silicon**: builds `./.build/daemon-substrate-test` natively (the host already has
  GHC via ghcup); installs the LaunchDaemon that runs `daemon-substrate-test service --role
  worker --config dhall/worker.dhall`. The in-cluster reconciliation (Harbor / Pulsar /
  MinIO / orchestrator) on Apple is currently still driven by `daemon-substrate-test cluster
  up` inside the same kind cluster the worker reaches via the edge port — that piece remains
  Haskell-owned.

The boundary: above the seam (substrate detection, prereqs, container / daemon lifecycle,
LaunchDaemon installation) is `hostbootstrap`. Below the seam (kind, Harbor, Pulsar, MinIO,
the daemon roles, the lifecycle phases) is `daemon-substrate-test`.

## What this repository no longer ships

The re-baseline onto `hostbootstrap` removes the following from the planned implementation:

- `bootstrap/apple-silicon.sh` and `bootstrap/linux-cpu.sh` — absorbed into
  `hostbootstrap doctor` and the model-per-substrate launch contract.
- `compose.yaml` — replaced by the `Container` model.
- Multi-language Dockerfile layers (GHC install, kube-tools install, `protoc` install) — every
  heavy layer lives in the `hostbootstrap` base image.
- The `daemon-substrate-linux-cpu:local` launcher image — superseded by the thin project
  Dockerfile `FROM`ing the base tag.

See [`legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
for the cleanup-ledger entries that record this.

## Cross-references

- Operator runbooks: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md),
  [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md),
  [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
- First-run developer flow: [../development/local_dev.md](../development/local_dev.md)
- Cluster topology (in-cluster side): [cluster_topology.md](cluster_topology.md)
- Cabal layout (GHC 9.12 pin): [cabal_layout.md](cabal_layout.md)
- Phase that delivers the integration: [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md) (was Phase 6 before the re-baseline)
