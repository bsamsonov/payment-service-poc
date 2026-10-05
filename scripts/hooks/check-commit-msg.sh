#!/usr/bin/env bash
# Validates the first line of a commit message against Conventional Commits.
set -euo pipefail

msg_file="$1"
subject="$(head -n1 "$msg_file")"

# Allow git-generated messages.
if [[ "$subject" =~ ^(Merge|Revert|fixup!|squash!|amend!) ]]; then
  exit 0
fi

max_len=72
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._-]+\))?!?: .+$'
if [[ ! "$subject" =~ $pattern || ${#subject} -gt $max_len ]]; then
  cat >&2 <<MSG
Commit message does not follow Conventional Commits:
  "$subject" (${#subject} chars)
Expected: <type>(<optional scope>): <subject>, whole line up to ${max_len} chars
Types: feat fix docs style refactor perf test build ci chore revert
MSG
  exit 1
fi
