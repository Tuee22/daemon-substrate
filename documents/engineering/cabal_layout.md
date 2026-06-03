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
- Four test-suite stanzas: `daemon-substrate-unit`, `daemon-substrate-lifecycle`,
  `daemon-substrate-integration`, `daemon-substrate-haskell-style`. All use
  `type: exitcode-stdio-1.0`.
- No sublibrary split, no separate `internal` package. Consumers depend on the top-level
  library only.

## Package shape

```
daemon-substrate/
├── daemon-substrate.cabal
├── cabal.project          # GHC pin (9.12, matching hostbootstrap base), allow-newer carve-outs
├── src/                   # library sources
│   └── Daemon/
│       ├── Sub.hs              # typed Subprocess + runStreaming (single shell-out seam)
│       ├── Pulsar.hs           # HasPulsar
│       ├── Pulsar/Admin.hs     # typed Pulsar admin operations
│       ├── MinIO.hs            # HasMinIO
│       ├── MinIO/Cache.hs      # ephemeral cache wrapper
│       ├── MinIO/Store.hs      # content-addressed blob/manifest/pointer + CAS
│       ├── MinIO/Admin.hs      # typed bucket admin operations
│       ├── Harbor.hs           # HasHarbor
│       ├── Kubectl.hs          # HasKubectl
│       ├── Engine.hs           # HasEngine + SubprocessEngine/NativeEngine variants
│       ├── Config/
│       │   ├── BootConfig.hs
│       │   ├── LiveConfig.hs
│       │   └── LifecyclePolicy.hs
│       ├── Lifecycle.hs        # 7-phase machine + runService entry
│       ├── Signal.hs           # SIGHUP/SIGTERM/SIGINT handling
│       ├── Audit.hs            # compacted-topic helper
│       ├── Consumer.hs         # consumer-batch primitive + dedup
│       ├── Worker.hs           # runWorker base loop
│       ├── Orchestrator.hs     # runOrchestrator base loop
│       ├── Bridge.hs           # runBridge base loop
│       ├── Bootstrap.hs        # runFanInBootstrap base loop
│       ├── Reconciler.hs       # runReconciler base loop (leader-elected lifecycle)
│       ├── WorkflowState.hs
│       ├── Cluster/            # test-harness-only; not part of public surface
│       │   ├── Kind.hs
│       │   ├── Storage.hs
│       │   ├── Helm.hs
│       │   ├── Harbor.hs
│       │   ├── Pulsar.hs
│       │   ├── MinIO.hs
│       │   ├── Workload.hs
│       │   └── EdgePort.hs
│       ├── Test/               # exposed for daemon-substrate-test; not consumer-facing
│       │   ├── FilesystemPulsar.hs
│       │   ├── FilesystemMinIO.hs
│       │   ├── FilesystemHarbor.hs
│       │   ├── FilesystemKubectl.hs
│       │   └── MockEngine.hs
│       └── Proto/              # generated protobuf bindings
├── app/
│   └── test/
│       └── Main.hs        # daemon-substrate-test executable entrypoint
├── test/
│   ├── unit/
│   │   └── Spec.hs
│   ├── lifecycle/
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

All four test suites use `exitcode-stdio-1.0`:

```cabal
test-suite daemon-substrate-unit
  type:             exitcode-stdio-1.0
  main-is:          Spec.hs
  hs-source-dirs:   test/unit
  build-depends:    daemon-substrate, hspec, ...

test-suite daemon-substrate-lifecycle
  type:             exitcode-stdio-1.0
  main-is:          Spec.hs
  hs-source-dirs:   test/lifecycle
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
| `daemon-substrate-unit` | pure logic: protobuf encode / decode, `WorkflowOwner` fold, `BootConfig` / `LiveConfig` / `LifecyclePolicy` decoders, cache eviction policies, `Store` semantics over `FilesystemMinIO`, `Consumer` dedup over `FilesystemPulsar`, reconciler tick over filesystem backends |
| `daemon-substrate-lifecycle` | daemon spawned as a real process; SIGHUP / SIGTERM / SIGINT exercised; `/readyz` polled; `LiveConfig` reload validated. No cluster needed. |
| `daemon-substrate-integration` | end-to-end with a real kind cluster brought up by `hostbootstrap cluster up` (delegating inward to `daemon-substrate-test cluster up`) |
| `daemon-substrate-haskell-style` | `ormolu` and `hlint` gates run against `src/`, plus the doc validator |

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

`cabal.project` pins GHC to `9.12` to match the [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap)
base image (`docker.io/tuee22/hostbootstrap:basecontainer-cpu-*`) and the GHC consumed by
`infernix` and `jitML`. The `allow-newer: *:base, *:template-haskell` carve-out is needed for
Dhall's transitive CBOR dependencies (same posture as the consumer projects).

The base image ships a warm Haskell store with the common build dependencies pre-resolved, so
the project container build only compiles `daemon-substrate`'s own modules. See
[hostbootstrap_integration.md](hostbootstrap_integration.md) for the integration shape.

## Cross-references

- Library surface (which modules exist): [../architecture/library_consumption_model.md](../architecture/library_consumption_model.md)
- CLI of the test executable: [../reference/cli_surface.md](../reference/cli_surface.md)
- Testing strategy: [../development/testing_strategy.md](../development/testing_strategy.md)
- hostbootstrap integration: [hostbootstrap_integration.md](hostbootstrap_integration.md)
