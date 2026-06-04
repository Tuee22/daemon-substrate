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

**Status**: Active
**Implementation**: Sprints 7.1 and 7.2 are implemented. Sprint 7.3 has validated the Apple
Silicon hostbootstrap `doctor`, `build`, `cluster up`, LaunchDaemon inspection, and
`cluster down` lifecycle. The Apple Silicon inner kind cluster now completes a preserved-state
`down` / `up` cycle and an in-place `cluster up` with Harbor / Pulsar / MinIO PVCs bound to
repo-local data, the orchestrator Deployment rolled out, and named native Pulsar Failover
leadership validated for the reconciler. The Linux CPU hostbootstrap lifecycle and the full
`Ready` kind-cluster gate remain open because Linux CPU cohort validation has not run from
this Apple Silicon environment.

**Remaining Work**:

- Sprint 7.3: Linux CPU `hostbootstrap cluster up` validation.
- Sprint 7.3: full `Ready` cluster validation on both cohorts after Linux CPU live validation
  runs.

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
  - `H.Substrate.AppleSilicon` → `H.Model.HostDaemon` with the `cabal install` build command
    targeting `exe:daemon-substrate-test`, host prereqs (`H.HostReqs::{ ghc = True }`), and
    the `daemon` command `./.build/daemon-substrate-test service --role worker --config dhall/worker.dhall`
- shape conforms to the canonical example in
  `../documents/engineering/hostbootstrap_integration.md`

#### Validation

Validated with a repo-local static shape check because `hostbootstrap` is not installed in
this environment. The check verifies the injected-`H` Dhall has no imports and declares the
Linux CPU `Container` model, Apple Silicon `HostDaemon` model, durable `.data` and
Docker-socket mounts, host GHC prereq, build command, and worker daemon command. Live
`hostbootstrap doctor` validation moves to Sprint 7.3.

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
  - declares `CMD ["daemon-substrate-test", "cluster", "up"]` so the Linux CPU
    `Container` model's long-running service starts the inner reconciler by default
  - no toolchain installation, no `RUN apt`, no `RUN curl ... ghcup`

#### Validation

Validated with a repo-local static boundary check: the Dockerfile starts with `ARG BASE_IMAGE`
and `FROM ${BASE_IMAGE}`, runs only the project `cabal install ... exe:daemon-substrate-test`
step, declares the `daemon-substrate-test cluster up` service `CMD`, and contains no
package-manager, `curl`, or `ghcup` toolchain installation. Live `hostbootstrap build`
validation is tracked in Sprint 7.3.

### Sprint 7.3: End-to-end bring-up [Active]

**Status**: Active
**Implementation**: `hostbootstrap.dhall`, `docker/linux-substrate.Dockerfile`,
`.build/daemon-substrate-test`, `src/Daemon/Test/CLI/Service.hs`
**Docs to update**: `../documents/operations/cluster_bootstrap_runbook.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`

**Remaining Work**:

- Linux CPU cohort validation is not run in the current Apple Silicon environment.
- Full `Ready` kind-cluster validation is gated on Linux CPU validation. Live Apple Silicon
  runs now bring up deployable Harbor / Pulsar / MinIO dependencies, live admin
  interpreters, PVC-backed state, orchestrator pods, named native Pulsar Failover leadership
  for the reconciler, managed edge-port forwarding, Apple host-worker handoff, and live
  request -> orchestrator -> host worker -> response workflow handoff.
- A single Apple Silicon `down` / `up` preserved-state cycle is validated. The full closure
  gate still requires the same preservation behavior on Linux CPU and a complete `Ready`
  result from the Linux CPU cohort.

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
- Linux CPU cohort: `hostbootstrap cluster up` builds the thin project image, runs the
  container long-running with the declared mounts, and the container's
  `daemon-substrate-test cluster up` reaches `Ready`. This validation remains open until a
  Linux CPU cohort is available.
- Full cluster readiness: still open. A passing gate requires both cohorts to reach `Ready`
  and two consecutive `down` / `up` cycles to produce identical cluster state on the second
  `up` (PV reattachment, edge port preserved).
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
