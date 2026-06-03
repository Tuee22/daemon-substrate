# Phase 6: Bootstrap and Outer Container

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-kind-cluster-and-helm-chart.md](phase-5-kind-cluster-and-helm-chart.md), [phase-7-test-harness-integration.md](phase-7-test-harness-integration.md)

> **Purpose**: Land the supported operator entrypoints: `bootstrap/apple-silicon.sh`,
> `bootstrap/linux-cpu.sh`, the `docker/linux-substrate.Dockerfile` and `compose.yaml`. After
> this phase, an operator can run a single bootstrap command and reach a `Ready` cluster.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 5
**Implementation**: none yet

## Phase Objective

Make the substrate operable. The cluster bring-up logic exists in Haskell after Phase 5; this
phase wraps it in the shell + Docker scaffolding that operators actually invoke. After Phase
6 closes, the workflow described in `documents/operations/apple_silicon_runbook.md` and
`documents/operations/linux_cpu_runbook.md` is real on both cohorts.

## Sprints

### Sprint 6.1: Apple Silicon bootstrap script [Planned]

**Status**: Planned
**Docs to update**: `documents/operations/apple_silicon_runbook.md`, `system-components.md`

#### Objective

Land `bootstrap/apple-silicon.sh` as a restartable prerequisite reconciler. Installs Homebrew
/ ghcup-managed prerequisites where missing, builds `./.build/daemon-substrate-test`,
stages Dhall under `./.build/`, delegates to the binary for cluster lifecycle.

#### Deliverables

- `bootstrap/apple-silicon.sh` with `up` and `down` subcommands
- prerequisite verification (ghcup version, GHC pin, Cabal pin, Colima running)
- `cabal install --installdir=./.build --install-method=copy --overwrite-policy=always
  daemon-substrate-test` to build the binary
- bootstrap-script invocation: only hardcoded absolute-path constants; no inherited env
  vars; `PATH=/usr/bin:/bin` reset at top

#### Validation

On a clean macOS arm64 host with Homebrew + ghcup present, `./bootstrap/apple-silicon.sh up`
produces a `Ready` cluster.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 6.2: Linux CPU outer container [Planned]

**Status**: Planned
**Blocked by**: 6.1 (re-uses shared script idioms)
**Docs to update**: `documents/operations/linux_cpu_runbook.md`, `system-components.md`

#### Objective

Land `docker/linux-substrate.Dockerfile`, `compose.yaml`, and `bootstrap/linux-cpu.sh`. The
Dockerfile produces `daemon-substrate-linux-cpu:local`; compose.yaml exposes a single
`daemon-substrate` service with the bind mounts and Docker socket access required for kind.

#### Deliverables

- `docker/linux-substrate.Dockerfile` building from a current Ubuntu / Debian base, including
  GHC 9.14.1, Cabal, the kind binary, kubectl, helm, and the compiled
  `daemon-substrate-test` binary baked into the image
- `compose.yaml` with `daemon-substrate` service, bind mount `./.data:/workspace/.data`,
  Docker socket mount, no `environment:` block
- `bootstrap/linux-cpu.sh` verifying Docker prereqs and delegating to `docker compose run
  --rm daemon-substrate daemon-substrate-test cluster up`

#### Validation

On a clean Ubuntu 24.04 host with Docker installed, `./bootstrap/linux-cpu.sh up` produces a
`Ready` cluster.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 6.3: Bootstrap "down" parity [Planned]

**Status**: Planned
**Blocked by**: 6.1, 6.2
**Docs to update**: `documents/operations/cluster_bootstrap_runbook.md`

#### Objective

Make `./bootstrap/<cohort>.sh down` reach parity with `daemon-substrate-test cluster down`
and confirm that durable repo state survives the cycle on both cohorts.

#### Deliverables

- `down` subcommand on both scripts, delegating to `cluster down`
- documented preservation guarantee for `./.data/`, `./.build/` (Apple), launcher image
  (Linux)

#### Validation

Two consecutive `up` / `down` cycles on either cohort produce identical cluster state on the
second `up` (cluster reattaches to the same PVs, edge port is preserved if available).

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- none unique to this phase (engineering docs landed in earlier phases)

**Reference docs to create/update:**
- `documents/reference/cli_surface.md` updates the `daemon-substrate-test` invocation
  examples from "planned" to current-state declarative.

**Operations docs to create/update:**
- `documents/operations/apple_silicon_runbook.md` updates from forward-looking to
  current-state.
- `documents/operations/linux_cpu_runbook.md` updates from forward-looking to current-state.
- `documents/operations/cluster_bootstrap_runbook.md` updates the heartbeat / progress
  sections as they become observable in practice.

**Cross-references to add:**
- `system-components.md` flips bootstrap entrypoint rows to `Implemented: yes`.
