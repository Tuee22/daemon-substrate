# Local Development

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [assistant_workflow.md](assistant_workflow.md), [testing_strategy.md](testing_strategy.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md), [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)

> **Purpose**: Get a contributor from a fresh clone to a working build and a green test suite
> on supported hostbootstrap substrates.

## TL;DR

- Install `hostbootstrap` via `pipx`.
- Clone the repo.
- Run `hostbootstrap doctor` and `hostbootstrap cluster up`.
- On the AppleSilicon `HostDaemon` target, run `hostbootstrap daemon run` in a second
  foreground process after cluster bring-up.
- Use `hostbootstrap run test ...` for the selected target, or
  `./.build/daemon-substrate-test test ...` after a host-native build.
- Use `--force-target <apple-silicon|linux-cpu|linux-gpu>` to exercise another declared
  substrate on the current machine.

## Current Status

The repository supports the Haskell library, `daemon-substrate-test` executable, local Cabal
test stanzas, and live kind harness. The current hostbootstrap target map is:

| Substrate entry | Model | Normal host |
|-----------------|-------|-------------|
| `apple-silicon` | `HostDaemon` | macOS arm64 Apple Silicon |
| `linux-cpu` | `Container` | Linux without NVIDIA runtime |
| `linux-gpu` | `HostBinary` | Linux with NVIDIA runtime |

The full validation matrix remains 3×3: three target/model pairs across three ML workflow
archetypes. A complete hardware run uses three machines; `--force-target` can exercise all
three target/model pairs on one machine for local validation.

## One-time Install

Install the `pipx` prerequisite first:

- **macOS**: `brew install pipx && pipx ensurepath`
- **Ubuntu**: `sudo apt install -y pipx && pipx ensurepath`

Then install `hostbootstrap`:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

`hostbootstrap` provisions its own native `dhall-to-json` binary on first use.

## First Run

```bash
hostbootstrap doctor
hostbootstrap cluster up
hostbootstrap daemon run  # HostDaemon target only; keep this foreground process running
hostbootstrap run test unit
hostbootstrap run test integration
# Stop the foreground daemon process with Ctrl-C in its terminal before teardown.
hostbootstrap cluster down
```

On `HostBinary` and `HostDaemon` targets, the build artifact is also available directly:

```bash
./.build/daemon-substrate-test test unit
./.build/daemon-substrate-test test integration
./.build/daemon-substrate-test cluster status --model host-daemon
```

## Forced Target Loop

Use forced targets when validating the full hostbootstrap surface from one machine:

```bash
hostbootstrap cluster up --force-target apple-silicon
hostbootstrap daemon run --force-target apple-silicon
hostbootstrap run --force-target apple-silicon test integration
# Stop the foreground daemon process with Ctrl-C in its terminal before teardown.
hostbootstrap cluster down --force-target apple-silicon

hostbootstrap cluster up --force-target linux-cpu
hostbootstrap run --force-target linux-cpu test integration
hostbootstrap cluster down --force-target linux-cpu

hostbootstrap cluster up --force-target linux-gpu
hostbootstrap run --force-target linux-gpu test integration
hostbootstrap cluster down --force-target linux-gpu
```

The direct inner `--model` flag remains a debugging override for `daemon-substrate-test`
itself. Normal operator workflows select the model through `hostbootstrap`.

## Build And Test Without A Cluster

Pure local checks still work through Cabal:

```bash
cabal build all --enable-tests
cabal test daemon-substrate-unit daemon-substrate-lifecycle daemon-substrate-haskell-style
```

`daemon-substrate-integration` requires a live harness cluster brought up by `hostbootstrap
cluster up`.

## State Directories

- `./.build/`: host-native binaries, host-native kubeconfig, edge-port records, and HostDaemon
  host-native runtime records.
- `./.data/`: durable cluster state and PV-backing files.

Neither directory is checked in. `hostbootstrap cluster down` and `hostbootstrap cluster
delete` preserve `./.data/`.

## Reboot Policy

`hostbootstrap` does not install launchd/systemd units and does not create restart-after-reboot
Docker containers. After reboot:

```bash
hostbootstrap cluster up
hostbootstrap daemon run  # HostDaemon target only
```

Operators who want boot-time automation can create their own OS unit outside this repository
and outside `hostbootstrap`; that unit should supervise `hostbootstrap daemon run` directly.

## When Things Go Wrong

- `hostbootstrap run cluster status` reports known kind clusters and node readiness for the
  selected target.
- Long-running phases such as image build and dependency rollout can take minutes; wall-clock
  duration alone is not failure.
- The kubeconfig path is repo-local and does not mutate the operator's global kubeconfig. Use
  `kubectl --kubeconfig ./.build/daemon-substrate.kubeconfig get pods -A` for host-native
  targets when direct inspection is needed.
- If the cluster is wedged, use `hostbootstrap cluster down` followed by
  `hostbootstrap cluster up`. Use `hostbootstrap cluster delete` for the thorough inner
  teardown path.

## Cross-references

- hostbootstrap integration: [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md)
- Testing strategy: [testing_strategy.md](testing_strategy.md)
- Apple-specific runbook: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md)
- Linux-specific runbook: [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)
- Assistant guidance: [assistant_workflow.md](assistant_workflow.md)
