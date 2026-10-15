# Renders guide.md from guide.json (schema: guide.schema.json) and, when the round has one, aggregate.json.
# Usage: jq -r --arg round N --arg mode full|delta --slurpfile agg <aggregate.json or /dev/null>
#           --slurpfile q <quorum.json or /dev/null> --rawfile map <component-map.md, may be empty>
#           -f render-guide.jq guide.json
# The top three attention items are expanded; the rest are one line each plus the question.
def loc: "`\(.path):\(.line)`";
def full($n):
  "- [ ] **\($n). \(.title)** · `\(.category)` · \(loc) · decide: `\(.decide_by)`\n" +
  "  _Decided here:_ \(.decision)\n" +
  "  _Why it matters later:_ \(.why_later)\(if (.affects | length) > 0 then " (" + (.affects | join(", ")) + ")" else "" end)\n" +
  "  _Options:_ \(.options | join(" · "))\n" +
  "  _Lean:_ \(.lean)\n" +
  "  _Checked:_ \(.checked)\n" +
  (if .verify != "" then "  _Verify yourself:_ \(.verify)\n" else "" end) +
  "  _Decide:_ \(.question)";
def short($n):
  "- [ ] **\($n). \(.title)** · `\(.category)` · \(loc) · decide: `\(.decide_by)`\n" +
  "  _Decide:_ \(.question) _Lean:_ \(.lean)";

($agg | first) as $a
| ($q | first) as $quorum
| "## Review guide — round \($round)\(if $mode == "delta" then " (changes since the previous round)" else "" end)\n",
  (if $quorum != null and ($quorum.quorum | not) then
     "> **Degraded AI review**: failed reviewers: \($quorum.failed | join(", ")).\n" else empty end),
  "### What changed",
  (.summary[] | "- \(.)"),
  (if ($map | test("\\S")) then "", "### Component map", "", ($map | rtrimstr("\n")) else empty end),
  "",
  "### Architect's attention",
  (if (.attention | length) == 0 then "- no decision in this PR needs your judgement"
   else
     (if (.attention | length) > 3 then "_If you have time for only three, take 1–3._" else empty end),
     (.attention | to_entries[] | (.key + 1) as $n | .value | if $n <= 3 then full($n) else short($n) end)
   end),
  "",
  (if (.previous | length) > 0 then
     "**Earlier attention items**", (.previous[] | "- \(.title): \(.status) — \(.note)"), ""
   else empty end),
  "### Read line by line",
  (if (.must_review | length) == 0 then "- nothing flagged" else
     (.must_review | to_entries[] | "- [ ] **\(.key + 1).** \(.value | loc) — \(.value.risk)\n  _Ask yourself:_ \(.value.question)") end),
  "",
  (if (.out_of_scope | length) > 0 then
     "### Outside the declared scope", (.out_of_scope[] | "- \(.what) — \(.note)"), ""
   else empty end),
  "### Findings (posted as review comments)",
  (if $a == null then "- AI review was not run for this head"
   elif ($a.findings | length) == 0 then "- none"
   else ($a.findings[] | "- [ ] **\(.id)** \(.severity)\(if .rule != "" then " · " + .rule else "" end) — \(.title) (\(loc))") end),
  (if $a != null and ($a.previous | length) > 0 then
     "", "**Previous findings**", ($a.previous[] | "- \(.id): \(.status) — \(.note)") else empty end),
  "",
  "### Can be skimmed",
  (if (.skim | length) == 0 then "- nothing" else (.skim[] | "- \(.what) — \(.why)") end),
  "",
  "<details><summary>Sensitive paths checked, no decision needed (\(.cleared | length))</summary>\n",
  (.cleared[] | "- \(.what) — \(.why)"),
  (if (.not_assessed | length) > 0 then "\n**Not assessed**", (.not_assessed[] | "- \(.)") else empty end),
  (if (.defects_seen | length) > 0 then
     "\n**Possible defects seen in passing (not verified)**", (.defects_seen[] | "- \(.)")
   else empty end),
  "\n</details>\n",
  "<sub>Review guide by `review-guide`\(if $quorum != null then "; AI reviewers: \($quorum.ok | join(", "))" else "" end)."
  + "\(if $a != null then " Close each finding with a fix commit or a reply explaining why it is not a bug." else "" end)</sub>"
