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

# Latest reviewed round directory of a PR (aggregation finished: aggregate.json present), or empty.
# Rounds that stopped earlier (no quorum, aggregation failure, Ctrl-C) are ignored, so --delta never skips commits.
latest_reviewed_round_dir() {
  local dir="$REVIEW_ROOT/$1" n
  [[ -d "$dir" ]] || return 0
  for n in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -rn); do
    [[ -f "$dir/$n/meta.json" && -f "$dir/$n/aggregate.json" ]] && { echo "$dir/$n"; return 0; }
  done
  return 0  # "none" is not an error: callers use $(...) under set -e
}

# Latest round directory of a PR whose bundle was built for the given head (reviewed or not), or empty.
latest_round_dir_for_head() {
  local dir="$REVIEW_ROOT/$1" head="$2" n
  [[ -d "$dir" ]] || return 0
  for n in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -rn); do
    [[ -f "$dir/$n/meta.json" && -f "$dir/$n/bundle/manifest.md" ]] || continue
    [[ "$(jq -r .head_sha "$dir/$n/meta.json")" == "$head" ]] && { echo "$dir/$n"; return 0; }
  done
  return 0
}

# Prompts and scripts of the review are taken from the working tree, not from the PR. A feature branch cut before a
# change of the review tooling runs the old version (PR #13, round 3, ran without the guide's attention section).
warn_if_tooling_differs_from_main() {
  git -C "$REPO_ROOT" rev-parse -q --verify origin/main >/dev/null || return 0
  git -C "$REPO_ROOT" diff --quiet origin/main -- scripts/review .claude/agents .claude/skills/pr-review \
    .claude/skills/review-guide 2>/dev/null && return 0
  log "WARNING: review tooling in this working tree differs from origin/main;" \
      "run from a checkout of main (e.g. a worktree) to use the current reviewers and guide"
}

# Settings layer for headless Claude reviewers: no hooks, English output regardless of the user's language setting.
CLAUDE_REVIEW_SETTINGS='{"disableAllHooks": true, "language": "English"}'

# Extract the body (system prompt) of a Claude agent file, i.e. everything after the YAML frontmatter.
agent_body() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/ && n<2 {n++; next} n>=2' "$1"
}
