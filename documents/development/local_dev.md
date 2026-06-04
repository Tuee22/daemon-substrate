# Local Development

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [assistant_workflow.md](assistant_workflow.md), [testing_strategy.md](testing_strategy.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Get a contributor from a fresh clone to a working build and a green test suite
> on either of the two supported cohorts (Apple Silicon, Linux CPU).

## TL;DR

- Install `hostbootstrap` into host Python (one-time).
- Clone the repo.
- Run `hostbootstrap doctor` and `hostbootstrap cluster up`.
- Use `daemon-substrate-test test ...` for unit and integration coverage.

## Current Status

The current repository supports the Haskell library, `daemon-substrate-test` executable, local
Cabal test stanzas, and the live Apple Silicon kind harness through the active Phase 8 Sprint
8.6 work. Local validation is:

```bash
cabal build all --enable-tests
cabal test daemon-substrate-unit daemon-substrate-lifecycle daemon-substrate-integration daemon-substrate-haskell-style
```

Apple Silicon live `daemon-substrate-test cluster up` brings up deployable Harbor / Pulsar /
MinIO dependencies, PVC-backed state, orchestrator pods, managed edge-port forwarding, and a
host worker that completes a request -> orchestrator -> worker -> response smoke handoff.
Full `Ready` closure remains active while Linux CPU validation finishes.

## One-time install

[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) is the canonical infrastructure
layer for this repository — substrate detection, host prereqs, base image, container / daemon
lifecycle. Install it into host Python (not a project virtualenv):

```bash
python -m pip install "git+https://github.com/Tuee22/hostbootstrap.git#egg=hostbootstrap"
```

Stock Python 3.12 on macOS arm64 or Ubuntu 24.04 is sufficient. `hostbootstrap` provisions its
own native `dhall-to-json` binary on first use.

## Supported cohorts

| Cohort | Host | hostbootstrap model | Test binary location |
|--------|------|---------------------|----------------------|
| Apple Silicon | macOS arm64 | `HostDaemon` (system-scope LaunchDaemon) | `./.build/daemon-substrate-test` (built natively via `ghcup`) |
| Linux CPU | x86_64 / arm64 Linux | `Container` (`service = True`) | inside the thin project container (`FROM ${BASE_IMAGE}`) |

There is no host-native Linux workflow. Linux contributors always go through the outer
container.

## First-run prerequisites

`hostbootstrap doctor` detects the substrate and idempotently installs the host prereqs.

### Apple Silicon

`hostbootstrap doctor` verifies / installs:

- Homebrew
- `ghcup` and GHC 9.12
- Cabal (paired with the GHC pin)
- Colima (the only supported Docker environment on Apple Silicon)

See [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md) for the
full prerequisite list and the manual steps the tool cannot do (Apple ID, Homebrew install).

### Linux CPU

`hostbootstrap doctor` verifies / installs:

- Docker Engine with the Compose plugin
- `docker buildx`
- User-namespace access to `/var/run/docker.sock`

See [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md) for the full
prerequisite list. GHC, Cabal, `kubectl`, `helm`, `kind`, and `protoc` are baked into the
`hostbootstrap` base image; no host-level Haskell toolchain is required.

## Build and test loop

### Apple Silicon

```bash
hostbootstrap doctor                                        # one-time: install prereqs
hostbootstrap cluster up                                    # build binary, install LaunchDaemon, bring kind cluster up
./.build/daemon-substrate-test test unit
./.build/daemon-substrate-test test integration
./.build/daemon-substrate-test cluster status
hostbootstrap cluster down                                  # tear down; preserves ./.data/
```

After the first bring-up, `./.build/daemon-substrate-test ...` is the canonical command
surface for the test commands. `hostbootstrap` is only invoked when the LaunchDaemon or
prerequisites change.

### Linux CPU

```bash
hostbootstrap doctor
hostbootstrap cluster up
hostbootstrap run daemon-substrate-test test unit
hostbootstrap run daemon-substrate-test test integration
hostbootstrap run daemon-substrate-test cluster status
hostbootstrap cluster down
```

`hostbootstrap run <cmd...>` dispatches into the project container, which carries the
toolchain (from the base image) and the compiled `daemon-substrate-test` binary.

## What's in `./.build/` and `./.data/`

- `./.build/` (Apple only): the compiled `daemon-substrate-test` binary, the staged Dhall
  configs, the kubeconfig (`daemon-substrate.kubeconfig`), and the chosen edge port
  (`edge-port.json`).
- `./.data/`: durable cluster state (PV-backing files), runtime state (Pulsar / MinIO / Harbor
  data). On Linux this is the only bind mount into the project container.

Neither directory is checked in. `hostbootstrap cluster down` preserves both so a fresh `up`
is fast; `hostbootstrap cluster delete` (thorough teardown) also preserves `./.data/`.

## When things go wrong

- `daemon-substrate-test cluster status` currently reports known kind clusters and node
  readiness. The target lifecycle phase / heartbeat report lands with the full `Ready` gate.
  Long-running phases such as image build and dependency rollout can take minutes; wall-clock
  duration alone is not failure.
- The kubeconfig path is repo-local — your shell's `~/.kube/config` is never modified. To run
  `kubectl` directly: `KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get pods -A`
  (Apple) or via `hostbootstrap run` on Linux.
- If the cluster gets into a wedged state, `daemon-substrate-test cluster down` followed by
  `daemon-substrate-test cluster up` is the inner reset switch; `hostbootstrap cluster down`
  followed by `hostbootstrap cluster up` is the outer reset. `./.data/` is preserved across
  both.

## Cross-references

- Current status: the executable parser, Cabal test stanzas, live cluster runner
  interpreters, deployable dependency charts, PVC-backed Apple kind state, and live service
  loops are implemented. Remaining live validation is tracked by
  `DEVELOPMENT_PLAN/phase-7-hostbootstrap-and-project-dockerfile.md` Sprint 7.3 and
  `DEVELOPMENT_PLAN/phase-8-test-harness-integration.md` Sprint 8.6.
- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Testing strategy: [testing_strategy.md](testing_strategy.md)
- Apple-specific runbook: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md)
- Linux-specific runbook: [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)
- Assistant guidance: [assistant_workflow.md](assistant_workflow.md)
