# Phase 1: Library Scaffolding and Cabal Package

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-0-documentation-and-governance.md](phase-0-documentation-and-governance.md), [phase-2-capability-typeclasses-and-admin-surfaces.md](phase-2-capability-typeclasses-and-admin-surfaces.md)

> **Purpose**: Establish the cabal package, GHC pin, module skeleton, and CI build so later
> phases have a place to land their code.

## Phase Status

**Status**: Done
**Implementation**: `daemon-substrate.cabal`, `cabal.project`, `src/Daemon/`,
`test/`, `.github/workflows/ci.yml`
**Remaining work**: none.

## Phase Objective

Stand up the structural shell of the library: `daemon-substrate.cabal`, `cabal.project` with
GHC 9.12 pinned, an empty `src/Daemon/` skeleton, and a no-op `cabal build all` that
verifies the toolchain is healthy.

No public typeclass surface lands in this phase. Phase 1 produces a buildable but empty
library; Phase 2 fills the typeclass surface in.

## Sprints

### Sprint 1.1: Cabal package + GHC pin [Done]

**Status**: Done
**Implementation**: `daemon-substrate.cabal`, `cabal.project`, `test/`
**Docs to update**: `documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Create `daemon-substrate.cabal` and `cabal.project` matching the consumer projects'
toolchain.

#### Deliverables

- `daemon-substrate.cabal` with one `library` stanza and the four `test-suite` stanzas
  (`daemon-substrate-unit`, `daemon-substrate-lifecycle`, `daemon-substrate-integration`,
  `daemon-substrate-haskell-style`; initially empty `Main.hs` placeholders)
- `cabal.project` with `with-compiler: ghc-9.12` (matching the
  [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) base image) and the
  `allow-newer: *:base, *:template-haskell` carve-out
- `cabal build all` succeeds with the placeholder modules

#### Validation

`cabal build all` exits 0 on a fresh clone after `cabal update`.

#### Remaining Work

(none)

### Sprint 1.2: Module skeleton [Done]

**Status**: Done
**Implementation**: `src/Daemon/`
**Docs to update**: `documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Create the empty `src/Daemon/*.hs` files (just `module` declarations) so the cabal stanza
compiles them and so Phase 2 has a place to add typeclass definitions.

#### Deliverables

- `src/Daemon/Sub.hs` (the typed `Subprocess` boundary later phases shell out through for
  MinIO / Harbor / Kubectl / `SubprocessEngine`; Pulsar runs in-process instead),
  `src/Daemon/Pulsar.hs`, `src/Daemon/MinIO.hs`, `src/Daemon/MinIO/Cache.hs`,
  `src/Daemon/Engine.hs`, `src/Daemon/Lifecycle.hs`, `src/Daemon/Config.hs`,
  `src/Daemon/Worker.hs`, `src/Daemon/Orchestrator.hs`, `src/Daemon/WorkflowState.hs`
- Each file is a bare `module Daemon.<Name> where` with no exports
- `exposed-modules` in the library stanza lists every file

#### Validation

`cabal build all` still succeeds. `cabal repl daemon-substrate` loads every module.

#### Remaining Work

(none)

### Sprint 1.3: CI build [Done]

**Status**: Done
**Implementation**: `.github/workflows/ci.yml`
**Docs to update**: `documents/development/local_dev.md`

#### Objective

Wire a GitHub Action that runs `cabal build all` and `cabal test daemon-substrate-unit` on
push to `main` and on pull requests.

#### Deliverables

- `.github/workflows/ci.yml` building on `ubuntu-latest` with GHC 9.12
- Optionally, a separate matrix entry building on `macos-latest` (Apple cohort)

#### Validation

CI workflow runs green on the first push that includes it.

#### Remaining Work

(none)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` updates from provisional to current-state declarative
  once the cabal file exists.

**Reference docs to create/update:**
- none unique to this phase

**Cross-references to add:**
- `system-components.md` flips Phase 1 inventory rows from `Implemented: no` to
  `Implemented: yes` as sprints close.
