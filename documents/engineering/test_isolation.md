# Test Isolation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [hostbootstrap_integration.md](hostbootstrap_integration.md), [cluster_topology.md](cluster_topology.md), [dhall_generation.md](dhall_generation.md), [../development/testing_strategy.md](../development/testing_strategy.md), [../reference/cli_surface.md](../reference/cli_surface.md), [../operations/cluster_bootstrap_runbook.md](../operations/cluster_bootstrap_runbook.md)

> **Purpose**: Define the test-isolation invariants of the executable 3x3 harness — the
> `ClusterProfile` distinction, `.test_data/<case>` isolation, test-scoped cluster names,
> guaranteed teardown, the `dst-test-` delete-guard, and the never-touch-production rule.

## TL;DR

- A **`ClusterProfile`** distinguishes **`ProductionProfile`** (data root `./.data`, fixed
  cluster name `daemon-substrate-<cohort>`) from **`TestProfile`** (data root
  `./.test_data/<case>`, test-scoped cluster name `dst-test-<model>-<archetype>`).
- One `daemon-substrate-test test integration` invocation creates and tears down **nine
  isolated test clusters**, one per matrix case, recursively invoking `hostbootstrap` per case.
- **Teardown is guaranteed.** Each case's cluster is torn down in a `finally` handler so a failed
  assertion never leaks a cluster.
- A **`dst-test-` prefix delete-guard** ensures teardown only ever deletes test-scoped clusters.
  A name that does not start with `dst-test-` is refused as a teardown target.
- Production `.data` and any production cluster are **never touched** by the test harness.

## `ClusterProfile`

`ClusterProfile` is the single switch that selects every name and path the harness derives. It is
a test-harness concept only; the substrate-agnostic library under `src/Daemon/*` never sees it.

| Profile | Data root | Cluster name | Used by |
|---------|-----------|--------------|---------|
| `ProductionProfile` | `./.data` | `daemon-substrate-<cohort>` | `cluster up/down` for a real cohort |
| `TestProfile` | `./.test_data/<case>` | `dst-test-<model>-<archetype>` | each of the nine integration cases |

Cluster-name and host-path derivation is **centralized** behind `ClusterProfile`. There are no
duplicate ad-hoc name/path computations elsewhere; the profile is the only input, so a test path
can never resolve to a production name and vice versa. The generated per-case Dhall carries the
`TestProfile` name and path for its case; see [dhall_generation.md](dhall_generation.md).

## `.test_data/<case>` isolation

Every test case gets its own workspace under `./.test_data/<case>/`:

- the generated per-case test Dhall
- the kind data mount and PV-backing files for that case's cluster
- the case's edge-port record and any `kubectl port-forward` pids

Cases never share a data root, so concurrent or sequential cases cannot read or clobber each
other's state, and a failed case's residue stays inside its own `.test_data/<case>/` directory.
Production durable state lives only under `./.data` and is outside every case workspace.

## Guaranteed teardown

The integration runner wraps each case in a `finally` so teardown runs even when an assertion
throws:

1. generate the per-case test Dhall (`TestProfile`)
2. recursively invoke `hostbootstrap` to bring up `dst-test-<model>-<archetype>`
3. run the case assertions
4. **`finally`**: tear down the case cluster and reconcile its `.test_data/<case>/` workspace

No case is allowed to leave a live cluster behind for the next case. `test all` and
`test integration` therefore never require — and never assume — a preexisting cluster.

## The `dst-test-` delete-guard

Teardown is the only destructive path the harness runs, and it is guarded:

- the teardown verb refuses any cluster name that does not start with `dst-test-`
- the fixed production name `daemon-substrate-<cohort>` does not match the prefix, so the harness
  cannot delete a production cluster even if a generated name were corrupted
- `./.data` is never a teardown target; only `./.test_data/<case>/` workspaces are reconciled away

This makes "never delete production" a mechanical invariant rather than a convention: the only
clusters the harness can destroy are the `dst-test-`-prefixed ones it created.

## Never touch production

Combining the rules above:

- the test harness only ever **creates** `dst-test-` clusters and only ever **deletes**
  `dst-test-` clusters
- the test harness only ever **reads or writes** under `./.test_data/<case>/`
- `ProductionProfile` (`./.data`, `daemon-substrate-<cohort>`) is reachable only from the operator
  `cluster up/down` path, never from `test integration`

An operator can therefore run the full nine-case matrix on the same host as a live production
cluster without risk to production `.data` or the production cluster.

## Cross-references

- Ownership boundary and recursive per-case invocation: [hostbootstrap_integration.md](hostbootstrap_integration.md)
- Per-case Dhall generation: [dhall_generation.md](dhall_generation.md)
- Single-worker-per-case topology: [cluster_topology.md](cluster_topology.md)
- Executable 3x3 contract: [../development/testing_strategy.md](../development/testing_strategy.md)
- `test integration` command behavior: [../reference/cli_surface.md](../reference/cli_surface.md)
