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

# Highest round number used by a PR (complete or not), or 0.
last_round_number() {
  local dir="$REVIEW_ROOT/$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -n | tail -1 | grep . || echo 0
}

# Latest complete round directory of a PR (bundle built: meta.json present), or empty.
latest_round_dir() {
  local dir="$REVIEW_ROOT/$1" n
  [[ -d "$dir" ]] || return 0
  for n in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -rn); do
    [[ -f "$dir/$n/meta.json" ]] && { echo "$dir/$n"; return 0; }
  done
}

# Settings layer for headless Claude reviewers: no hooks, English output regardless of the user's language setting.
CLAUDE_REVIEW_SETTINGS='{"disableAllHooks": true, "language": "English"}'

# Extract the body (system prompt) of a Claude agent file, i.e. everything after the YAML frontmatter.
agent_body() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/ && n<2 {n++; next} n>=2' "$1"
}
