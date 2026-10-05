#!/usr/bin/env bash
# Shared helpers for scripts/review/*. Source it; do not execute.

REPO_ROOT="$(git rev-parse --show-toplevel)"
REVIEW_ROOT="$REPO_ROOT/.review"
SCRIPTS_DIR="$REPO_ROOT/scripts/review"

log() { printf '[pr-review] %s\n' "$*" >&2; }
die() { printf '[pr-review] ERROR: %s\n' "$*" >&2; exit 1; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# Latest round directory of a PR, or empty.
latest_round_dir() {
  local pr="$1" dir="$REVIEW_ROOT/$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' | sort -n | tail -1 \
    | sed "s|^|$dir/|"
}

# Extract the body (system prompt) of a Claude agent file, i.e. everything after the YAML frontmatter.
agent_body() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/ && n<2 {n++; next} n>=2' "$1"
}
