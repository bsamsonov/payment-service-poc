#!/usr/bin/env bash
# Validates the first line of a commit message against Conventional Commits.
set -euo pipefail

msg_file="$1"
subject="$(head -n1 "$msg_file")"

# Allow git-generated messages.
if [[ "$subject" =~ ^(Merge|Revert|fixup!|squash!|amend!) ]]; then
  exit 0
fi

pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._-]+\))?!?: .{1,72}$'
if [[ ! "$subject" =~ $pattern ]]; then
  cat >&2 <<MSG
Commit message does not follow Conventional Commits:
  "$subject"
Expected: <type>(<optional scope>): <subject up to 72 chars>
Types: feat fix docs style refactor perf test build ci chore revert
MSG
  exit 1
fi
