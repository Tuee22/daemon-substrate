# Documentation Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../DEVELOPMENT_PLAN/development_plan_standards.md](../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define how the governed `documents/` suite is structured, updated, and kept aligned
> with `DEVELOPMENT_PLAN/`, `README.md`, and the repository implementation.

## TL;DR

- `documents/` is the only canonical documentation root.
- Governed docs require metadata, relative links, and clear topic ownership.
- Broad doctrine docs use stronger structure: summary first, explicit current-status notes when
  current and target behavior mix, and validation sections when tests or lint prove the contract.
- The Phase 0 documentation validator is the mechanical enforcement point for the governed docs
  suite once it lands.

## Metadata Block

Every governed Markdown document under `documents/` starts with this block:

```markdown
# Title

**Status**: Authoritative source | Supporting reference | Draft
**Supersedes**: N/A | relative/path/to/old.md
**Referenced by**: [name](relative/link.md), [other](relative/other.md)

> **Purpose**: One-sentence summary.
```

Rules:

- the `# Title` line is the first non-empty line in the file
- `**Status**:` is required
- `**Supersedes**:` is required; use `N/A` when nothing is superseded
- `**Referenced by**:` is required, even when there is only one cross-reference
- the purpose blockquote is required

## Broad Doctrine Structure

Broad governed docs that define repository doctrine use stronger structure than a short reference
page.

Rules:

- include `## TL;DR` or `## Executive Summary` when the topic is broad
- include `## Current Status` when implemented behavior and target direction appear in the same
  document
- include `## Validation` when tests or lint prove the contract
- use explicit tables or matrices when a phase calls for ownership, durability, or matrix detail as
  a closure condition
- answer these questions directly when relevant: what is the rule, what is current versus target,
  how is it validated, and what is library-internal detail versus consumer-facing contract

## Governed Root Documents

The governed root documents use a parallel metadata block so readers and automation can distinguish
orientation or entry guidance from canonical topic ownership.

```markdown
# Title

**Status**: Governed orientation document | Governed entry document
**Supersedes**: short statement describing the root-level duplication this file replaces, or N/A
**Canonical homes**: [documents/...](documents/...), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md)

> **Purpose**: One-sentence summary.
```

Rules:

- `README.md` uses `**Status**: Governed orientation document`
- `AGENTS.md` and `CLAUDE.md` use `**Status**: Governed entry document`
- every governed root doc carries both `**Supersedes**:` and `**Canonical homes**:` lines
- root docs summarize and link; they do not become parallel canonical homes for workflow or
  architecture topics

## Taxonomy

The canonical suite layout is:

```text
documents/
├── README.md
├── documentation_standards.md
├── architecture/
├── development/
├── engineering/
├── operations/
└── reference/
```

Rules:

- `documents/` is the only canonical documentation root
- `docs/` is not introduced
- new top-level categories (for example `tools/`, `research/`) require an update to this file and
  `documents/README.md` in the same change that adds the directory

## Source Of Truth

- `DEVELOPMENT_PLAN/` owns phase order, current implementation status, and closure criteria.
- `documents/` owns architecture and engineering guidance once the relevant document exists.
- The build, lifecycle, and bootstrap layer is provided by
  [`hostbootstrap`](https://github.com/Tuee22/hostbootstrap); its own documentation standards
  (see [`~/hostbootstrap/documents/documentation_standards.md`](https://github.com/Tuee22/hostbootstrap/blob/main/documents/documentation_standards.md))
  are the source of truth for that repository's docs. This file remains canonical for
  `daemon-substrate`'s own `documents/` tree.
- When current-state or closure claims in `documents/` conflict with `DEVELOPMENT_PLAN/`,
  reconcile the governed docs to `DEVELOPMENT_PLAN/`; do not use `documents/` as a parallel
  implementation status authority.
- `README.md` is a governed orientation layer and points to canonical documents instead of
  duplicating them.
- `AGENTS.md` and `CLAUDE.md` are governed entry documents and must stay aligned with the
  repository-level rules they summarize.
- Supporting-reference docs may narrow or operationalize a topic already owned elsewhere, but they
  point back to the canonical owner instead of presenting a second authoritative home.

## Naming And Linking

- file names are lowercase `snake_case` with a `.md` suffix
- `README.md`, `AGENTS.md`, `CLAUDE.md`, and `LICENSE` are the only permitted ALL-CAPS file names
- relative Markdown links are required for in-repo references
- each governed doc links to at least one other governed source
- module names, commands, paths, types, and binaries use backticks

## Content Rules

- write current-state declarative guidance, not migration diaries
- keep one canonical home per topic
- move implementation status discussion into `DEVELOPMENT_PLAN/`
- describe `daemon-substrate` as a Haskell library consumed by other projects; do not describe
  consumer-specific behavior (CLI surfaces, substrate matrices, Helm charts) as belonging to this
  repository
- no governed doc may reference environment variables, `$PATH`, or shell-inherited values as a
  supported configuration source; the supported configuration substrate is typed Dhall, consumed
  by the consumer at startup and passed into the library as a typed record

## Update Rules

- when the public typeclass surface (`HasPulsar`, `HasMinIO`, `HasEngine`, lifecycle hooks)
  changes, update the relevant `documents/engineering/*.md` files and any affected phase document
  in the same change
- when the protobuf schemas under `proto/` change, update the relevant `documents/reference/*.md`
  schema documentation and the affected phase document in the same change
- when the daemon-role model (Worker, Orchestrator) changes, update
  `documents/architecture/daemon_roles.md`, `DEVELOPMENT_PLAN/system-components.md`, and the
  affected phase document in the same change
- when the cabal layout (libraries, executables, sublibraries) changes, update
  `documents/engineering/cabal_layout.md` and the affected phase document in the same change
- when repository-level workflow rules change, review `README.md`, `AGENTS.md`, and `CLAUDE.md` in
  the same change

## Validation

The documentation validator owned by Phase 0 of `DEVELOPMENT_PLAN/` checks:

- required metadata lines for governed `documents/` content
- required structure for the named broad doctrine docs whose headings are part of the supported
  contract
- governed root-document metadata lines (`Status`, `Supersedes`, `Canonical homes`, purpose)
- governed document existence for the canonical bootstrap set
- relative link resolution for governed docs, governed root docs, and phase-plan docs
- root `README.md` references to both `documents/` and `DEVELOPMENT_PLAN/`
- `DEVELOPMENT_PLAN/` phase documents retaining their `## Documentation Requirements` section

The validator is implementation work owned by a later phase. Until it lands, contributors apply
the rules above by hand; cross-link resolution is the most useful manual check.
