# Documents Index

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [documentation_standards.md](documentation_standards.md), [../DEVELOPMENT_PLAN/README.md](../DEVELOPMENT_PLAN/README.md)

> **Purpose**: Orient readers to the `documents/` tree and link to the canonical documentation
> standards and per-topic doctrine homes.

## Layout

```text
documents/
├── README.md                       # this file
├── documentation_standards.md      # authoritative rules for governed docs
├── architecture/                   # cross-cutting doctrine and structural decisions
├── development/                    # contributor and assistant workflow, testing strategy
├── engineering/                    # technical contracts, schemas, layouts
├── operations/                     # operator-facing runbooks for the test harness
└── reference/                      # surface inventories (CLI, protobuf)
```

## Canonical topic homes

| Topic | Home |
|-------|------|
| Documentation rules | [documentation_standards.md](documentation_standards.md) |
| Daemon roles (Worker, Orchestrator) | [architecture/daemon_roles.md](architecture/daemon_roles.md) |
| Pulsar/MinIO source-of-truth split | [architecture/pulsar_minio_ssot.md](architecture/pulsar_minio_ssot.md) |
| Pulsar / MinIO lifecycle policy | [architecture/lifecycle_policy.md](architecture/lifecycle_policy.md) |
| Library consumption model | [architecture/library_consumption_model.md](architecture/library_consumption_model.md) |
| Cabal package layout | [engineering/cabal_layout.md](engineering/cabal_layout.md) |
| Test-harness Pulsar topics | [engineering/pulsar_topics.md](engineering/pulsar_topics.md) |
| Test-harness MinIO buckets | [engineering/minio_buckets.md](engineering/minio_buckets.md) |
| Cluster topology | [engineering/cluster_topology.md](engineering/cluster_topology.md) |
| Mock engine | [engineering/mock_engine.md](engineering/mock_engine.md) |
| hostbootstrap integration | [engineering/hostbootstrap_integration.md](engineering/hostbootstrap_integration.md) |
| Assistant workflow | [development/assistant_workflow.md](development/assistant_workflow.md) |
| Local development | [development/local_dev.md](development/local_dev.md) |
| Testing strategy | [development/testing_strategy.md](development/testing_strategy.md) |
| Cluster bootstrap | [operations/cluster_bootstrap_runbook.md](operations/cluster_bootstrap_runbook.md) |
| Apple Silicon operator workflow | [operations/apple_silicon_runbook.md](operations/apple_silicon_runbook.md) |
| Linux CPU operator workflow | [operations/linux_cpu_runbook.md](operations/linux_cpu_runbook.md) |
| `daemon-substrate-test` CLI | [reference/cli_surface.md](reference/cli_surface.md) |
| Protobuf surface | [reference/proto_surface.md](reference/proto_surface.md) |

## Source of truth

`DEVELOPMENT_PLAN/` owns phase order and current implementation status. `documents/` owns
architecture, engineering, and operator guidance. When the two conflict, reconcile the governed
docs to `DEVELOPMENT_PLAN/`. See
[documentation_standards.md § Source Of Truth](documentation_standards.md) for the full rule.
