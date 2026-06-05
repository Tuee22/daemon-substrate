# hostbootstrap Integration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../../README.md](../../README.md), [../../CLAUDE.md](../../CLAUDE.md), [../../AGENTS.md](../../AGENTS.md), [../development/local_dev.md](../development/local_dev.md), [../development/assistant_workflow.md](../development/assistant_workflow.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [cabal_layout.md](cabal_layout.md), [cluster_topology.md](cluster_topology.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md), [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Define how `daemon-substrate` sits on top of [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) —
> the acceleration-keyed target model and capability subsumption, the canonical
> `hostbootstrap.dhall` shape this repository ships, the multi-spec approach for the three
> execution models, and the boundary between what `hostbootstrap` owns and what
> `daemon-substrate-test` owns.

## TL;DR

- `hostbootstrap` is a `pipx`-installed Python CLI plus prebuilt base container images. It
  is the canonical infrastructure layer for this repository.
- `daemon-substrate` declares its behavior as a single `H.Accel.Cpu` **target** in a typed
  `hostbootstrap.dhall` at the repository root. `H.Accel = <Cpu | Cuda | Metal>` is the
  workload's acceleration *requirement*; the host is detected and matched by capability
  subsumption.
- `daemon-substrate` is CPU-only (no GPU, no Metal, no CUDA), so it declares exactly one
  `H.Accel.Cpu` target. A single `Cpu` target runs on **every** host — `apple-silicon`,
  `linux-cpu`, and `linux-gpu`, amd64 and arm64. There is no host-keyed cohort split.
- The three execution **models** are `Container`, `HostBinary`, and `HostDaemon`. Because one
  spec carries one model, the models are driven by separate spec files via
  `hostbootstrap … --spec <file>`.
- `hostbootstrap cluster up` is the outer operator entrypoint. The inner cluster reconciler is
  `daemon-substrate-test cluster up`, and the target is the full 3×3 model × workflow matrix.

## Current Status

The acceleration-keyed schema (`H.config { project, targets = [ H.target H.Accel.Cpu … ] }`),
the single `Cpu` target, the three per-model spec files, the tini-wrapped container
`ENTRYPOINT`, and the `daemon-substrate-test check-code` Dockerfile build gate are implemented
repo-side. Phase 7 Sprint 7.4 closed the project-side `hostbootstrap` schema migration, and
Phase 8 Sprint 8.7 closed the model-keyed harness surface. The obsolete host-keyed entries are
recorded as completed cleanup in
[`../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## Why hostbootstrap

[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) standardizes host detection,
host-prereq install, the multi-language base toolchain (`ghc-9.12.4`, Cabal, kube tools,
`protoc`, `ormolu`, `hlint`, warm Haskell store), and the Container / HostBinary / HostDaemon
execution models at the OS level — the exact surface `daemon-substrate-test` would otherwise
hand-roll. Adopting it collapses what would have been per-host bootstrap scripts and a custom
Dockerfile family into one declarative Dhall file plus a thin project Dockerfile. The same tool
is consumed by [`infernix`](https://github.com/Tuee22/infernix) and
[`jitML`](https://github.com/Tuee22/jitML), so the three-project family shares one
infrastructure substrate.

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
> `hostbootstrap`'s `HostBinary` model invokes `daemon-substrate-test` per command; and
> `hostbootstrap`'s `HostDaemon` model runs `daemon-substrate-test service --role worker
> --config dhall/worker.dhall` as a managed service. Everything above the seam stays in
> Haskell.

The seam is the only place host identifiers cross from `hostbootstrap` into
`daemon-substrate`. The substrate-agnostic library rule in
[../architecture/library_consumption_model.md](../architecture/library_consumption_model.md) is
unchanged: `src/Daemon/*` never branches on host or acceleration.

## Acceleration targets and capability subsumption

`hostbootstrap` is keyed by **acceleration requirement**, not by host. A target declares the
acceleration capability the workload needs — `H.Accel = <Cpu | Cuda | Metal>` — and
`hostbootstrap` detects the host and matches it by **capability subsumption**:

| Detected host | Capabilities it satisfies |
|---------------|----------------------------|
| `apple-silicon` | `{ Cpu, Metal }` |
| `linux-cpu` | `{ Cpu }` |
| `linux-gpu` | `{ Cpu, Cuda }` |

A `Cpu` target is subsumed by every host, so it runs everywhere (amd64 and arm64). A `Cuda`
target runs only on `linux-gpu`; a `Metal` target runs only on `apple-silicon`. The old
host-keyed `AppleSilicon → HostDaemon` / `LinuxGpu → Container` cohort mapping is gone, and so
is the `flavor` field — flavor is now *derived* from the target's `H.Accel`. CUDA-on-Apple is
unrepresentable because no host satisfies both `Cuda` and `Metal`.

`daemon-substrate` is **CPU-only**: the mock engine performs no GPU, Metal, or CUDA work. It
therefore declares exactly one `H.Accel.Cpu` target, which runs on every host. Consumers
(`infernix`, `jitML`) carry their own `Cuda` / `Metal` targets against their own model
matrices.

## The three execution models, one spec each

The three execution models are `Container`, `HostBinary`, and `HostDaemon`:

| Model | What it launches |
|-------|------------------|
| `Container` | `daemon-substrate-test cluster up` inside the thin project container, which reconciles the in-cluster kind topology |
| `HostBinary` | `daemon-substrate-test <cmd>` natively on the host, invoked per command |
| `HostDaemon` | `daemon-substrate-test service --role worker --config dhall/worker.dhall` as a managed long-lived service — launchd on Apple, systemd on Linux, from one declaration |

Because one spec carries one model, the three models are driven by **separate spec files**
selected with `hostbootstrap … --spec <file>`:

| Spec file | Model |
|-----------|-------|
| `hostbootstrap.dhall` (default) | `Container` |
| `hostbootstrap-hostbinary.dhall` | `HostBinary` |
| `hostbootstrap-hostdaemon.dhall` | `HostDaemon` |

A `Cpu` `HostDaemon` now runs on Apple (launchd) **and** Linux (systemd) from one declaration,
replacing the old Apple-only LaunchDaemon path.

## Canonical `hostbootstrap.dhall`

The repository ships `hostbootstrap.dhall` at the root (the `Container` default). The CLI
bundles and injects the typed schema as `H`; the file has no import line.

```dhall
H.config
  { project = "daemon-substrate"
  , targets =
    [ H.target H.Accel.Cpu
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
    ]
  }
```

The `hostbootstrap-hostbinary.dhall` and `hostbootstrap-hostdaemon.dhall` specs declare the
same single `H.Accel.Cpu` target wrapped in `H.Model.HostBinary` and `H.Model.HostDaemon`
respectively. Both host-native specs build `exe:daemon-substrate-test` into
`.build/daemon-substrate-test` and copy it to `.build/daemon-substrate`, the artifact path
`hostbootstrap run` expects for project `daemon-substrate`. The `HostBinary` spec declares
handoff commands for `cluster up --model host-binary` / `cluster down --model host-binary`.
The `HostDaemon` spec declares the managed service command
`.build/daemon-substrate-test service --role worker --config dhall/worker.dhall`.

## Base image and toolchain

`hostbootstrap` selects the base tag from
`docker.io/tuee22/hostbootstrap:basecontainer-{cpu,cuda}-{amd64,arm64}`. A `Cpu` target uses
`basecontainer-cpu-amd64` (or `-arm64`). The base ships `ghc-9.12.4`, Cabal, kube tools
(`kubectl`, `helm`, `kind`), `protoc`, `ormolu`, `hlint`, and a warm Haskell store.

The GHC pin for this repository is exactly **`ghc-9.12.4`**, matching the base. The warm-store
`cabal.project.freeze` import applies to **container builds only**; host/native builds
(`HostBinary`, `HostDaemon`) do not use the warm store. See [cabal_layout.md](cabal_layout.md).

## Project Dockerfile

`docker/linux-substrate.Dockerfile` is intentionally thin:

```dockerfile
# check=skip=InvalidDefaultArgInFrom
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
COPY . .
RUN cabal install --project-file=cabal.project.container --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test
RUN daemon-substrate-test check-code

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/daemon-substrate-test"]
CMD ["cluster", "up", "--model", "container", "--stay-resident"]
```

`hostbootstrap` resolves `BASE_IMAGE` to the correct per-acceleration tag and passes it via
`docker build --build-arg`. The Dockerfile carries no toolchain installation logic — every
heavy layer is in the base. The `RUN daemon-substrate-test check-code` step is the local
build gate documented in [../reference/cli_surface.md](../reference/cli_surface.md). The
tini-wrapped `ENTRYPOINT`
reaps zombies and forwards signals; the container's default service command remains the inner
cluster reconciler and keeps the container resident so hostbootstrap's restart policy does not
repeatedly rerun a completed `cluster up`.

## Operator entrypoints

`hostbootstrap` is installed via `pipx` only. Install the prereqs first, then the tool:

- **macOS**: `brew install pipx && pipx ensurepath`
- **Ubuntu**: `sudo apt install -y pipx && pipx ensurepath`

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

Per-clone (the model is selected by `--spec`; `hostbootstrap.dhall` is the `Container`
default):

```bash
hostbootstrap doctor          # detect host; install host prereqs
hostbootstrap cluster up      # build + bring the project up
hostbootstrap cluster down    # tear down; preserves ./.data/
hostbootstrap cluster delete  # thorough teardown; still preserves ./.data/
```

`hostbootstrap doctor` replaces every responsibility per-host bootstrap scripts would carry
(Homebrew / ghcup / Colima / Docker Engine verification and install).

`hostbootstrap cluster up`:

- **`Container` model**: builds the project container `FROM` the base; runs it with
  `service = True`, the `.data` and `docker.sock` mounts; the container starts
  `daemon-substrate-test cluster up --model container --stay-resident`, attaches itself to
  Docker's `kind` network, exports kind's internal kubeconfig, and reconciles the kind cluster
  + Harbor / Pulsar / MinIO / orchestrator (and the worker Deployment) inside. After a
  successful reconciliation, the container stays resident for `hostbootstrap run` /
  `docker exec` diagnostics.
- **`HostBinary` model**: builds `./.build/daemon-substrate-test` natively and invokes it per
  handoff command (`cluster up --model host-binary`, `cluster down --model host-binary`)
  without installing a managed service.
- **`HostDaemon` model**: builds `./.build/daemon-substrate-test` natively; installs or
  removes the managed worker service (launchd on Apple, systemd on Linux) that runs
  `daemon-substrate-test service --role worker --config dhall/worker.dhall`. One-shot
  cluster reconciliation for this model is available through
  `hostbootstrap run cluster up --model host-daemon`, not through the managed-service install
  step itself.

The boundary: above the seam (host detection, prereqs, the Container / HostBinary / HostDaemon
lifecycle, managed-service installation) is `hostbootstrap`. Below the seam (kind, Harbor,
Pulsar, MinIO, the daemon roles, the lifecycle phases) is `daemon-substrate-test`.

## hostbootstrap CLI surface

The relevant outer commands (each accepts `--spec <file>` to select the model):

| Command | Purpose |
|---------|---------|
| `hostbootstrap doctor` | Detect host; idempotently install host prereqs |
| `hostbootstrap build` | Build the project artifact (container image or native binary) |
| `hostbootstrap run <cmd...>` | Dispatch a command into the container (Container) or run the host binary (HostBinary / HostDaemon) |
| `hostbootstrap cluster up` | Build and launch per the model declared in the active spec |
| `hostbootstrap cluster down` | Tear down (preserves `./.data/`) |
| `hostbootstrap cluster delete` | Thorough teardown (still preserves `./.data/`) |
| `hostbootstrap base …` | Manage the prebuilt base image inventory |

## What this repository no longer ships

The re-baseline onto `hostbootstrap` removes the following from the planned implementation:

- per-host bootstrap scripts — absorbed into `hostbootstrap doctor` and the per-model launch
  contract.
- `compose.yaml` — replaced by the `Container` model.
- Multi-language Dockerfile layers (GHC install, kube-tools install, `protoc` install) — every
  heavy layer lives in the `hostbootstrap` base image.
- The host-keyed `hostbootstrap.dhall` entries (`AppleSilicon → HostDaemon`, `LinuxGpu →
  Container`) — replaced by the single `H.Accel.Cpu` target plus per-model spec files.
- The `flavor` field — derived from the target's `H.Accel`.

See [`legacy-tracking-for-deletion.md`](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
for the cleanup-ledger entries that record this.

## Cross-references

- Operator runbooks: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md),
  [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md),
  [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)
- First-run developer flow: [../development/local_dev.md](../development/local_dev.md)
- Cluster topology (in-cluster side): [cluster_topology.md](cluster_topology.md)
- Cabal layout (`ghc-9.12.4` pin, container-only freeze): [cabal_layout.md](cabal_layout.md)
- Phase that delivers the integration: [../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md](../../DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md) (was Phase 6 before the re-baseline)
