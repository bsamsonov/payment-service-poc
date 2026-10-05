#!/usr/bin/env bash
# Aggregate raw reviewer reports of a round with the review-aggregator subagent and render the results:
#   aggregate.json — structured result (schema: aggregate.schema.json)
#   report.md      — confirmed and rejected findings, reviewer stats
#   guide.md       — guide for the human reviewer (posted as a PR comment)
#   stats.tsv      — per reviewer: raw findings, confirmed findings
#
# Usage: scripts/review/aggregate.sh <round-dir>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: aggregate.sh <round-dir>}"
round_dir="$(cd "$round_dir" && pwd)"
round_rel="${round_dir#"$REPO_ROOT"/}"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
mode="$(jq -r .mode "$round_dir/meta.json")"
compgen -G "$round_dir/raw/*.md" >/dev/null || die "no raw reports in $round_rel/raw"

reports="$(cd "$round_dir/raw" && ls -1 *.md | sed "s|^|- \`$round_rel/raw/|; s|$|\`|")"
log "aggregating $(wc -l <<<"$reports") reports"
(cd "$REPO_ROOT" && timeout "${PR_REVIEW_TIMEOUT:-1200}" claude -p \
  --agent review-aggregator \
  --output-format json \
  --json-schema "$(cat "$SCRIPTS_DIR/aggregate.schema.json")" \
  --permission-mode dontAsk \
  --strict-mcp-config \
  --disable-slash-commands \
  --no-session-persistence \
  --settings '{"disableAllHooks": true}' \
  "Aggregate review round \`$round_rel/\` of PR #$pr (mode: $mode).
Bundle: \`$round_rel/bundle/\` (start with manifest.md). Raw reports:
$reports") >"$round_dir/logs/aggregator.json" 2>"$round_dir/logs/aggregator.err" \
  || die "aggregator failed, see $round_rel/logs/aggregator.err"
jq -e '.is_error == false and (.structured_output | type == "object")' "$round_dir/logs/aggregator.json" >/dev/null \
  || die "aggregator returned no structured output, see $round_rel/logs/aggregator.json"
jq '.structured_output' "$round_dir/logs/aggregator.json" >"$round_dir/aggregate.json"
agg="$round_dir/aggregate.json"

# Per-reviewer stats: raw = "### F<n>" headings (L2) or failed rules (L1); confirmed = findings listing the reviewer.
: >"$round_dir/stats.tsv"
for f in "$round_dir"/raw/*.md; do
  id="$(basename "$f" .md)"
  if [[ "$id" == checklist ]]; then
    raw="$(grep -cE '^\| *RC-[0-9]+ *\| *fail' "$f" || true)"
  else
    raw="$(grep -cE '^#{2,4} *(F[0-9]+|[0-9]+[.)])' "$f" || true)"
  fi
  confirmed="$(jq --arg id "$id" '[.findings[] | select(.sources | index($id))] | length' "$agg")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$pr" "$round" "$id" "$raw" "$confirmed" >>"$round_dir/stats.tsv"
done

jq -r --arg pr "$pr" --arg round "$round" --arg mode "$mode" --slurpfile q "$round_dir/quorum.json" '
  def loc: "`\(.path):\(.line)`";
  "# /pr-review report — PR #\($pr), round \($round) (\($mode))\n",
  "Reviewers ok: \($q[0].ok | join(", ")); failed: \(if ($q[0].failed | length) == 0 then "none" else ($q[0].failed | join(", ")) end)" +
    (if $q[0].quorum then "" else " — **degraded run, quorum not met**" end) + "\n",
  "## Confirmed findings (\(.findings | length))\n",
  (.findings[] | "### \(.id) · \(.severity)\(if .rule != "" then " · " + .rule else "" end) — \(.title)\n" +
     "- location: \(loc)\(if .in_diff then "" else " (outside the diff)" end)\n- reported by: \(.sources | join(", "))\n\n\(.body)\n"),
  (if (.previous | length) > 0 then "## Previous findings\n", (.previous[] | "- \(.id): \(.status) — \(.note)"), "" else empty end),
  "## Rejected (\(.rejected | length))\n",
  (.rejected[] | "- [\(.source)] \(.title) — \(.reason)")
' "$agg" >"$round_dir/report.md"

jq -r --arg pr "$pr" --arg round "$round" --arg mode "$mode" --slurpfile q "$round_dir/quorum.json" '
  def loc: "`\(.path):\(.line)`";
  "## /pr-review guide — round \($round)\(if $mode == "delta" then " (changes since the previous round)" else "" end)\n",
  (if $q[0].quorum then empty else "> **Degraded run**: failed reviewers: \($q[0].failed | join(", ")).\n" end),
  "### What changed",
  (.summary[] | "- \(.)"),
  "",
  "### Must review",
  (if (.must_review | length) == 0 then "- nothing flagged" else
     (.must_review | to_entries[] | "- [ ] **\(.key + 1).** \(.value | loc) — \(.value.risk)\n  _Ask yourself:_ \(.value.question)") end),
  "",
  "### Findings (posted as review comments)",
  (if (.findings | length) == 0 then "- none" else
     (.findings[] | "- [ ] **\(.id)** \(.severity)\(if .rule != "" then " · " + .rule else "" end) — \(.title) (\(loc))") end),
  "",
  (if (.previous | length) > 0 then "### Previous findings", (.previous[] | "- \(.id): \(.status) — \(.note)"), "" else empty end),
  "### Can be skimmed",
  (if (.skim | length) == 0 then "- nothing" else (.skim[] | "- \(.what) — \(.why)") end),
  "",
  "<sub>Reviewers: \($q[0].ok | join(", ")). Close each finding with a fix commit or a reply explaining why it is not a bug.</sub>"
' "$agg" >"$round_dir/guide.md"

log "aggregated: $(jq '.findings | length' "$agg") confirmed, $(jq '.rejected | length' "$agg") rejected → $round_rel/{report,guide}.md"
