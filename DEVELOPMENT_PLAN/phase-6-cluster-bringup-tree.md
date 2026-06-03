# Phase 6: Cluster Bring-up Tree (Kind / Helm / Harbor / Pulsar / MinIO / Workload / EdgePort)

**Status**: Authoritative source
**Supersedes**: `phase-6-bootstrap-and-outer-container.md` (the hostbootstrap-wiring work moves to Phase 7 in the re-baselined plan)
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-base-loops.md](phase-5-base-loops.md), [phase-7-hostbootstrap-and-project-dockerfile.md](phase-7-hostbootstrap-and-project-dockerfile.md)

> **Purpose**: Land the cluster bring-up tree (`src/Daemon/Cluster/*`), the `chart/` directory
> with Harbor / Pulsar / MinIO chart dependencies and the orchestrator / worker Deployment
> templates, and the `dhall/` configs for both roles. After this phase, the inner
> `daemon-substrate-test cluster up` reconciler is real.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 5
**Implementation**: none yet

## Phase Objective

Make `daemon-substrate-test cluster up` real. After this phase, the inner reconciler — running
inside the project container on Linux CPU or on the host on Apple Silicon — can bring up a
kind cluster with Harbor, Pulsar, MinIO, the orchestrator Deployment, and (on Linux) the
worker Deployment, in the topology described in
[`../documents/engineering/cluster_topology.md`](../documents/engineering/cluster_topology.md).

The outer `hostbootstrap cluster up` wiring lands in Phase 7.

## Sprints

### Sprint 6.1: Cluster lifecycle Haskell modules [Planned]

**Status**: Planned
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

#### Validation

Unit tests cover the plan-generation logic (which `kubectl` invocations in which order). Live
cluster bring-up validated in Phase 8.

### Sprint 6.2: Helm chart [Planned]

**Status**: Planned
**Blocked by**: 6.1
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

`helm template ./chart -f chart/values/linux-cpu.yaml` and `-f chart/values/apple-silicon.yaml`
both produce valid YAML; the worker Deployment renders only for the linux-cpu values.

### Sprint 6.3: Dhall configs for orchestrator and worker [Planned]

**Status**: Planned
**Blocked by**: 6.1, 6.2
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

`daemon-substrate-test service --role orchestrator --config dhall/orchestrator.dhall` boots
through `Load → Prereq → Acquire → Ready → Serve` against a running cluster. Same for worker.

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
