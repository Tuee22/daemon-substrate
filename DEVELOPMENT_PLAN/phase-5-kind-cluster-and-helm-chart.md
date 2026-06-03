# Phase 5: Kind Cluster and Helm Chart

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-worker-and-orchestrator-base-loops.md](phase-4-worker-and-orchestrator-base-loops.md), [phase-6-bootstrap-and-outer-container.md](phase-6-bootstrap-and-outer-container.md)

> **Purpose**: Land the kind cluster orchestration code (`src/Daemon/Cluster/*`), the
> `chart/` directory with Harbor / Pulsar / MinIO / orchestrator / worker deployments, and
> the `dhall/` configs for both roles.

## Phase Status

**Status**: Blocked
**Blocked by**: Phase 4
**Implementation**: none yet

## Phase Objective

Make `daemon-substrate-test cluster up` real. After this phase, the operator can bring up a
kind cluster with all five workloads (Harbor, Pulsar, MinIO, orchestrator, worker on Linux)
through a single CLI invocation, and the cluster is the exact topology described in
[`../documents/engineering/cluster_topology.md`](../documents/engineering/cluster_topology.md).

This is the first phase where the cohort split (`apple-silicon` vs `linux-cpu`) becomes
visible in the implementation: the worker Deployment is conditionally rendered, the worker
Dhall config differs slightly.

## Sprints

### Sprint 5.1: Cluster lifecycle Haskell module [Planned]

**Status**: Planned
**Docs to update**: `documents/engineering/cluster_topology.md`,
`documents/operations/cluster_bootstrap_runbook.md`, `system-components.md`

#### Objective

Land `src/Daemon/Cluster/Kind.hs` and supporting modules: kind cluster create / delete,
kubeconfig export, manual StorageClass + PV reconciliation, Helm dependency build, Harbor
bootstrap, Pulsar bootstrap, MinIO bootstrap + bucket seeding, ConfigMap render,
orchestrator / worker Deployment apply, edge port discovery.

#### Deliverables

- `src/Daemon/Cluster/Kind.hs` (cluster create/delete/status)
- `src/Daemon/Cluster/Storage.hs` (manual StorageClass + PV reconciliation)
- `src/Daemon/Cluster/Harbor.hs` (Harbor bootstrap + image publication)
- `src/Daemon/Cluster/Pulsar.hs` (Pulsar bootstrap + namespace setup)
- `src/Daemon/Cluster/MinIO.hs` (MinIO bootstrap + bucket seeding)
- `src/Daemon/Cluster/Workload.hs` (orchestrator / worker Deployment apply)
- `src/Daemon/Cluster/EdgePort.hs` (port discovery + persistence)

#### Validation

Unit tests cover the plan-generation logic (which kubectl invocations, in which order). Live
cluster bring-up validated in Phase 7.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 5.2: Helm chart [Planned]

**Status**: Planned
**Blocked by**: 5.1
**Docs to update**: `documents/engineering/cluster_topology.md`, `system-components.md`

#### Objective

Land `chart/` with Chart.yaml, values.yaml, per-cohort values overrides, and the deployment
templates.

#### Deliverables

- `chart/Chart.yaml` declaring Harbor / Pulsar / MinIO chart dependencies
- `chart/values.yaml` with `orchestrator.replicas` (default `2`, no anti-affinity),
  `worker.enabled`, `worker.replicas` (default `2`), worker anti-affinity defaults,
  per-component resource requests, and the WAN-egress NetworkPolicy stanza permitting only
  orchestrator pods to reach external networks
- `chart/values/apple-silicon.yaml` overriding `worker.enabled: false`
- `chart/values/linux-cpu.yaml` overriding `worker.enabled: true`, `worker.replicas: 2`
- `chart/templates/deployment-orchestrator.yaml`
- `chart/templates/deployment-worker.yaml` (conditional on `worker.enabled`)
- `chart/templates/configmap-orchestrator.yaml`, `configmap-worker.yaml`
- `chart/templates/service-*.yaml` as needed for in-cluster reachability

#### Validation

`helm template ./chart -f chart/values/linux-cpu.yaml` and
`helm template ./chart -f chart/values/apple-silicon.yaml` both produce valid YAML; the
worker Deployment renders only for the linux-cpu values.

#### Remaining Work

(scoped when the sprint opens)

### Sprint 5.3: Dhall configs for orchestrator and worker [Planned]

**Status**: Planned
**Blocked by**: 5.1, 5.2
**Docs to update**: `documents/architecture/library_consumption_model.md`, `system-components.md`

#### Objective

Land the test-harness Dhall configs the orchestrator and worker each consume.

#### Deliverables

- `dhall/orchestrator.dhall` (BootConfig Orchestrator) with Pulsar / MinIO endpoints,
  upstream topic set, fan-out topic set
- `dhall/worker.dhall` (BootConfig Worker) with Pulsar / MinIO endpoints, cohort tag, cache
  directory

#### Validation

`daemon-substrate-test service --role orchestrator --config dhall/orchestrator.dhall` boots
through `Bootstrap → AcquireClients → ProbeClients → Ready` against a running cluster. Same
for worker.

#### Remaining Work

(scoped when the sprint opens)

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/cluster_topology.md` updates from "planned" to current-state.

**Reference docs to create/update:**
- none unique to this phase

**Operations docs to create/update:**
- `documents/operations/cluster_bootstrap_runbook.md` updates from forward-looking to
  current-state as cluster bring-up becomes real.

**Cross-references to add:**
- `system-components.md` flips chart-workload rows and the cluster-orchestration module rows
  to `Implemented: yes`.
