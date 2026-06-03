# Assistant Workflow

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../AGENTS.md](../../AGENTS.md), [../../CLAUDE.md](../../CLAUDE.md), [../README.md](../README.md), [local_dev.md](local_dev.md)

> **Purpose**: Canonical workflow document for LLM-based coding assistants (Claude, Codex,
> Cursor, Aider, and similar) operating in this repository. Restates the non-negotiable git
> boundary and names the canonical homes for everything else.

## TL;DR

- **Never `git add` / `git commit` / `git push`.** Git history is exclusively user-controlled.
- Read the standards before writing docs or plan content.
- Treat `DEVELOPMENT_PLAN/` as authoritative for current-state status; treat `documents/` as
  authoritative for architecture, engineering, and operator guidance.
- Edit files in-place when reasonable; do not invent parallel files for the same topic.

## Non-negotiable rules

Git history is exclusively user-controlled. Assistants must never perform any of the
following:

- `git add`
- `git commit`
- `git push`
- `git rebase`, `git merge`, `git tag`, `git reset --hard`, or any other history-mutating
  operation

Read-only `git` operations are fine and encouraged for understanding state: `git status`,
`git diff`, `git log`, `git blame`, `git show`. So is proposing commit messages or PR
descriptions in chat for the operator to use.

If a workflow step appears to require a commit (for example, a CI check that runs against
`HEAD` rather than the working tree), stop and ask the operator to perform the commit. Do not
work around the rule.

## Where to look first

Before making any non-trivial change, read:

- [../documentation_standards.md](../documentation_standards.md) — how governed docs are
  structured.
- [../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)
  — how the phase plan is structured.
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — current status of every
  phase.
- [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md) —
  authoritative inventory of components, typeclasses, schemas, topics, buckets, roles.
- [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md) —
  the canonical infrastructure layer this repository sits on top of, and the
  `hostbootstrap` / `daemon-substrate` ownership boundary.
- [../architecture/lifecycle_policy.md](../architecture/lifecycle_policy.md) — how the
  substrate owns Pulsar topic and MinIO bucket / object lifecycle (declarative `LifecyclePolicy`
  + leader-elected reconciler running concurrently on the orchestrator).

## House style

- **One canonical home per topic.** If you find yourself writing the same paragraph in two
  files, link instead.
- **Current-state declarative prose.** Not migration diaries, not aspiration disguised as
  status. If you describe target behavior that does not exist, mark it explicitly as such.
- **Relative links** for in-repo references.
- **Backticks** for module names, commands, paths, types, and binaries.
- **Metadata blocks** on every governed doc (Status, Supersedes, Referenced by, Purpose).

## When you edit a doc

Update every cross-reference that points to the doc. If you move or rename a file, search the
repo for the old path and update consumers in the same change.

When a change touches doctrine or contract that other docs depend on, the standards files name
which docs must update together. See:

- [../documentation_standards.md § Update Rules](../documentation_standards.md)
- [../../DEVELOPMENT_PLAN/development_plan_standards.md § H](../../DEVELOPMENT_PLAN/development_plan_standards.md)

## When you touch bootstrap / lifecycle

- Substrate behavior is declared in `hostbootstrap.dhall` at the repository root. Do not
  hand-roll `bootstrap/*.sh`, `compose.yaml`, or multi-language Dockerfile layers — those
  responsibilities belong to [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap).
- The project Dockerfile is intentionally thin: `FROM ${BASE_IMAGE}` plus the project's own
  build steps. Toolchain installation (GHC, Cabal, kube tools, `protoc`) belongs in the
  `hostbootstrap` base image, not here.
- The in-cluster reconcilers (kind create, Helm install, ConfigMap render, Deployment apply)
  remain in Haskell under `src/Daemon/Cluster/*`. The seam between `hostbootstrap` and
  `daemon-substrate-test` is documented in
  [../engineering/hostbootstrap_integration.md](../engineering/hostbootstrap_integration.md).

## When you write Haskell

- No `lookupEnv` / `getEnv` / `getEnvironment` / `setEnv` / `unsetEnv` anywhere under `src/`.
- No `proc "<bare-name>"` calls (anything that resolves through `$PATH`). External invocations
  read absolute paths from the typed `BootConfig` record.
- No substrate identifier branching (`apple-silicon`, `linux-cpu`, etc.) under `src/Daemon/*`
  proper. The test-harness substrate seam under `src/Daemon/Cluster/*`, `bootstrap/`,
  `docker/`, and `chart/` is the exception.

## When you write tests

- Unit tests are pure and do not require a cluster. They live under `test/unit/`.
- Integration tests require a kind cluster brought up by `daemon-substrate-test cluster up`.
  They live under `test/integration/`.
- Tests use typed fixtures, not environment variables.

## When you cannot make progress

Stop and ask. The repository's standards are intentionally strict so the operator can rely on
them; an assistant guessing past a constraint is worse than an assistant pausing for
clarification.
