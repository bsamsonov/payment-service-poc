@AGENTS.md

## Claude Code specifics
- Use plan mode for any non-trivial change; reference the spec file in the prompt (`@specs/NNN-name/spec.md`).
- Hooks (`.claude/settings.json`): Java files are formatted after each edit; when you finish a turn with source changes,
  the fast check runs and a failure is returned to you — fix it instead of reporting the work as done.
- Commands: `/spec-new`, `/spec-plan`, `/spec-tasks`, `/spec-verify` (see `.claude/commands/`).
- Commits made with Claude may include a `Co-Authored-By: Claude …` trailer.
- Do not edit `.idea/` or read `.env*` files.
