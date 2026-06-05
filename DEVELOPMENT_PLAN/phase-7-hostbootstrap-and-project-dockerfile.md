# Phase 7: hostbootstrap.dhall + Thin Project Dockerfile

**Status**: Authoritative source
**Supersedes**: `phase-6-bootstrap-and-outer-container.md` (the original hostbootstrap-wiring phase, renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-cluster-bringup-tree.md](phase-6-cluster-bringup-tree.md), [phase-8-test-harness-integration.md](phase-8-test-harness-integration.md), [../documents/engineering/hostbootstrap_integration.md](../documents/engineering/hostbootstrap_integration.md)

> **Purpose**: Land the project-side files that wire `daemon-substrate` onto
> [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap): the typed `hostbootstrap.dhall`
> at the repository root, and the thin `docker/linux-substrate.Dockerfile` (`FROM
> ${BASE_IMAGE}` + project build). After this phase, an operator can run
> `hostbootstrap cluster up` on either cohort and reach a `Ready` cluster.

## Phase Status

**Status**: Done

The current Phase 7 surface is the acceleration-keyed `hostbootstrap` schema:
`hostbootstrap.dhall` declares a single `H.Accel.Cpu` `Container` target,
`hostbootstrap-hostbinary.dhall` and `hostbootstrap-hostdaemon.dhall` declare the same `Cpu`
target under the host-native models, and `docker/linux-substrate.Dockerfile` is a thin
`FROM ${BASE_IMAGE}` project layer with the container-only Cabal project file, a
`daemon-substrate-test check-code` build gate, and a tini-wrapped project entrypoint. Earlier
host-keyed bootstrap details and the shell-form service command are preserved only in the
completed cleanup ledger.

**Remaining work**: none.

## Phase Objective

Make the substrate operable on top of `hostbootstrap`. The in-cluster reconciliation logic
exists in Haskell after Phase 6; this phase ships the outer wiring as a typed Dhall config and
a thin project Dockerfile. Substrate detection, host-prereq install, container / daemon
lifecycle, and LaunchDaemon installation are owned by `hostbootstrap` and are not
re-implemented here. After Phase 7 closes, the workflow described in
`documents/operations/apple_silicon_runbook.md` and
`documents/operations/linux_cpu_runbook.md` is real on both cohorts.

The boundary is documented in
[`../documents/engineering/hostbootstrap_integration.md`](../documents/engineering/hostbootstrap_integration.md).

## Sprints

### Sprint 7.1: `hostbootstrap.dhall` [Done]

**Status**: Done
**Implementation**: `hostbootstrap.dhall`
**Docs to update**: `../documents/engineering/hostbootstrap_integration.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`, `system-components.md`

#### Objective

Land the typed default `hostbootstrap.dhall` at the repository root. The schema is bundled and
injected by `hostbootstrap` as `H`; the file has no import line.

#### Deliverables

- `hostbootstrap.dhall` declaring one `H.target H.Accel.Cpu` wrapped in
  `H.Model.Container`, with `dockerfile = "docker/linux-substrate.Dockerfile"`, `service =
  True`, and mounts for `./.data` (durable cluster state) and `/var/run/docker.sock` (so the
  container can drive its own `kind`)
- shape conforms to the canonical example in
  `../documents/engineering/hostbootstrap_integration.md`

#### Validation

Validated with repo-local static shape checks and the upstream `hostbootstrap` parser. The
checks verify the injected-`H` Dhall has no imports, declares `H.config`, carries a single
`H.target H.Accel.Cpu`, uses the `Container` model, and includes the durable `.data` and
Docker-socket mounts.

### Sprint 7.2: Thin project Dockerfile [Done]

**Status**: Done
**Implementation**: `docker/linux-substrate.Dockerfile`
**Docs to update**: `../documents/engineering/cluster_topology.md`,
`../documents/engineering/hostbootstrap_integration.md`, `system-components.md`

#### Objective

Land `docker/linux-substrate.Dockerfile` as the thin project container. The file inherits
from the `hostbootstrap` base tag (passed via `--build-arg BASE_IMAGE`) and runs only the
project's own build steps. The heavy toolchain (GHC 9.12, Cabal, kube tools, `protoc`,
formatters, warm Haskell store) lives in the base.

#### Deliverables

- `docker/linux-substrate.Dockerfile`:
  - `ARG BASE_IMAGE`
  - `FROM ${BASE_IMAGE}`
  - copies the project source and runs
    `cabal install --project-file=cabal.project.container --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test`
  - runs `daemon-substrate-test check-code`
  - declares a tini-wrapped `ENTRYPOINT` for `/usr/local/bin/daemon-substrate-test`
  - declares `CMD ["cluster", "up", "--model", "container", "--stay-resident"]` so the
    `Container` model's long-running service starts the inner reconciler by default and remains
    resident after successful reconciliation
  - no toolchain installation, no `RUN apt`, no `RUN curl ... ghcup`

#### Validation

Validated with a repo-local static boundary check: the Dockerfile starts with `ARG BASE_IMAGE`
and `FROM ${BASE_IMAGE}`, uses `cabal.project.container`, runs
`daemon-substrate-test check-code`, declares the tini-wrapped entrypoint and resident container
`CMD`, and contains no package-manager, `curl`, or `ghcup` toolchain installation.

### Sprint 7.3: End-to-end bring-up [Done]

**Status**: Done
**Implementation**: `hostbootstrap.dhall`, `docker/linux-substrate.Dockerfile`,
`.build/daemon-substrate-test`, `src/Daemon/Test/CLI/Service.hs`
**Docs to update**: `../documents/operations/cluster_bootstrap_runbook.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`

#### Objective

Validate that `hostbootstrap cluster up` reaches a `Ready` cluster on both cohorts, and that
the lifecycle preserves `./.data/` across cycles.

#### Deliverables

- runbook updates documenting verification steps (kubeconfig path, `launchctl list`
  inspection on Apple, edge-port inspection)
- documented `./.data/` preservation guarantee (`hostbootstrap` never deletes the mount)
- on Apple Silicon, documented LaunchDaemon install / remove behavior on `hostbootstrap
  cluster up` / `cluster down`

#### Validation

- Apple cohort outer lifecycle validated locally with:
  - `hostbootstrap doctor --spec hostbootstrap.dhall`
  - `hostbootstrap build --spec hostbootstrap.dhall`
  - `hostbootstrap cluster up --spec hostbootstrap.dhall`
  - `launchctl print system/com.hostbootstrap.daemon-substrate`
  - `hostbootstrap cluster down --spec hostbootstrap.dhall`

  The run built `.build/daemon-substrate-test`, installed
  `/Library/LaunchDaemons/com.hostbootstrap.daemon-substrate.plist`, reported the
  LaunchDaemon as `state = running` with the expected `service --role worker --config
  dhall/worker.dhall` arguments, and removed the LaunchDaemon on `cluster down`.
- Linux cohort: `hostbootstrap doctor --spec hostbootstrap.dhall` reports `linux-gpu`
  (`amd64`) on the validated host, with Ubuntu 24.04, passwordless sudo, Docker daemon
  access, and NVIDIA runtime checks passing. `hostbootstrap.dhall` maps that detected
  substrate to the same CPU-flavored Container model used for Linux CPU validation.
  `hostbootstrap build --spec hostbootstrap.dhall` builds
  `daemon-substrate:linux-gpu-amd64` from the thin project Dockerfile. `hostbootstrap cluster
  up --spec hostbootstrap.dhall` starts the long-running service container, runs
  `daemon-substrate-test cluster up`, attaches the container to Docker's `kind` network,
  exports the internal kind kubeconfig, waits for node readiness, deploys Harbor / Pulsar /
  MinIO, rolls out the orchestrator and worker Deployments, and persists edge ports
  `9090`/`9091`/`9092`.
- Full cluster readiness: closed for the phase. Apple Silicon and Linux both reach `Ready`.
  Linux validation included two consecutive inner `daemon-substrate-test cluster down` /
  `cluster up` cycles against the same `.data` mount; both re-created kind, reattached the
  retained PVs, rolled out dependencies and daemon workloads, and preserved the edge-port
  record at base port `9090`.
- Apple Silicon inner kind preserved-state validation has been exercised with:
  - `daemon-substrate-test cluster down`
  - `daemon-substrate-test cluster up`
  - PV/PVC inspection showing Harbor, Pulsar, and MinIO claims bound
  - Pulsar topic lookup returning the in-cluster advertised broker service
  - persisted MinIO and Pulsar state under
    `./.data/kind/apple-silicon/daemon-substrate/`

### Sprint 7.4: Single `Cpu` target + tini ENTRYPOINT + check-code build gate [Done]

**Status**: Done
**Implementation**: `hostbootstrap.dhall`, `hostbootstrap-hostbinary.dhall`,
`hostbootstrap-hostdaemon.dhall`, `docker/linux-substrate.Dockerfile`
**Docs to update**: `../documents/engineering/hostbootstrap_integration.md`,
`../documents/engineering/cluster_topology.md`, `../documents/engineering/cabal_layout.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`,
`../documents/operations/cluster_bootstrap_runbook.md`,
`../documents/development/local_dev.md`, `../documents/development/assistant_workflow.md`,
`../documents/reference/cli_surface.md`, `../../README.md`, `system-components.md`

#### Objective

Migrate the project-side bootstrap wiring from the host-keyed schema to the acceleration-keyed
schema: one `H.Accel.Cpu` target that runs on every host, the three execution models driven by
separate `--spec` files, a tini-wrapped Dockerfile `ENTRYPOINT` with a `check-code` build gate,
and a warm-store freeze scoped to container builds. `hostbootstrap` is installed via `pipx`.

#### Deliverables

- `hostbootstrap.dhall` rewritten to
  `H.config { project = "daemon-substrate", targets = [ H.target H.Accel.Cpu ( H.Model.Container … ) ] }`
  — a single `Cpu` target, no host-keyed entries, no `flavor` field (`HostReqs` is `{ ghc }`).
- `hostbootstrap-hostbinary.dhall` and `hostbootstrap-hostdaemon.dhall` declaring the same
  single `H.Accel.Cpu` target wrapped in `H.Model.HostBinary` / `H.Model.HostDaemon`; the
  `HostDaemon` spec installs launchd on Apple and systemd on Linux from one declaration.
- `docker/linux-substrate.Dockerfile` gains a tini-wrapped `ENTRYPOINT`, a
  `RUN daemon-substrate-test check-code` build gate, and a default
  `cluster up --model container --stay-resident` command that runs the inner reconciler and
  keeps the service container resident (replacing the `CMD … sleep infinity` form).
- the container build imports the warm-store `cabal.project.freeze`; native `HostBinary` /
  `HostDaemon` builds do not.

#### Validation

- Static checks confirm all three spec files use `H.config`, `targets`, and a single
  `H.target H.Accel.Cpu`, with no `H.Substrate`, `H.entry`, `substrates`, `H.Flavor`, or
  `flavor` fields.
- The current upstream `hostbootstrap` schema parser loads the three specs as
  `ContainerModel`, `HostBinaryModel`, and `HostDaemonModel`, all under project
  `daemon-substrate` with one `cpu` target.
- Static Dockerfile checks confirm `ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`, no toolchain
  installation, `--project-file=cabal.project.container`, `RUN daemon-substrate-test
  check-code`, a tini-wrapped `ENTRYPOINT`, and `CMD ["cluster", "up", "--model",
  "container", "--stay-resident"]`.

#### Remaining Work

(none)

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/hostbootstrap_integration.md` describes the acceleration-keyed
  target model, capability subsumption, the multi-spec approach, the tini-ENTRYPOINT +
  `check-code` Dockerfile, and `pipx` install.
- `../documents/engineering/cluster_topology.md` outer-container shape references the built
  project image, the tini `ENTRYPOINT`, and the container-only warm-store freeze.
- `../documents/engineering/cabal_layout.md` records the `ghc-9.12.4` pin and the
  container-only freeze import.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` documents the `check-code` build-gate subcommand
  and the `hostbootstrap … --spec` per-model selection.

**Operations docs to create/update:**
- `../documents/operations/apple_silicon_runbook.md` and
  `../documents/operations/linux_cpu_runbook.md` describe the single `Cpu` target, the per-model
  specs, and `pipx` install; no `pip install` lines.
- `../documents/operations/cluster_bootstrap_runbook.md` describes `--spec` model selection and
  `cluster delete`.

**Cross-references to add:**
- `../../README.md` and `system-components.md` describe the single `Cpu` target, the three
  execution models, and the 3×3 model × workflow matrix. `system-components.md` keeps the
  `hostbootstrap.dhall`, base-image, and project-Dockerfile rows accurate for the
  acceleration-keyed shape.
