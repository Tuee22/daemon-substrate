# Local Development

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [assistant_workflow.md](assistant_workflow.md), [testing_strategy.md](testing_strategy.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Get a contributor from a fresh clone to a working build and a green test suite
> on either of the two supported cohorts (Apple Silicon, Linux CPU).

## TL;DR

- Install `hostbootstrap` via `pipx` (one-time).
- Clone the repo.
- Run `hostbootstrap doctor` and `hostbootstrap cluster up` (model selected by `--spec`).
- Use `daemon-substrate-test test ...` for unit and integration coverage.

## Current Status

The current repository supports the Haskell library, `daemon-substrate-test` executable, local
Cabal test stanzas, and the live kind harness on both supported cohorts. Local validation is:

```bash
cabal build all --enable-tests
cabal test daemon-substrate-unit daemon-substrate-lifecycle daemon-substrate-integration daemon-substrate-haskell-style
```

Apple Silicon live `daemon-substrate-test cluster up` brings up deployable Harbor / Pulsar /
MinIO dependencies, PVC-backed state, orchestrator pods, managed edge-port forwarding, and a
host worker that completes a request -> orchestrator -> worker -> response smoke handoff.
Linux live `hostbootstrap cluster up` brings up the outer service container, inner kind
cluster, Harbor / Pulsar / MinIO dependencies, orchestrator and worker Deployments,
retained PVCs, and the live integration readiness gate.

## One-time install

[`hostbootstrap`](https://github.com/Tuee22/hostbootstrap) is the canonical infrastructure
layer for this repository — host detection, host prereqs, base image, and the Container /
HostBinary / HostDaemon execution models. Install it via `pipx` only.

Install the `pipx` prereq first:

- **macOS**: `brew install pipx && pipx ensurepath`
- **Ubuntu**: `sudo apt install -y pipx && pipx ensurepath`

Then install `hostbootstrap`:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

Stock Python 3.12 on macOS arm64 or Ubuntu 24.04 is sufficient. `hostbootstrap` provisions its
own native `dhall-to-json` binary on first use.

## One CPU target, three execution models

`daemon-substrate` is CPU-only, so it declares a single `H.Accel.Cpu` target that
`hostbootstrap` matches to every host by capability subsumption (`apple-silicon` →
`{ Cpu, Metal }`, `linux-cpu` → `{ Cpu }`, `linux-gpu` → `{ Cpu, Cuda }`). The execution model
is chosen by **spec file**, not by host:

| Spec (`--spec`) | Model | Test binary location |
|-----------------|-------|----------------------|
| `hostbootstrap.dhall` (default) | `Container` | inside the thin project container (`FROM ${BASE_IMAGE}`) |
| `hostbootstrap-hostbinary.dhall` | `HostBinary` | `./.build/daemon-substrate-test` (built natively) |
| `hostbootstrap-hostdaemon.dhall` | `HostDaemon` | `./.build/daemon-substrate-test` run as a managed launchd (Apple) / systemd (Linux) service |

The harness target is the full **3×3 matrix**: each model exercising each of three ML workflow
archetypes — continuous batched inference (≈ `infernix`), finite SL / offline-RL training jobs
(≈ `jitML`), and continuous online RL. `daemon-substrate` is the reference scaffolding for both
consumers. See [testing_strategy.md](testing_strategy.md).

## First-run prerequisites

`hostbootstrap doctor` detects the substrate and idempotently installs the host prereqs.

### Apple Silicon

`hostbootstrap doctor` verifies / installs:

- Homebrew
- `ghcup` and `ghc-9.12.4`
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
prerequisite list. `ghc-9.12.4`, Cabal, `kubectl`, `helm`, `kind`, and `protoc` are baked into
the `hostbootstrap` base image; no host-level Haskell toolchain is required for the `Container`
model.

## Build and test loop

### `Container` model (default)

```bash
hostbootstrap doctor
hostbootstrap cluster up
hostbootstrap run test unit
hostbootstrap run test integration
hostbootstrap run cluster status --model container
hostbootstrap cluster down
```

`hostbootstrap run <cmd...>` dispatches into the project container, which carries the
toolchain (from the base image) and the compiled `daemon-substrate-test` binary.

### `HostDaemon` / `HostBinary` models (native host build)

```bash
hostbootstrap doctor                                              # one-time: install prereqs
hostbootstrap cluster up --spec hostbootstrap-hostdaemon.dhall    # build binary, install managed service, bring kind cluster up
./.build/daemon-substrate-test test unit
./.build/daemon-substrate-test test integration
./.build/daemon-substrate-test cluster status
hostbootstrap cluster down --spec hostbootstrap-hostdaemon.dhall  # tear down; preserves ./.data/
```

After the first bring-up, `./.build/daemon-substrate-test ...` is the canonical command
surface for the test commands. `hostbootstrap` is only invoked when the managed service or
prerequisites change.

## What's in `./.build/` and `./.data/`

- `./.build/` (native `HostBinary` / `HostDaemon` builds): the compiled
  `daemon-substrate-test` binary, the staged Dhall configs, the kubeconfig
  (`daemon-substrate.kubeconfig`), and the chosen edge port (`edge-port.json`).
- `./.data/`: durable cluster state (PV-backing files), runtime state (Pulsar / MinIO / Harbor
  data). Under the `Container` model this is the only bind mount into the project container.

Neither directory is checked in. `hostbootstrap cluster down` preserves both so a fresh `up`
is fast; `hostbootstrap cluster delete` (thorough teardown) also preserves `./.data/`.

## When things go wrong

- `daemon-substrate-test cluster status` currently reports known kind clusters and node
  readiness. Lifecycle phase / heartbeat detail remains target telemetry. Long-running
  phases such as image build and dependency rollout can take minutes; wall-clock duration
  alone is not failure.
- The kubeconfig path is repo-local — your shell's `~/.kube/config` is never modified. To run
  `kubectl` directly: `KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get pods -A`
  (Apple) or via `hostbootstrap run` on Linux.
- If the cluster gets into a wedged state, `daemon-substrate-test cluster down` followed by
  `daemon-substrate-test cluster up` is the inner reset switch; `hostbootstrap cluster down`
  followed by `hostbootstrap cluster up` is the outer reset. `./.data/` is preserved across
  both.

## Cross-references

- Current status: the executable parser, Cabal test stanzas, live cluster runner
  interpreters, deployable dependency charts, PVC-backed kind state, live service loops, and
  both-cohort readiness validation are implemented.
- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Testing strategy: [testing_strategy.md](testing_strategy.md)
- Apple-specific runbook: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md)
- Linux-specific runbook: [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)
- Assistant guidance: [assistant_workflow.md](assistant_workflow.md)
