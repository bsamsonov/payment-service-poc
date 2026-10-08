#!/usr/bin/env bash
# Clean up local branches (and their worktrees) whose pull requests are merged.
#
# Usage: scripts/git/cleanup-merged.sh [--apply] [--quiet]
#   (default)  report only, change nothing
#   --apply    remove the branches' clean worktrees and delete the branches
#   --quiet    print nothing when there is nothing to report (for hooks)
#
# A branch qualifies when its upstream is gone (GitHub deletes head branches on merge) and `gh` finds a merged PR
# whose head commit equals the local tip — so nothing on the branch is missing from the merge. Rebase merge
# rewrites commits, so `git branch -d` would refuse; this check is what makes `-D` safe.
# Never touched: the branch checked out in the main worktree, worktrees with local changes, branches whose PR is
# not merged (closed or unknown) — those are only reported.
set -euo pipefail

apply=false quiet=false
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --quiet) quiet=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

git fetch --prune --quiet origin 2>/dev/null || echo "warning: git fetch failed, using local state" >&2

main_worktree="$(git worktree list --porcelain | awk 'NR==1 {sub(/^worktree /, ""); print; exit}')"
gh_ok=true
command -v gh >/dev/null 2>&1 || gh_ok=false

# Path of the worktree that has the branch checked out; empty if none.
worktree_of() {
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref { print path; exit }'
}

report=()
while read -r branch track; do
  [[ "$track" == "[gone]" ]] || continue
  pr=""
  tip="$(git rev-parse "refs/heads/$branch")"
  if $gh_ok; then
    # Only a merged PR whose last commit is exactly the local tip: no local commits after the merge,
    # no reused branch name with new work.
    pr="$(gh pr list --head "$branch" --state merged --limit 100 --json number,headRefOid \
      --jq "map(select(.headRefOid == \"$tip\")) | .[0].number // empty" 2>/dev/null || true)"
  fi
  if [[ -z "$pr" ]]; then
    report+=("- $branch: upstream gone, no merged PR with the local tip ${tip:0:7} — check manually")
    continue
  fi
  wt="$(worktree_of "$branch")"
  if [[ "$wt" == "$main_worktree" ]]; then
    report+=("- $branch: PR #$pr merged, but checked out in the main worktree — switch to another branch first")
    continue
  fi
  if [[ -n "$wt" && -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    report+=("- $branch: PR #$pr merged, worktree $wt has local changes — left as is")
    continue
  fi
  if $apply; then
    if [[ -n "$wt" ]]; then git worktree remove "$wt"; fi
    git branch -D --quiet "$branch"
    report+=("- $branch: PR #$pr merged — ${wt:+worktree $wt removed, }branch deleted")
  else
    report+=("- $branch: PR #$pr merged — ${wt:+worktree $wt and }branch can be deleted")
  fi
done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)

if $apply; then git worktree prune; fi

if [[ ${#report[@]} -eq 0 ]]; then
  $quiet || echo "Nothing to clean up."
  exit 0
fi
if $apply; then
  echo "Cleanup result:"
else
  echo "Merged branches to clean up (run scripts/git/cleanup-merged.sh --apply):"
fi
$gh_ok || echo "(gh not found: merge status cannot be checked, nothing is deleted)"
printf '%s\n' "${report[@]}"
