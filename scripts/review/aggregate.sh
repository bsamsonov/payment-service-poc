#!/usr/bin/env bash
# Aggregate raw reviewer reports of a round with the review-aggregator subagent and render the results:
#   aggregate.json — structured result (schema: aggregate.schema.json)
#   report.md      — confirmed and rejected findings, reviewer stats
#   guide.md       — guide for the human reviewer (posted as a PR comment)
#   stats.tsv      — per reviewer: raw findings, confirmed findings
#
# Usage: scripts/review/aggregate.sh <round-dir> [--reuse]
#   --reuse  do not call the aggregator again; re-render from logs/aggregator.json
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: aggregate.sh <round-dir> [--reuse]}"
reuse=false
[[ "${2:-}" == "--reuse" ]] && reuse=true
round_dir="$(cd "$round_dir" && pwd)"
round_rel="${round_dir#"$REPO_ROOT"/}"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
mode="$(jq -r .mode "$round_dir/meta.json")"
compgen -G "$round_dir/raw/*.md" >/dev/null || die "no raw reports in $round_rel/raw"

reports="$(cd "$round_dir/raw" && ls -1 *.md | sed "s|^|- \`$round_rel/raw/|; s|$|\`|")"
if [[ "$reuse" == true && -s "$round_dir/logs/aggregator.json" ]]; then
  log "reusing logs/aggregator.json"
else
  log "aggregating $(wc -l <<<"$reports") reports"
  (cd "$REPO_ROOT" && timeout "${PR_REVIEW_TIMEOUT:-1200}" claude \
    -p "Aggregate review round \`$round_rel/\` of PR #$pr (mode: $mode).
Bundle: \`$round_rel/bundle/\` (start with manifest.md). Raw reports:
$reports" \
    --agent review-aggregator \
    --output-format json \
    --json-schema "$(cat "$SCRIPTS_DIR/aggregate.schema.json")" \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS") >"$round_dir/logs/aggregator.json" 2>"$round_dir/logs/aggregator.err" \
    || die "aggregator failed, see $round_rel/logs/aggregator.err"
fi
jq -e '.is_error == false' "$round_dir/logs/aggregator.json" >/dev/null \
  || die "aggregator reported an error, see $round_rel/logs/aggregator.json"

# Structured output when --json-schema is honoured; otherwise the JSON object from the text result
# (the agent is instructed to answer with JSON only, possibly inside a ```json fence).
# aggregate.json marks the round as reviewed (delta rounds start from it), so it appears only after validation;
# a failed re-aggregation keeps the previous valid file (mv replaces it atomically).
tmp="$round_dir/aggregate.json.tmp"
jq 'if (.structured_output | type) == "object" then .structured_output
    else .result | sub("^[^{]*"; "") | sub("[^}]*$"; "") | fromjson end' \
  "$round_dir/logs/aggregator.json" >"$tmp" 2>/dev/null \
  || die "aggregator output is not valid JSON, see $round_rel/logs/aggregator.json"
jq -e 'has("summary") and has("findings") and has("rejected") and has("must_review") and has("skim") and has("previous")
       and (.reviewers | type == "array" and length > 0)
       and all(.findings[]; has("id") and has("path") and has("line") and has("severity") and has("body") and has("sources"))
       and all(.reviewers[]; has("id") and has("raw_findings"))' \
  "$tmp" >/dev/null || die "aggregator JSON misses required fields, see $round_rel/aggregate.json.tmp"
mv "$tmp" "$round_dir/aggregate.json"
agg="$round_dir/aggregate.json"

# Open findings after this round: earlier open findings not reported as fixed + this round's findings (ids R<n>-Fk).
prev_open='[]'
[[ -f "$round_dir/bundle/previous-findings.json" ]] && prev_open="$(cat "$round_dir/bundle/previous-findings.json")"
jq --arg r "R$round-" --argjson prev "$prev_open" '
  (.previous | map({key: .id, value: .status}) | from_entries) as $status
  | [$prev[] | select(($status[.id] // "not_fixed") != "fixed")]
    + [.findings[] | {id: ($r + .id), title, severity, path, line, body}]
' "$agg" >"$round_dir/open-findings.json"

# Per-reviewer stats: raw findings as counted by the aggregator, confirmed = findings listing the reviewer.
jq -r --arg pr "$pr" --arg round "$round" '
  . as $a | $a.reviewers[]
  | .id as $id | [$pr, $round, $id, .raw_findings, ([$a.findings[] | select(.sources | index($id))] | length)] | @tsv
' "$agg" >"$round_dir/stats.tsv"

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
