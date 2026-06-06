# Phase 6: Cluster Bring-up Tree (Kind / Helm / Harbor / Pulsar / MinIO / Workload / EdgePort)

**Status**: Authoritative source
**Supersedes**: `phase-6-bootstrap-and-outer-container.md` (the hostbootstrap-wiring work moves to Phase 7 in the re-baselined plan)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-base-loops.md](phase-5-base-loops.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the cluster bring-up tree (`src/Daemon/Cluster/*`), the `chart/` directory
> with Harbor / Pulsar / MinIO chart dependencies and the orchestrator / worker Deployment
> templates, and the `dhall/` configs for both roles. After this phase, the inner
> `daemon-substrate-test cluster up` reconciler is real.

## Phase Status

**Status**: Active
**Implementation**: Sprints 6.1, 6.2, and 6.3 are implemented and validated, but the
worker-cardinality and Harbor-publication contract was corrected after closure.

### Remaining Work

- Replace the old two-worker in-cluster harness topology with exactly one worker per matrix
  case. The worker owns the resources of the whole node whether it runs in-cluster or as a
  host daemon.
- Replace the direct kind image-load publication path with per-cluster Harbor deployment plus
  harness image upload. The host/project artifact may be reused, but each fresh cluster must
  receive its own Harbor deployment and image upload.

## Phase Objective

Make `daemon-substrate-test cluster up` real. After this phase, the inner reconciler — running
inside the project container on Linux CPU or on the host on Apple Silicon — can bring up a
kind cluster with Harbor, Pulsar, MinIO, the orchestrator Deployment, and (on Linux) the
worker Deployment, in the topology described in
[`../documents/engineering/cluster_topology.md`](../documents/engineering/cluster_topology.md).

The outer `hostbootstrap cluster up` wiring lands in Phase 7.

## Sprints

### Sprint 6.1: Cluster lifecycle Haskell modules [Done]

**Status**: Done
**Implementation**: `src/Daemon/Cluster/Types.hs`, `src/Daemon/Cluster/Kind.hs`,
`src/Daemon/Cluster/Storage.hs`, `src/Daemon/Cluster/Helm.hs`,
`src/Daemon/Cluster/Harbor.hs`, `src/Daemon/Cluster/Pulsar.hs`,
`src/Daemon/Cluster/MinIO.hs`, `src/Daemon/Cluster/Workload.hs`,
`src/Daemon/Cluster/EdgePort.hs`, `src/Daemon/Cluster/Plan.hs`, `daemon-substrate.cabal`,
`test/unit/Main.hs`
**Docs to update**: `documents/engineering/cluster_topology.md`,
`documents/operations/cluster_bootstrap_runbook.md`, `system-components.md`

#### Objective

Land `src/Daemon/Cluster/*` modules: kind cluster create / delete, kubeconfig export, manual
StorageClass + PV reconciliation, Helm dependency build, Harbor bootstrap, Pulsar bootstrap,
MinIO bootstrap + bucket seeding, ConfigMap render, orchestrator / worker Deployment apply,
edge port discovery.

#### Deliverables

- `src/Daemon/Cluster/Kind.hs` (cluster create/delete/status)
- `src/Daemon/Cluster/Storage.hs` (manual StorageClass + PV reconciliation)
- `src/Daemon/Cluster/Helm.hs` (phased Helm release rollout)
- `src/Daemon/Cluster/Harbor.hs` (Harbor bootstrap + image publication)
- `src/Daemon/Cluster/Pulsar.hs` (Pulsar broker install + tenant / namespace setup)
- `src/Daemon/Cluster/MinIO.hs` (MinIO install + bucket seeding)
- `src/Daemon/Cluster/Workload.hs` (orchestrator / worker Deployment apply)
- `src/Daemon/Cluster/EdgePort.hs` (port discovery + persistence)
- `src/Daemon/Cluster/Types.hs` and `src/Daemon/Cluster/Plan.hs` (shared action vocabulary and
  ordered bring-up / status / teardown plans)

#### Validation

Validated with:

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`

Unit tests cover the plan-generation logic: phase ordering, Linux vs Apple worker placement,
worker anti-affinity rendering, and edge-port selection. Live cluster bring-up is validated in
Phase 8.

### Sprint 6.2: Helm chart [Done]

**Status**: Done
**Implementation**: `chart/Chart.yaml`, `chart/values.yaml`,
`chart/values/apple-silicon.yaml`, `chart/values/linux-cpu.yaml`, `chart/templates/*.yaml`,
`chart/charts/harbor/*`, `chart/charts/pulsar/*`, `chart/charts/minio/*`
**Docs to update**: `documents/engineering/cluster_topology.md`, `system-components.md`

#### Objective

Land `chart/` with `Chart.yaml`, `values.yaml`, per-cohort values overrides, and the deployment
templates.

#### Deliverables

- `chart/Chart.yaml` declaring Harbor / Pulsar / MinIO chart dependencies
- `chart/values.yaml` with `orchestrator.replicas` (default `2`, no anti-affinity),
  `worker.enabled`, `worker.replicas` (default `2`), worker anti-affinity defaults, per-
  component resource requests, and the WAN-egress NetworkPolicy stanza permitting only
  orchestrator pods to reach external networks
- `chart/values/apple-silicon.yaml` overriding `worker.enabled: false`
- `chart/values/linux-cpu.yaml` overriding `worker.enabled: true`, `worker.replicas: 2`
- `chart/templates/deployment-orchestrator.yaml`
- `chart/templates/deployment-worker.yaml` (conditional on `worker.enabled`)
- `chart/templates/configmap-orchestrator.yaml`, `configmap-worker.yaml`
- `chart/templates/service-*.yaml` as needed for in-cluster reachability

#### Validation

Validated with:

- `helm template daemon-substrate-test ./chart -f chart/values/linux-cpu.yaml`
- `helm template daemon-substrate-test ./chart -f chart/values/apple-silicon.yaml`
- render assertion that the Linux CPU cohort includes the worker Deployment and
  `podAntiAffinity`, while the Apple Silicon cohort omits the worker Deployment

The chart uses local Harbor / Pulsar / MinIO dependency charts so render validation is
deterministic and does not require network chart repositories.

Sprint 6.4 supersedes the two-worker default above with the corrected one-worker topology.

### Sprint 6.3: Dhall configs for orchestrator and worker [Done]

**Status**: Done
**Implementation**: `dhall/orchestrator.dhall`, `dhall/worker.dhall`, `dhall/live.dhall`,
`dhall/lifecycle-policy.dhall`, `chart/files/orchestrator.dhall`, `chart/files/worker.dhall`,
`chart/files/live.dhall`, `chart/files/lifecycle-policy.dhall`, `chart/templates/configmap-*.yaml`,
`test/unit/Main.hs`
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Land the test-harness Dhall configs the orchestrator and worker each consume.

#### Deliverables

- `dhall/orchestrator.dhall` (`BootConfig Orchestrator app` + `LiveConfig` + `LifecyclePolicy`)
  with Pulsar / MinIO endpoints, upstream topic set, fan-out topic set, and a `LifecyclePolicy`
  declaring at least one topic in each of the four `TopicLifecycle` modes plus the
  test-harness `BucketLifecycle` with `orphanScan = EveryHours` (short interval + tight safety
  window for integration tests)
- `dhall/worker.dhall` (`BootConfig Worker app` + `LiveConfig`) with Pulsar / MinIO endpoints,
  cohort tag, cache directory

#### Validation

Validated with:

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- `helm template daemon-substrate-test ./chart -f chart/values/linux-cpu.yaml`
- `helm template daemon-substrate-test ./chart -f chart/values/apple-silicon.yaml`
- render assertion that the chart packages `orchestrator.dhall`, `worker.dhall`, `live.dhall`,
  and `lifecycle-policy.dhall`

Live service boot against a running cluster is validated in Phase 8, when the
`daemon-substrate-test` executable and integration harness land.

### Sprint 6.4: Single-worker topology and Harbor upload path [Active]

**Status**: Active
**Implementation**: `src/Daemon/Cluster/Workload.hs`, `src/Daemon/Cluster/Harbor.hs`,
`src/Daemon/Cluster/Runner.hs`, `chart/values.yaml`, `chart/values/linux-cpu.yaml`,
`chart/templates/deployment-worker.yaml`, `test/unit/Main.hs`
**Docs to update**: `../documents/engineering/cluster_topology.md`,
`../documents/development/testing_strategy.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Correct the cluster topology for the executable 3x3 integration suite. Each matrix case has
one coordinator/orchestrator Deployment with two replicas and exactly one worker. In-cluster
worker models deploy one worker pod; `HostDaemon` starts one foreground host worker process.
Every fresh cluster deploys Harbor and receives the harness image through Harbor before the
coordinator and worker workloads roll out.

#### Deliverables

- chart defaults and per-cohort overrides set worker `replicas: 1`
- Haskell workload-plan defaults and unit tests expect exactly one in-cluster worker
- worker anti-affinity remains allowed but is no longer used to validate multi-worker split
- Harbor publication action uploads/tags the already-built harness image through the fresh
  cluster's Harbor deployment instead of relying on direct kind image-load as the target
  publication behavior
- documentation and legacy ledger entries record that the old two-worker and direct-kind-load
  surfaces are obsolete

#### Validation

- `cabal build all --enable-tests`
- `cabal test daemon-substrate-unit daemon-substrate-haskell-style`
- `helm template daemon-substrate-test ./chart -f chart/values/linux-cpu.yaml`
- `helm template daemon-substrate-test ./chart -f chart/values/apple-silicon.yaml`
- unit assertions prove one worker Deployment for in-cluster models and no worker Deployment
  for host-daemon models

#### Remaining Work

Sprint 6.4 is not implemented in the current repo state. The existing chart and Haskell
defaults still contain the old two-worker topology and direct kind image-load publication path.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/cluster_topology.md` updates from "planned" to current-state.

**Reference docs to create/update:**
- none unique to this phase.

**Operations docs to create/update:**
- `documents/operations/cluster_bootstrap_runbook.md` updates from forward-looking to
  current-state as cluster bring-up becomes real.

**Cross-references to add:**
- `system-components.md` flips chart-workload rows and the cluster-orchestration module rows
  to `Implemented: yes`.
