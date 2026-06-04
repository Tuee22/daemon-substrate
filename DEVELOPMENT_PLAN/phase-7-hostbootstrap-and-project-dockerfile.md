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
**Implementation**: Sprints 7.1, 7.2, and 7.3 are implemented and validated. Apple Silicon
hostbootstrap `doctor`, `build`, `cluster up`, LaunchDaemon inspection, and `cluster down`
lifecycle are validated. Linux hostbootstrap `doctor`, `build`, and `cluster up` are
validated on an Ubuntu 24.04 amd64 host that hostbootstrap detects as `linux-gpu`; this
repository maps that detected substrate to the CPU-flavored harness container because the
test harness intentionally has no GPU cohort. The Linux service container runs `cluster up`
to completion, stays resident, and reaches a `Ready` kind cluster with Harbor / Pulsar /
MinIO PVCs bound, orchestrator and worker Deployments rolled out, and the edge-port record
preserved. Two consecutive preserved-state Linux `cluster down` / `cluster up` cycles
reattach the retained PVs and preserve edge ports.

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

Land the typed `hostbootstrap.dhall` at the repository root declaring `Container` for
`H.Substrate.LinuxCpu` and `HostDaemon` for `H.Substrate.AppleSilicon`. The schema is bundled
and injected by `hostbootstrap` as `H`; the file has no import line.

#### Deliverables

- `hostbootstrap.dhall` declaring:
  - `H.Substrate.LinuxCpu` → `H.Model.Container` with `dockerfile = "docker/linux-substrate.Dockerfile"`,
    `service = True`, and mounts for `./.data` (durable cluster state) and `/var/run/docker.sock`
    (so the container can drive its own `kind`)
  - `H.Substrate.LinuxGpu` → the same CPU-flavored `H.Model.Container`, for hosts where
    hostbootstrap detects NVIDIA runtime support even though this repository has no GPU
    cohort
  - `H.Substrate.AppleSilicon` → `H.Model.HostDaemon` with the `cabal install` build command
    targeting `exe:daemon-substrate-test`, host prereqs (`H.HostReqs::{ ghc = True }`), and
    the `daemon` command `./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall`
- shape conforms to the canonical example in
  `../documents/engineering/hostbootstrap_integration.md`

#### Validation

Validated with repo-local static shape checks and live `hostbootstrap doctor` in Sprint 7.3.
The checks verify the injected-`H` Dhall has no imports and declares the Linux CPU
`Container` model, the Linux GPU-detected CPU harness compatibility entry, Apple Silicon
`HostDaemon` model, durable `.data` and Docker-socket mounts, host GHC prereq, build command,
and worker daemon command.

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
    `cabal install --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test`
  - declares `CMD ["/bin/sh", "-c", "daemon-substrate-test cluster up && sleep infinity"]`
    so the Linux CPU `Container` model's long-running service starts the inner reconciler by
    default and remains resident after successful reconciliation
  - no toolchain installation, no `RUN apt`, no `RUN curl ... ghcup`

#### Validation

Validated with a repo-local static boundary check: the Dockerfile starts with `ARG BASE_IMAGE`
and `FROM ${BASE_IMAGE}`, runs only the project `cabal install ... exe:daemon-substrate-test`
step, declares the `daemon-substrate-test cluster up && sleep infinity` service `CMD`, and
contains no package-manager, `curl`, or `ghcup` toolchain installation. Live
`hostbootstrap build` validation is tracked in Sprint 7.3.

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

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/hostbootstrap_integration.md` updates from forward-looking to
  current-state as the `hostbootstrap.dhall` and project Dockerfile land.
- `../documents/engineering/cluster_topology.md` outer-container shape (Linux) references the
  built project image.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` confirms the outer / inner CLI split is current-state.

**Operations docs to create/update:**
- `../documents/operations/apple_silicon_runbook.md` updates from forward-looking to
  current-state.
- `../documents/operations/linux_cpu_runbook.md` updates from forward-looking to current-state.
- `../documents/operations/cluster_bootstrap_runbook.md` updates the heartbeat / progress
  sections as they become observable in practice.

**Cross-references to add:**
- `system-components.md` flips the `hostbootstrap.dhall`, base-image, and project-Dockerfile
  rows to `Implemented: yes`.
