# 0003. AI-assisted development workflow and quality gates

- Status: Accepted
- Date: 2026-10-02

## Context and problem
Code is written largely with AI coding agents. Without a system this produces large, hard-to-review changes and
unverifiable behavior. We need a workflow that is predictable for the agent and reviewable for humans.

## Decision
1. **Spec first**: features start from `specs/NNN/spec.md` with numbered acceptance criteria; `plan.md` and `tasks.md`
   follow. Every AC has a test carrying its id.
2. **Test first, small steps**: commit after every logical block (code and documentation) so any commit is a safe
   rollback point. Conventional Commits; rebase merge keeps atomic commits on `main`.
3. **Deterministic checks over instructions**: rules that can be automated are enforced by tools, not prompts —
   layered by speed: IDE → Claude Code hooks (format on edit, fast check on stop) → git hooks via Lefthook
   (pre-commit: format, secrets, commit message; pre-push: fast verify) → CI (full verify, analyzers, CodeQL) →
   repository ruleset (PR only, required checks, resolved conversations, linear history).
4. **Single source of agent instructions**: `AGENTS.md` (read by all agents); `CLAUDE.md` imports it.
5. **Layered review**: CI checks, AI review against a checklist and by several models, an AI-generated review guide,
   and a final human review (implemented as the `/pr-review` command).

## Consequences
- Local hooks are a convenience; CI and the ruleset are the guarantee.
- Every review finding that can be formalized is moved into an automated check (ratchet).
