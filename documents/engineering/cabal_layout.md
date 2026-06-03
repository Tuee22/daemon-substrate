# Cabal Layout

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../development/testing_strategy.md](../development/testing_strategy.md)

> **Purpose**: Define the `daemon-substrate.cabal` package shape — what library, executables,
> and test-suites exist, and why no further sublibrary or package split is supported yet.

## TL;DR

- One library (`daemon-substrate`) carries every public `Daemon.*` module that consumers depend
  on.
- One executable (`daemon-substrate-test`) drives the test harness.
- Three test-suite stanzas: `daemon-substrate-unit`, `daemon-substrate-integration`,
  `daemon-substrate-haskell-style`. All use `type: exitcode-stdio-1.0`.
- No sublibrary split, no separate `internal` package. Consumers depend on the top-level
  library only.

## Package shape

```
daemon-substrate/
├── daemon-substrate.cabal
├── cabal.project          # GHC pin (9.14.1), allow-newer carve-outs
├── src/                   # library sources
│   └── Daemon/
│       ├── Pulsar.hs
│       ├── MinIO.hs
│       ├── MinIO/Cache.hs
│       ├── Engine.hs
│       ├── Lifecycle.hs
│       ├── Config.hs
│       ├── Worker.hs
│       ├── Orchestrator.hs
│       ├── WorkflowState.hs
│       ├── Cluster/           # test-harness-only; not part of public surface
│       └── Proto/             # generated protobuf bindings
├── app/
│   └── test/
│       └── Main.hs        # daemon-substrate-test executable entrypoint
├── test/
│   ├── unit/
│   │   └── Spec.hs
│   ├── integration/
│   │   └── Spec.hs
│   └── haskell-style/
│       └── Spec.hs
└── proto/                 # .proto sources, code-generated into src/Daemon/Proto
```

## Library stanza

```cabal
library
  import:           common-opts
  exposed-modules:
      Daemon.Config
    , Daemon.Engine
    , Daemon.Lifecycle
    , Daemon.MinIO
    , Daemon.MinIO.Cache
    , Daemon.Orchestrator
    , Daemon.Pulsar
    , Daemon.Worker
    , Daemon.WorkflowState
    -- plus Daemon.Proto.* generated modules
  hs-source-dirs:   src
```

The library exposes only the modules consumers are expected to depend on. The test-harness-only
modules under `Daemon.Cluster.*` are exposed by the library for the `daemon-substrate-test`
executable's use, but consumers are not expected to import them.

## Executable stanza

```cabal
executable daemon-substrate-test
  import:           common-opts
  main-is:          Main.hs
  hs-source-dirs:   app/test
  build-depends:    daemon-substrate
  ghc-options:      -threaded -rtsopts -with-rtsopts=-N
```

This is the *only* executable in the repository. There is no `daemon-substrate` binary — the
library is consumed by name, not invoked from the command line. The `daemon-substrate-test`
executable is for the harness only.

## Test-suite stanzas

All three test suites use `exitcode-stdio-1.0`:

```cabal
test-suite daemon-substrate-unit
  type:             exitcode-stdio-1.0
  main-is:          Spec.hs
  hs-source-dirs:   test/unit
  build-depends:    daemon-substrate, hspec, ...

test-suite daemon-substrate-integration
  type:             exitcode-stdio-1.0
  main-is:          Spec.hs
  hs-source-dirs:   test/integration
  build-depends:    daemon-substrate, hspec, ...

test-suite daemon-substrate-haskell-style
  type:             exitcode-stdio-1.0
  main-is:          Spec.hs
  hs-source-dirs:   test/haskell-style
  build-depends:    daemon-substrate, ...
```

| Suite | What it exercises |
|-------|-------------------|
| `daemon-substrate-unit` | pure logic: protobuf encode / decode, `WorkflowOwner` fold, `BootConfig` decoders, cache eviction policies |
| `daemon-substrate-integration` | end-to-end with a real kind cluster brought up by `daemon-substrate-test cluster up` |
| `daemon-substrate-haskell-style` | `ormolu` and `hlint` gates run against `src/` |

The integration suite is the one that depends on a running cluster. It is invoked through
`daemon-substrate-test test integration`, which performs the cluster preflight before delegating
to `cabal test daemon-substrate-integration`.

## Why no sublibrary split

`infernix` and `jitML` both ship a single library + executables. There is no advantage to
splitting `daemon-substrate` into multiple `library` stanzas:

- consumers depend on one package name; a split would create two
- the test harness shares modules with the library (cluster bootstrap, mock engine wiring);
  splitting would require a third "harness" sublibrary that the executable depends on
- the build cost of compiling unused modules is negligible at this size

Revisit only if (a) a consumer explicitly needs to depend on a subset that does not include the
test-harness modules under `Daemon.Cluster.*`, or (b) the library grows past a threshold where
incremental rebuild times suffer.

## GHC pin and `cabal.project`

`cabal.project` pins GHC to `9.14.1` to match `infernix` and `jitML`. The
`allow-newer: *:base, *:template-haskell` carve-out is needed for Dhall's transitive CBOR
dependencies (same posture as the consumer projects).

## Cross-references

- Library surface (which modules exist): [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md)
- CLI of the test executable: [../reference/cli_surface.md](../reference/cli_surface.md)
- Testing strategy: [../development/testing_strategy.md](../development/testing_strategy.md)
