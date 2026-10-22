#!/usr/bin/env bash
# Tests of the reviewer configuration and the quorum in scripts/review/run-reviewers.sh: reviewers.conf, the local
# override, --skip (PR_REVIEW_SKIP), --only (PR_REVIEW_REVIEWERS). Reviewers are stubs: no models, no network.
#
# Usage: scripts/review/test-reviewers.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# Stub reviewers: every Claude agent and OpenCode model returns a complete report; a lane reports one drift and one
# needs-decision finding. FAIL_AGENT=<agent> makes that agent fail.
mkdir -p "$work/bin"
cat >"$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
agent="" prompt=""
while [[ $# -gt 0 ]]; do case "$1" in --agent) agent="$2"; shift ;; -p) prompt="$2"; shift ;; esac; shift; done
[[ "$agent" == "${FAIL_AGENT:-}" ]] && exit 1
case "$agent" in
  review-checklist) r=$'# L1 checklist review\n| RC-01 | pass |' ;;
  review-bugs)      r=$'# L2 bug review\n## Findings\nnone' ;;
  review-lane)      lane="$(sed -n 's/.*Lane: `\([^`]*\)`.*/\1/p' <<<"$prompt")"
                    r="# L3 $lane review"$'\n## Findings\n### F1 — a\n- kind: drift\n### F2 — b\n- kind: needs-decision' ;;
  *)                exit 1 ;;
esac
jq -n --arg r "$r" '{is_error: false, result: $r, total_cost_usd: 0.01}'
STUB
printf '#!/usr/bin/env bash\nprintf "# L2 bug review\\n## Findings\\nnone\\n"\n' >"$work/bin/opencode"
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/gh"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" OPENCODE="$work/bin/opencode" PR_REVIEW_LOCAL_CONFIG="$work/reviewers.local"

# A delta round (the built-in /code-review skips itself there) with the db and guards lanes switched on.
round="$work/round"
mkdir -p "$round"/{raw,logs}
echo '{"pr": 1, "round": 2, "mode": "delta", "head_sha": "abc"}' >"$round/meta.json"
echo '{"setting": "auto", "lanes": [{"id": "db", "reasons": ["V1 added"]}, {"id": "guards", "reasons": ["pom.xml"]}]}' \
  >"$round/lanes.json"
for l in db guards; do mkdir -p "$round/bundle/lanes/$l"; touch "$round/bundle/lanes/$l/"{checklist,facts}.md; done

# run <expected exit> <name> [env assignments…]: fresh round unless KEEP=1, then checks on quorum.json via expect.
run() {
  local want="$1" name="$2" rc=0; shift 2
  [[ "${KEEP:-0}" == 1 ]] || rm -f "$round"/logs/* "$round"/raw/*
  env "$@" "$SCRIPTS/run-reviewers.sh" "$round" >/dev/null 2>"$work/err" || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, expected $want"; sed 's/^/  /' "$work/err"; failures=$((failures + 1))
  fi
}
expect() {  # expect <name> <jq filter that must be true on quorum.json>
  jq -e "$2" "$round/quorum.json" >/dev/null || {
    echo "FAIL $1: $2"; jq -c . "$round/quorum.json" | sed 's/^/  /'; failures=$((failures + 1)); }
}

: >"$work/reviewers.local"
run 0 default
expect default '.quorum and (.ok | length) == 6 and .skipped == ["code-review"] and .disabled == []
                and .lanes_required == ["lane-db", "lane-guards"]'

run 0 skip PR_REVIEW_SKIP=glm,lane-guards
expect skip '.quorum and .disabled == ["glm", "lane-guards"] and .lanes_required == ["lane-db"]
             and .lanes_disabled == ["lane-guards"] and (.ok | index("glm") | not)'
grep -q '^skipped 0 disabled' "$round/logs/glm.status" || { echo "FAIL skip: glm.status"; failures=$((failures + 1)); }

printf '# all of L2 off\nbugs-opus off\ndeepseek L2 off\nglm off\ncode-review off\n' >"$work/reviewers.local"
run 0 local-l2-off
expect local-l2-off '.quorum and .disabled == ["bugs-opus", "code-review", "deepseek", "glm"]'

: >"$work/reviewers.local"
run 0 unknown-skip PR_REVIEW_SKIP=nobody
expect unknown-skip '.quorum and .disabled == [] and (.skipped | index("nobody") | not)'

run 3 lane-fails FAIL_AGENT=review-lane
expect lane-fails '(.quorum | not) and .lanes_missing == ["lane-db", "lane-guards"]'

KEEP=1 run 0 only-reruns-failed PR_REVIEW_REVIEWERS="lane-db lane-guards"
expect only-reruns-failed '.quorum and (.ok | index("checklist")) != null'

run 3 l1-fails FAIL_AGENT=review-checklist
run 0 l1-off-then-not-required FAIL_AGENT=review-checklist PR_REVIEW_SKIP=checklist

if [[ $failures -gt 0 ]]; then echo "$failures reviewer config test(s) failed"; exit 1; fi
echo "all reviewer config tests passed"
