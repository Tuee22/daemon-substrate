# Local Development

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [assistant_workflow.md](assistant_workflow.md), [testing_strategy.md](testing_strategy.md), [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md), [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)

> **Purpose**: Get a contributor from a fresh clone to a working build and a green test suite
> on either of the two supported cohorts (Apple Silicon, Linux CPU).

## TL;DR

- Clone the repo.
- Run the supported bootstrap script for your host.
- The first run installs prerequisites, builds the test binary or launcher image, and brings
  up the kind cluster. Subsequent runs reconcile.
- Use `daemon-substrate-test test ...` for unit and integration coverage.

## Supported cohorts

| Cohort | Host | Bootstrap script | Test binary location |
|--------|------|------------------|----------------------|
| Apple Silicon | macOS arm64 | `./bootstrap/apple-silicon.sh up` | `./.build/daemon-substrate-test` |
| Linux CPU | x86_64 / arm64 Linux | `./bootstrap/linux-cpu.sh up` | inside the `daemon-substrate-linux-cpu:local` container |

There is no host-native Linux workflow. Linux contributors always go through the outer
container.

## First-run prerequisites

### Apple Silicon

The bootstrap script verifies and (where possible) installs:

- Homebrew
- `ghcup` and GHC 9.14.1
- `cabal` 3.16.1.0
- `protoc` (for protobuf code generation)
- Docker via Colima (for the in-cluster Harbor / Pulsar / MinIO images)

See [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md) for the
full prerequisite list and the manual steps the script cannot do for you (Apple ID, Homebrew
install, etc.).

### Linux CPU

The bootstrap script verifies and (where possible) installs:

- Docker Engine with the Compose plugin
- `docker buildx` for image building
- User-namespace access to `/var/run/docker.sock`

See [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md) for full
prerequisite list.

## Build and test loop

### Apple Silicon

```bash
./bootstrap/apple-silicon.sh up        # one-time: install prereqs, build binary, bring cluster up
./.build/daemon-substrate-test test unit
./.build/daemon-substrate-test test integration
./.build/daemon-substrate-test cluster status
./bootstrap/apple-silicon.sh down      # tear cluster down (preserves ./.data/, ./.build/)
```

After the first bring-up, `./.build/daemon-substrate-test ...` is the canonical command
surface. The bootstrap script is only needed when prerequisites change.

### Linux CPU

```bash
./bootstrap/linux-cpu.sh up
docker compose run --rm daemon-substrate daemon-substrate-test test unit
docker compose run --rm daemon-substrate daemon-substrate-test test integration
docker compose run --rm daemon-substrate daemon-substrate-test cluster status
./bootstrap/linux-cpu.sh down
```

Always invoke through `docker compose run --rm`. The container has the launcher image, the
GHC toolchain, and the kind binary.

## What's in `./.build/` and `./.data/`

- `./.build/` (Apple only): the compiled `daemon-substrate-test` binary, the staged Dhall
  configs, the kubeconfig (`daemon-substrate.kubeconfig`), and the chosen edge port
  (`edge-port.json`).
- `./.data/`: durable cluster state (PV-backing files), runtime state (Pulsar / MinIO / Harbor
  data). On Linux this is the only bind mount into the launcher container.

Neither directory is checked in. Bootstrap `down` preserves both so a fresh `up` is fast.

## When things go wrong

- `daemon-substrate-test cluster status` reports the current lifecycle phase and the heartbeat
  timestamp. Long-running phases (image build, Harbor publication) refresh the heartbeat
  roughly every 30 seconds; wall-clock duration alone is not failure.
- The kubeconfig path is repo-local — your shell's `~/.kube/config` is never modified. To run
  `kubectl` directly: `KUBECONFIG=./.build/daemon-substrate.kubeconfig kubectl get pods -A`
  (Apple) or via the launcher container on Linux.
- If the cluster gets into a wedged state, `daemon-substrate-test cluster down` followed by
  `daemon-substrate-test cluster up` is the reset switch. `./.data/` is preserved across that
  cycle.

## Cross-references

- Testing strategy: [testing_strategy.md](testing_strategy.md)
- Apple-specific runbook: [../operations/apple_silicon_runbook.md](../operations/apple_silicon_runbook.md)
- Linux-specific runbook: [../operations/linux_cpu_runbook.md](../operations/linux_cpu_runbook.md)
- Assistant guidance: [assistant_workflow.md](assistant_workflow.md)
