# Phase 7: hostbootstrap.dhall + Thin Project Dockerfile

**Status**: Authoritative source
**Supersedes**: `phase-6-bootstrap-and-outer-container.md` (the original hostbootstrap-wiring phase, renumbered after the re-baseline)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-cluster-bringup-tree.md](phase-6-cluster-bringup-tree.md), [phase-8-test-harness-integration.md](phase-8-test-harness-integration.md), [../documents/engineering/hostbootstrap_integration.md](../documents/engineering/hostbootstrap_integration.md)

> **Purpose**: Land the project-side files that wire `daemon-substrate` onto
> [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap): the typed `hostbootstrap.dhall`
> at the repository root, and the thin `docker/Dockerfile` (`FROM
> ${BASE_IMAGE}` + project build).

## Phase Status

**Status**: Done

The current Phase 7 surface is the substrate-keyed `hostbootstrap` schema:
`hostbootstrap.dhall` maps `AppleSilicon` to `HostDaemon`, `LinuxCpu` to `Container`, and
`LinuxGpu` to `HostBinary`. The project name is `daemon-substrate-test`, matching the command
hostbootstrap builds and invokes. `docker/Dockerfile` is a thin
`FROM ${BASE_IMAGE}` project layer with the container-only Cabal project file, a
`daemon-substrate-test check-code` build gate, and a tini-wrapped project entrypoint with no
default `CMD`.

`hostbootstrap cluster up/down/delete` forwards plain `daemon-substrate-test cluster
up/down/delete`. `HostDaemon` workers run only as caller-owned foreground
`hostbootstrap daemon run` processes after `cluster up`; callers stop that process before
`cluster down` / `cluster delete`. There are no per-model spec files, explicit handoff commands,
launchd/systemd unit edits, PID-file daemon wrappers, development mode, or restart-after-reboot
Docker containers.

**Remaining work**: none.

## Phase Objective

Make the substrate operable on top of `hostbootstrap`. The in-cluster reconciliation logic
exists in Haskell after Phase 6; this phase ships the outer wiring as a typed Dhall config and
a thin project Dockerfile. Substrate detection, host prerequisite checks, base image selection,
artifact build, and outer lifecycle dispatch are owned by `hostbootstrap` and are not
re-implemented here.

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

- `hostbootstrap.dhall` declares project `daemon-substrate-test`.
- `AppleSilicon` uses `H.cluster (H.Model.HostDaemon ...)` with daemon arguments
  `service --role worker --config dhall/worker.dhall`.
- `LinuxCpu` uses `H.cluster (H.Model.Container ...)` with the thin Dockerfile and mounts for
  `./.data` and `/var/run/docker.sock`.
- `LinuxGpu` uses `H.cluster (H.Model.HostBinary ...)`.
- Host-native models include the optional project container artifact where the harness needs the
  project image for kind workloads.

#### Validation

Validated with repo-local static shape checks and the upstream `hostbootstrap` parser. The
checks verify the injected-`H` Dhall has no imports, declares `H.config`, carries substrate
entries for Apple Silicon, Linux CPU, and Linux GPU, and contains no explicit build, handoff,
service, or restart fields.

### Sprint 7.2: Thin project Dockerfile [Done]

**Status**: Done
**Implementation**: `docker/Dockerfile`
**Docs to update**: `../documents/engineering/cluster_topology.md`,
`../documents/engineering/hostbootstrap_integration.md`, `system-components.md`

#### Objective

Land `docker/Dockerfile` as the thin project container. The file inherits from
the `hostbootstrap` base tag passed via `BASE_IMAGE` and runs only the project's own build
steps. The heavy toolchain lives in the base.

#### Deliverables

- `ARG BASE_IMAGE`
- `FROM ${BASE_IMAGE}`
- copy project source
- run `cabal install --project-file=cabal.project.container --installdir /usr/local/bin --install-method=copy --overwrite-policy=always exe:daemon-substrate-test`
- run `daemon-substrate-test check-code`
- declare `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/daemon-substrate-test"]`
- no default `CMD`
- no toolchain installation

#### Validation

Validated with a repo-local static boundary check: the Dockerfile starts with `ARG BASE_IMAGE`
and `FROM ${BASE_IMAGE}`, uses `cabal.project.container`, runs
`daemon-substrate-test check-code`, declares the tini-wrapped entrypoint, has no `CMD`, and
contains no package-manager, `curl`, or `ghcup` toolchain installation.

### Sprint 7.3: End-to-end bring-up [Done]

**Status**: Done
**Implementation**: `hostbootstrap.dhall`, `docker/Dockerfile`,
`.build/daemon-substrate-test`, `src/Daemon/Test/CLI/Service.hs`
**Docs to update**: `../documents/operations/cluster_bootstrap_runbook.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`

#### Objective

Validate that `hostbootstrap cluster up` reaches a `Ready` cluster for the selected target and
that lifecycle commands preserve `./.data/`.

#### Deliverables

- runbook updates documenting detected-host and forced-target flows
- documented `./.data/` preservation guarantee
- documented HostDaemon process ordering: caller runs foreground `hostbootstrap daemon run`
  after `cluster up` and stops it before `cluster down` / `cluster delete`
- documented reboot policy: operator reruns `hostbootstrap cluster up`

#### Validation

Validated with detected-host and forced-target bring-up flows. The live validation evidence is
tracked in Phase 8, which owns the executable and integration readiness gate. Phase 7 validates
the hostbootstrap boundary and project-file shape that those live flows consume.

### Sprint 7.4: Substrate-keyed targets + tini ENTRYPOINT + check-code build gate [Done]

**Status**: Done
**Implementation**: `hostbootstrap.dhall`, `docker/Dockerfile`
**Docs to update**: `../documents/engineering/hostbootstrap_integration.md`,
`../documents/engineering/cluster_topology.md`, `../documents/engineering/cabal_layout.md`,
`../documents/operations/apple_silicon_runbook.md`,
`../documents/operations/linux_cpu_runbook.md`,
`../documents/operations/cluster_bootstrap_runbook.md`,
`../documents/development/local_dev.md`, `../documents/development/assistant_workflow.md`,
`../documents/reference/cli_surface.md`, `../../README.md`, `system-components.md`

#### Objective

Keep one model per substrate in a single config, remove the per-model Dhall files, remove
resident-container defaults, and align the project command with hostbootstrap's templated build
and handoff rules.

#### Deliverables

- single `hostbootstrap.dhall` with `AppleSilicon`, `LinuxCpu`, and `LinuxGpu` entries
- `project = "daemon-substrate-test"`
- no `hostbootstrap-hostbinary.dhall` or `hostbootstrap-hostdaemon.dhall`
- no explicit build or handoff command fields
- no launchd/systemd unit ownership
- no hostbootstrap daemon start/stop or PID-file ownership
- no default Dockerfile `CMD`
- direct inner `--model` debugging override retained by `daemon-substrate-test`
- `cluster delete` supported by the inner CLI

#### Validation

Static checks confirm the single Dhall file uses `H.config`, `substrates`, `H.entry`, and the
three expected substrate/model pairs. Dockerfile checks confirm the tini-wrapped entrypoint,
`check-code` gate, and absence of a default `CMD`. The harness parser accepts
`cluster up/down/delete/status`, preserves the direct `--model` override, and resolves the
hostbootstrap-selected model for plain handoff commands.

#### Remaining Work

(none)

## Documentation Requirements

**Engineering docs to create/update:**
- `../documents/engineering/hostbootstrap_integration.md` describes the substrate-keyed target
  model, plain cluster handoff, `--force-target`, the tini entrypoint, and the no-auto-restart
  policy.
- `../documents/engineering/cluster_topology.md` outer-container shape references the built
  project image, the tini `ENTRYPOINT`, and the container-only warm-store freeze.
- `../documents/engineering/cabal_layout.md` records the `ghc-9.12.4` pin and the
  container-only freeze import.

**Reference docs to create/update:**
- `../documents/reference/cli_surface.md` documents `cluster delete`, `check-code`, direct
  inner `--model` debugging, and outer `--force-target` selection.

**Operations docs to create/update:**
- `../documents/operations/apple_silicon_runbook.md`,
  `../documents/operations/linux_cpu_runbook.md`, and
  `../documents/operations/cluster_bootstrap_runbook.md` describe the single
  `hostbootstrap.dhall`, target map, HostDaemon process ordering, `cluster delete`, and no
  reboot-persistent hostbootstrap lifecycle.

**Cross-references to add:**
- `../../README.md` and `system-components.md` describe the substrate-keyed target map and the
  3×3 target/model × workflow matrix.
