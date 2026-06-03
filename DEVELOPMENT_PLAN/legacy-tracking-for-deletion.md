# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative cleanup ledger for obsolete module paths, duplicate guidance,
> and stale compatibility surfaces.

## Pending

The following surfaces were planned in earlier revisions of this repository's development plan
and have been removed by the `hostbootstrap` re-baseline (Phase 0 Sprint 0.6). They were never
implemented; the entries below record the decision so the plan history remains coherent.
Removal owning phase is Phase 0 Sprint 0.6 (documentation); replacements ship in Phase 6.

- **`bootstrap/apple-silicon.sh`** — planned but never implemented; replaced by the
  `HostDaemon` model entry in `hostbootstrap.dhall`. Owning phase: phase-0, sprint 0.6.
  Replacement: `hostbootstrap cluster up` driving the LaunchDaemon (see
  `../documents/engineering/hostbootstrap_integration.md`).
- **`bootstrap/linux-cpu.sh`** — planned but never implemented; replaced by the `Container`
  model entry in `hostbootstrap.dhall`. Owning phase: phase-0, sprint 0.6. Replacement:
  `hostbootstrap cluster up` driving the project container.
- **`compose.yaml`** — planned but never implemented; replaced by the `Container` model
  declared in `hostbootstrap.dhall` (`service = True`, `.data` + Docker-socket mounts).
  Owning phase: phase-0, sprint 0.6.
- **`daemon-substrate-linux-cpu:local` launcher image** — planned but never implemented;
  replaced by the thin `docker/linux-substrate.Dockerfile` that inherits from the
  `hostbootstrap` base tag. Owning phase: phase-0, sprint 0.6. Replacement landing in
  phase-7, sprint 7.2.

### To be deleted in consumer repositories (tracked here for visibility)

These items belong to consumer repositories (`infernix`, `jitML`) and must be removed when
those repositories refactor to consume `daemon-substrate` as a library. The entries are
recorded here so the substrate's contract stays honest.

- **`infernix/src/Infernix/Service.hs` `acquireEngineLock` / `engine.lock`** — `flock(2)`-based
  exclusion of multiple engine daemons. Substrate `development_plan_standards.md § K` forbids
  OS-level concurrency guards in worker code; Pulsar's at-most-one-active-consumer-per-message
  guarantee on shared subscriptions enforces the invariant correctly. Removal during
  infernix's `daemon-substrate` consumption refactor.
- **`jitML/src/JitML/Service/Capabilities.hs` and sibling subprocess / filesystem
  implementations** — superseded by `Daemon.Pulsar` / `Daemon.MinIO` / `Daemon.Harbor` /
  `Daemon.Kubectl` once jitML consumes the substrate library. Removal during jitML's
  `daemon-substrate` consumption refactor.
- **`jitML/src/JitML/Cluster/*`** — superseded by `Daemon.Cluster.*` once jitML consumes the
  substrate library. Project-specific Dhall body remains; reconciler logic moves to the
  library.
- **`jitML/src/JitML/Checkpoint/Store.hs` generic retention/GC logic** — superseded by
  `Daemon.MinIO.Store` plus `Daemon.Reconciler`'s orphan-scan. jitML's training-specific
  manifest body (with metric semantics) stays in jitML; the store mechanics move out.

## Completed

(none)

## Rules

Per [development_plan_standards.md § I](development_plan_standards.md):

- If an obsolete or duplicate surface still exists, it must appear in the **Pending** section
  above. Each entry names its location, the reason for removal, and the owning phase or
  sprint.
- When cleanup lands, move the entry from **Pending** to **Completed** in the same change.
- Empty `Pending` and `Completed` sections are valid. The ledger exists as a stable home so
  cleanup obligations are never lost; absence of pending items reflects current reality, not
  an incomplete file.

## Entry format

When a future entry is added, use this shape:

```markdown
- `path/to/obsolete/file` — short reason for removal. Owning phase: phase-N.
```

For more complex entries:

```markdown
- **`path/to/obsolete/surface`** — reason for removal. Owning phase: phase-N, sprint X.Y.
  Replacement: `path/to/new/surface` (see `documents/...`).
```
