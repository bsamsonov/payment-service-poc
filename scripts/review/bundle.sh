#!/usr/bin/env bash
# Build a review bundle for a pull request:
#   .review/<pr>/<round>/bundle/{manifest.md,diff.patch,files/,checklist.md,context.md,attention.md,spec/,previous-findings.md}
# Prints the round directory on stdout.
#
# Usage: scripts/review/bundle.sh <pr> [--delta]
#   --delta  diff only against the head reviewed in the previous round; previous findings are included.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh git jq

pr="${1:?usage: bundle.sh <pr> [--delta]}"
[[ "$pr" =~ ^[0-9]+$ ]] || die "PR number expected, got: $pr"
mode="full"
[[ "${2:-}" == "--delta" ]] && mode="delta"

meta="$(gh pr view "$pr" --json number,title,body,url,headRefName,headRefOid,baseRefName,isDraft,state)"
head_sha="$(jq -r .headRefOid <<<"$meta")"
base_ref="$(jq -r .baseRefName <<<"$meta")"
head_ref="$(jq -r .headRefName <<<"$meta")"

log "PR #$pr: fetching base '$base_ref' and head ${head_sha:0:7}"
git fetch -q origin "$base_ref" "pull/$pr/head"
git cat-file -e "$head_sha^{commit}" || die "head commit $head_sha not available after fetch"
base_sha="$(git merge-base "origin/$base_ref" "$head_sha")"

prev_dir="$(latest_reviewed_round_dir "$pr")"
diff_from="$base_sha"
if [[ "$mode" == "delta" ]]; then
  [[ -n "$prev_dir" ]] || die "--delta needs a previous reviewed round (with aggregate.json) in .review/$pr"
  prev_head="$(jq -r .head_sha "$prev_dir/meta.json")"
  if [[ "$prev_head" == "$head_sha" ]]; then
    die "no new commits since round $(basename "$prev_dir") (${head_sha:0:7})"
  elif git merge-base --is-ancestor "$prev_head" "$head_sha" 2>/dev/null; then
    diff_from="$prev_head"
  else
    log "previous head ${prev_head:0:7} is not an ancestor (history rewritten): delta falls back to the full diff"
  fi
fi

# Numbering skips aborted rounds (directories without meta.json) instead of reusing them.
round=$(( $(last_round_number "$pr") + 1 ))
round_dir="$REVIEW_ROOT/$pr/$round"
bundle="$round_dir/bundle"
mkdir -p "$bundle/files" "$round_dir/raw" "$round_dir/logs"

# Fixed a/ b/ prefixes and no external diff tools: publish.sh parses the patch, so user diff config must not leak in.
DIFF=(git -c diff.noprefix=false -c diff.mnemonicPrefix=false diff --no-color --no-ext-diff --find-renames
      --src-prefix=a/ --dst-prefix=b/)
"${DIFF[@]}" "$diff_from" "$head_sha" >"$bundle/diff.patch"
# The full PR diff is always kept: inline comments must target lines of the PR diff, not of the delta.
"${DIFF[@]}" "$base_sha" "$head_sha" >"$round_dir/pr.patch"

mapfile -t changed < <(git diff --name-only --diff-filter=d --find-renames "$diff_from" "$head_sha")
for path in "${changed[@]}"; do
  mkdir -p "$bundle/files/$(dirname "$path")"
  git show "$head_sha:$path" >"$bundle/files/$path"
done
mapfile -t deleted < <(git diff --name-only --diff-filter=D "$diff_from" "$head_sha")

# Review inputs are taken from the PR head, so a PR that changes them is reviewed by its own rules.
for pair in "docs/review-checklist.md:checklist.md" "docs/review-context.md:context.md"; do
  src="${pair%%:*}" dst="${pair##*:}"
  git show "$head_sha:$src" >"$bundle/$dst" 2>/dev/null || die "$src not found at ${head_sha:0:7}"
done
# Optional: heuristics for the "Architect's attention" section (older PR heads may not have the file).
git show "$head_sha:docs/review-attention.md" >"$bundle/attention.md" 2>/dev/null || rm -f "$bundle/attention.md"

# Feature spec: from the branch name (feat/NNN-...) or from specs touched by the PR.
spec_id=""
if [[ "$head_ref" =~ ^feat/([0-9]{3})- ]]; then
  spec_id="${BASH_REMATCH[1]}"
else
  spec_id="$(git diff --name-only "$base_sha" "$head_sha" -- specs | sed -nE 's|^specs/([0-9]{3})-.*|\1|p' | head -1)"
fi
spec_dir=""
if [[ -n "$spec_id" ]]; then
  spec_dir="$(git ls-tree -d --name-only "$head_sha" specs/ | grep -E "^specs/${spec_id}-" | head -1 || true)"
  if [[ -n "$spec_dir" ]]; then
    mkdir -p "$bundle/spec"
    while read -r f; do
      git show "$head_sha:$f" >"$bundle/spec/$(basename "$f")"
    done < <(git ls-tree -r --name-only "$head_sha" "$spec_dir")
  fi
fi

if [[ "$mode" == "delta" ]]; then
  # Open findings of all earlier rounds (open-findings.json is maintained by aggregate.sh). Rounds aggregated before
  # it existed fall back to their own findings.
  if [[ -f "$prev_dir/open-findings.json" ]]; then
    cp "$prev_dir/open-findings.json" "$bundle/previous-findings.json"
  else
    jq --arg r "R$(basename "$prev_dir")-" '[.findings[] | {id: ($r + .id), title, severity, path, line, body}]' \
      "$prev_dir/aggregate.json" >"$bundle/previous-findings.json"
  fi
  jq -r '"# Open findings of previous rounds\n",
    "Report the status of each id in `previous`.\n",
    (.[] | "## \(.id) — \(.title)\n- location: `\(.path):\(.line)` (at the time it was reported)\n- severity: \(.severity)\n\n\(.body)\n")' \
    "$bundle/previous-findings.json" >"$bundle/previous-findings.md"
fi

jq -n --argjson pr "$pr" --argjson round "$round" --arg mode "$mode" \
  --arg head "$head_sha" --arg base "$base_sha" --arg from "$diff_from" --arg head_ref "$head_ref" \
  --arg created "$(date -u +%FT%TZ)" \
  '{pr:$pr, round:$round, mode:$mode, head_sha:$head, base_sha:$base, diff_from:$from, head_ref:$head_ref, created:$created}' \
  >"$round_dir/meta.json"

{
  echo "# Review bundle — PR #$pr, round $round ($mode)"
  echo
  echo "- Title: $(jq -r .title <<<"$meta")"
  echo "- URL: $(jq -r .url <<<"$meta")"
  echo "- Branch: \`$head_ref\` → \`$base_ref\`"
  echo "- Head: \`$head_sha\`; diff from: \`$diff_from\`"
  echo "- Spec: ${spec_dir:-none}"
  echo
  echo "## Files"
  echo "- \`diff.patch\` — $(grep -c '^diff --git' "$bundle/diff.patch" || true) files changed"
  echo "- \`files/\` — full post-change copies:"
  for path in "${changed[@]}"; do echo "  - \`files/$path\`"; done
  if (( ${#deleted[@]} )); then
    echo "- Deleted files:"
    for path in "${deleted[@]}"; do echo "  - \`$path\`"; done
  fi
  echo "- \`checklist.md\`, \`context.md\`"
  [[ -f "$bundle/attention.md" ]] && echo "- \`attention.md\` — heuristics for the Architect's attention section"
  [[ -d "$bundle/spec" ]] && echo "- \`spec/\` — $(ls "$bundle/spec" | tr '\n' ' ')"
  [[ -f "$bundle/previous-findings.md" ]] && echo "- \`previous-findings.md\`"
  echo
  echo "## PR description"
  echo
  jq -r '.body // ""' <<<"$meta"
} >"$bundle/manifest.md"

lines="$(wc -l <"$bundle/diff.patch")"
(( lines > 3000 )) && log "warning: diff has $lines lines; consider splitting the PR"
log "bundle ready: ${round_dir#"$REPO_ROOT"/} (${#changed[@]} files, $lines diff lines)"
echo "$round_dir"
