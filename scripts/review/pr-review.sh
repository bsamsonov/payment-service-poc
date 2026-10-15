#!/usr/bin/env bash
# /pr-review pipeline: bundle (+ specialist lanes) → reviewers (parallel, quorum) → aggregation → auto-fix of the
# confirmed findings → review guide → publication → one delta round over the fix commits.
#
# Usage: scripts/review/pr-review.sh <pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish]
#                                         [--lanes=<lane,…> | --no-lanes] [--skip=<id,…>] [--only=<id,…>]
#                                         [--no-fix]
#   --delta           review only the commits pushed since the previous round
#   --allow-degraded  continue when the quorum is not met (recorded in the report)
#   --no-guide        skip the review guide (guide.sh can be run later on the same round)
#   --no-publish      stop before publication (report.md / guide.md stay local); no auto-fix either
#   --no-fix          do not fix the confirmed findings (also: `fixer off` in reviewers.conf / .review/reviewers.local)
#   --lanes=db,api    run exactly these specialist lanes (L3) instead of the ones the diff switches on
#   --no-lanes        run no specialist lanes
#   --skip=glm,deepseek  switch these reviewers off for this run (recorded as skipped; see reviewers.conf)
#   --only=checklist,bugs-opus  run just these reviewers (lanes as lane-<id>); others keep earlier results of the round
# Reviewers on/off by default: scripts/review/reviewers.conf; personal override: .review/reviewers.local.
# Env: PR_REVIEW_REVIEWERS, PR_REVIEW_SKIP, PR_REVIEW_TIMEOUT (see run-reviewers.sh), PR_REVIEW_LANES, PR_REVIEW_LANE_TOOLS
#      (see lanes.py)
#
# Exit codes: 0 ok, 1 error, 3 quorum not met.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pr="${1:?usage: pr-review.sh <pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish] [--lanes=<list> | --no-lanes] [--skip=<list>] [--only=<list>] [--no-fix]}"
shift
delta=() degraded=() publish=true guide=true fix=true pass=()
for arg in "$@"; do
  [[ "$arg" == --delta || "$arg" == --no-fix ]] || pass+=("$arg")  # flags for the delta round after the fixes
  case "$arg" in
    --delta)          delta=(--delta) ;;
    --allow-degraded) degraded=(--allow-degraded) ;;
    --no-guide)       guide=false ;;
    --no-publish)     publish=false ;;
    --no-fix)         fix=false ;;
    --lanes=*)        export PR_REVIEW_LANES="${arg#--lanes=}" ;;
    --no-lanes)       export PR_REVIEW_LANES=none ;;
    --skip=*)         export PR_REVIEW_SKIP="${arg#--skip=}" ;;
    --only=*)         export PR_REVIEW_REVIEWERS="${arg#--only=}"; PR_REVIEW_REVIEWERS="${PR_REVIEW_REVIEWERS//,/ }" ;;
    *)                die "unknown option: $arg" ;;
  esac
done

warn_if_tooling_differs_from_main
round_dir="$("$SCRIPTS_DIR/bundle.sh" "$pr" "${delta[@]}")"
"$SCRIPTS_DIR/run-reviewers.sh" "$round_dir" "${degraded[@]}"
"$SCRIPTS_DIR/aggregate.sh" "$round_dir"
# Fixes are pushed to the PR, so they run only together with publication. A failed auto-fix does not stop the round:
# its findings are published as not fixed.
if [[ "$fix" == true && "$publish" == true ]]; then
  "$SCRIPTS_DIR/fix.sh" "$round_dir" || log "WARNING: auto-fix failed; findings are published without fixes"
fi
# A failed guide does not hold back the findings: they are published anyway, the guide can be re-run alone.
if [[ "$guide" == true ]]; then
  "$SCRIPTS_DIR/guide.sh" "$round_dir" >/dev/null || log "WARNING: review guide failed; findings are published without it"
fi
if [[ "$publish" == true ]]; then
  "$SCRIPTS_DIR/publish.sh" "$round_dir"
fi

rel="${round_dir#"$REPO_ROOT"/}"
echo "round:   $rel"
echo "report:  $rel/report.md"
echo "guide:   $rel/guide.md"
echo "stats:   $rel/stats.tsv"
echo "summary: $(jq -r '[.findings[] | .severity] | group_by(.) | map("\(.[0]): \(length)") | join(", ") | if . == "" then "no findings" else . end' "$round_dir/aggregate.json")"
if [[ -f "$round_dir/fixes.json" ]]; then
  echo "fixes:   $(jq -r 'if .status != "done" then "not run (\(.reason))" else
    ([.items[] | .status] | group_by(.) | map("\(.[0]): \(length)") | join(", "))
    + (if .pushed then ", pushed to \(.branch)" else " (\(.push_error))" end) end' "$round_dir/fixes.json")"
fi

# One delta round over the fix commits: confirms the fixes (previous findings) and catches regressions. It never
# fixes again, so the pipeline cannot loop; its findings go to the owner.
if [[ -f "$round_dir/fixes.json" ]] && jq -e '.pushed == true' "$round_dir/fixes.json" >/dev/null; then
  log "fixes pushed: running one delta round over them"
  exec "$SCRIPTS_DIR/pr-review.sh" "$pr" --delta --no-fix "${pass[@]}"
fi
