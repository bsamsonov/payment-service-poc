#!/usr/bin/env bash
# Aggregate raw reviewer reports of a round with the review-aggregator subagent and render the results:
#   aggregate.json — structured result (schema: aggregate.schema.json)
#   report.md      — confirmed and rejected findings, reviewer stats
#   stats.tsv      — one row per reviewer of the round and one for the aggregator (header row first):
#                    pr, round, reviewer, found, confirmed, level, status, seconds, cost_usd, rejected,
#                    decisions (rejected as "design decision" → Architect's attention), drift, needs_decision
#                    (L3 lanes: kinds of findings in the raw report), confirmed_ids
#
# Usage: scripts/review/aggregate-findings.sh <round-dir> [--reuse]
#   --reuse  do not call the aggregator again; re-render from logs/aggregator.json
# The guide for the human reviewer is written by write-review-guide.sh from the same round.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: aggregate-findings.sh <round-dir> [--reuse]}"
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
  agg_start=$SECONDS
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
  echo "ok $(( SECONDS - agg_start )) 0" >"$round_dir/logs/aggregator.time"
fi
jq -e '.is_error == false' "$round_dir/logs/aggregator.json" >/dev/null \
  || die "aggregator reported an error, see $round_rel/logs/aggregator.json"

# Structured output when --json-schema is honoured; otherwise the JSON object from the text result
# (the agent is instructed to answer with JSON only, possibly inside a ```json fence).
# aggregate.json marks the round as reviewed (delta rounds start from it), so it appears only after validation;
# a failed re-aggregation keeps the previous valid file (mv replaces it atomically).
tmp="$round_dir/aggregate.json.tmp"
jq -e '(.structured_output | type) == "object"' "$round_dir/logs/aggregator.json" >/dev/null \
  || log "WARNING: no structured output, the schema was not applied (is StructuredOutput in the agent's tools?);" \
       "parsing the text result"
jq 'if (.structured_output | type) == "object" then .structured_output
    else .result | sub("^[^{]*"; "") | sub("[^}]*$"; "") | fromjson end' \
  "$round_dir/logs/aggregator.json" >"$tmp" 2>/dev/null \
  || die "aggregator output is not valid JSON, see $round_rel/logs/aggregator.json"
jq -e 'has("findings") and has("rejected") and has("previous")
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

# Stats: one row per reviewer that has a status in the round (ok, failed, skipped — also switched off) and one for
# the aggregator. Time from logs/<id>.status, cost from logs/<id>.json (Claude runs only; OpenCode reports none),
# found = distinct findings as counted by the aggregator, confirmed = findings listing the reviewer as a source.
stats_rows() {
  local f id status secs rc level cost drift nd
  for f in "$round_dir"/logs/*.status; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .status)"
    read -r status secs rc <"$f"
    [[ "$status" == skipped && "$rc" == disabled ]] && status="skipped:disabled"
    level="$(reviewer_config | awk -v id="$id" '$1 == id {print $2}')"
    [[ -n "$level" ]] || level="$([[ "$id" == lane-* ]] && echo L3 || echo '?')"
    cost="$(jq -r '.total_cost_usd // empty' "$round_dir/logs/$id.json" 2>/dev/null || true)"
    drift="" nd=""
    if [[ "$id" == lane-* && -f "$round_dir/raw/$id.md" ]]; then
      drift="$(grep -cE '^- kind: *drift' "$round_dir/raw/$id.md" || true)"
      nd="$(grep -cE '^- kind: *needs-decision' "$round_dir/raw/$id.md" || true)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$level" "$status" "$secs" "$cost" "$drift" "$nd"
  done
  secs=""
  [[ -f "$round_dir/logs/aggregator.time" ]] && read -r _ secs _ <"$round_dir/logs/aggregator.time"
  printf 'aggregator\tagg\tok\t%s\t%s\t\t\n' "$secs" "$(jq -r '.total_cost_usd // empty' "$round_dir/logs/aggregator.json")"
}
{
  printf 'pr\tround\treviewer\tfound\tconfirmed\tlevel\tstatus\tseconds\tcost_usd\trejected\tdecisions\tdrift\tneeds_decision\tconfirmed_ids\n'
  stats_rows | jq -R -r --arg pr "$pr" --arg round "$round" --slurpfile a "$agg" '
    def src($id): .source | split("[ ,;/]+"; null) | index($id) != null;
    def decision: .reason | test("design decision"; "i");
    $a[0] as $a | split("\t") as [$id, $level, $status, $secs, $cost, $drift, $nd]
    | if $id == "aggregator" then
        [$pr, $round, $id, ([$a.reviewers[].raw_findings] | add // 0), ($a.findings | length),
         $level, $status, $secs, $cost, ($a.rejected | length), ([$a.rejected[] | select(decision)] | length),
         "", "", ([$a.findings[].id] | join(","))]
      else
        ([$a.findings[] | select(.sources | index($id))]) as $conf
        | [$pr, $round, $id,
           (if $status == "ok" then ([$a.reviewers[] | select(.id == $id) | .raw_findings] | first // 0) else "" end),
           ($conf | length), $level, $status, $secs, $cost, ([$a.rejected[] | select(src($id))] | length),
           ([$a.rejected[] | select(src($id) and decision)] | length), $drift, $nd, ([$conf[].id] | join(","))]
      end
    | map(tostring) | @tsv'
} >"$round_dir/stats.tsv"

lanes='{"lanes": []}'  # rounds bundled before lanes existed
[[ -f "$round_dir/lanes.json" ]] && lanes="$(cat "$round_dir/lanes.json")"
jq -r --arg pr "$pr" --arg round "$round" --arg mode "$mode" --slurpfile q "$round_dir/quorum.json" \
  --argjson l "$lanes" '
  def loc: "`\(.path):\(.line)`";
  "# /pr-review report — PR #\($pr), round \($round) (\($mode))\n",
  "Reviewers ok: \($q[0].ok | join(", ")); failed: \(if ($q[0].failed | length) == 0 then "none" else ($q[0].failed | join(", ")) end)" +
    (if ($q[0].skipped // [] | length) > 0
     then "; skipped: \($q[0].skipped | map(if (. as $id | $q[0].disabled // [] | index($id)) then . + " (switched off)" else . end) | join(", "))"
     else "" end) +
    (if $q[0].quorum then "" else " — **degraded run, quorum not met**" end) + "\n",
  (if ($l.lanes | length) > 0
   then "## Specialist lanes (L3)\n",
        "Switched on by the diff of the round (`lanes.json`):",
        ($l.lanes[] | ("lane-" + .id) as $id
          | "- **\(.id)**\(if ($q[0].lanes_disabled // [] | index($id)) then " — switched off, not reviewed"
                          elif ($q[0].lanes_missing // [] | index($id)) then " — **not reviewed (failed)**" else "" end): " +
            (.reasons[:5] | join("; ")) + (if (.reasons | length) > 5 then "; and \(.reasons | length - 5) more" else "" end)),
        ""
   else "Specialist lanes: none switched on\n" end),
  "## Confirmed findings (\(.findings | length))\n",
  (.findings[] | "### \(.id) · \(.severity)\(if .rule != "" then " · " + .rule else "" end) — \(.title)\n" +
     "- location: \(loc)\(if .in_diff then "" else " (outside the diff)" end)\n- reported by: \(.sources | join(", "))\n\n\(.body)\n"),
  (if (.previous | length) > 0 then "## Previous findings\n", (.previous[] | "- \(.id): \(.status) — \(.note)"), "" else empty end),
  "## Rejected (\(.rejected | length))\n",
  (.rejected[] | "- [\(.source)] \(.title) — \(.reason)")
' "$agg" >"$round_dir/report.md"

log "aggregated: $(jq '.findings | length' "$agg") confirmed, $(jq '.rejected | length' "$agg") rejected → $round_rel/report.md"
