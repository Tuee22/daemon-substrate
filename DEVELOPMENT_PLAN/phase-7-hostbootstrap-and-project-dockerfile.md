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

**Status**: Blocked
**Blocked by**: Phase 6
**Implementation**: none yet

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

### Sprint 7.1: `hostbootstrap.dhall` [Planned]

**Status**: Planned
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
  - `H.Substrate.AppleSilicon` → `H.Model.HostDaemon` with the `cabal install` build command
    targeting `exe:daemon-substrate-test`, host prereqs (`H.HostReqs::{ ghc = True }`), and
    the `daemon` command `./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall`
- shape conforms to the canonical example in
  `../documents/engineering/hostbootstrap_integration.md`

#### Validation

`hostbootstrap doctor` succeeds on a clean macOS arm64 host (Apple cohort) and on a clean
Ubuntu 24.04 host with Docker installed (Linux cohort). The Dhall parses cleanly via
`hostbootstrap`'s bundled `dhall-to-json`.

### Sprint 7.2: Thin project Dockerfile [Planned]

**Status**: Planned
**Blocked by**: 7.1
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
  - no toolchain installation, no `RUN apt`, no `RUN curl ... ghcup`

#### Validation

`hostbootstrap build` produces the project image with the compiled `daemon-substrate-test`
binary on `$PATH` inside the container. The image size is dominated by the base; the project
layer is small.

### Sprint 7.3: End-to-end bring-up [Planned]

**Status**: Planned
**Blocked by**: 7.1, 7.2
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

- Apple cohort: `hostbootstrap cluster up` builds the binary, installs
  `/Library/LaunchDaemons/com.tuee22.daemon-substrate.worker.plist`, brings the kind cluster
  to `Ready`. `hostbootstrap cluster down` removes the LaunchDaemon and tears the cluster
  down. Two consecutive `down` / `up` cycles produce identical cluster state on the second
  `up` (PV reattachment, edge port preserved).
- Linux CPU cohort: `hostbootstrap cluster up` builds the thin project image, runs the
  container long-running with the declared mounts, and the container's
  `daemon-substrate-test cluster up` reaches `Ready`. Two consecutive `down` / `up` cycles
  produce identical cluster state on the second `up`.

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
