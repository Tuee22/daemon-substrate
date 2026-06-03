# AGENTS.md

**Status**: Governed entry document
**Supersedes**: N/A
**Canonical homes**: [documents/development/assistant_workflow.md](documents/development/assistant_workflow.md), [documents/documentation_standards.md](documents/documentation_standards.md), [DEVELOPMENT_PLAN/development_plan_standards.md](DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Thin automation-oriented entry document that points LLM coding assistants at the
> canonical assistant-workflow, documentation, and development-plan rules, and that states the
> non-negotiable git-history boundary.

Instructions for LLM-based coding assistants (Codex, Cursor, Aider, etc.) working in this repository.

## Non-negotiable rules

Git history is **exclusively a user-controlled domain**. LLM assistants must never perform any of the following:

- never run `git add`
- never run `git commit`
- never run `git push`

Any staging, commit authoring, signing, tagging, or remote-update operation is reserved for the human operator. An assistant may edit files, run read-only `git` commands (`git status`, `git diff`, `git log`, `git blame`), and propose commit messages or PR descriptions in chat — but it must not perform the staging or commit itself.

If a workflow step appears to require a commit (for example, a CI check that runs against `HEAD` rather than the working tree), stop and ask the user to perform the commit. Do not work around the rule.

## Scope

This repository (`daemon-substrate`) is a shared Haskell library consumed by [`infernix`](https://github.com/Tuee22/infernix) and [`jitML`](https://github.com/Tuee22/jitML). See [README.md](README.md) for the architectural model.
