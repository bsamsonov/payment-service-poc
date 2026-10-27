#!/usr/bin/env bash
# Tests of scripts/review/fix.sh (auto-fix of confirmed findings) on a throwaway repository with a bare remote.
# The fixer (`claude`) and `gh` are stubs; the fast check is PR_REVIEW_FIX_VERIFY. No models, no network.
#
# Usage: scripts/review/test-fix.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# Stub fixer: what it does depends on the finding id in the prompt; an unknown id (F7) crashes with no output.
mkdir -p "$work/bin"
cat >"$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && { prompt="$2"; shift; }; shift; done
id="$(sed -n 's/^Fix finding \([^ ]*\) of PR.*/\1/p' <<<"$prompt")"
answer() { jq -n --arg s "$1" --arg r "$2" '{is_error: false, result: "", total_cost_usd: 0.1,
  structured_output: {status: $s, scope: "Payment", summary: "guard the stale read with the event version", reason: $r, files: []}}'; }
case "$id" in
  *-F1) echo "class A { int fixed; }" >src/A.java; answer fixed "missing guard" ;;
  *-F2) answer declined "needs owner: retry or fail fast" ;;
  *-F3) echo "changed" >>specs/001/spec.md; answer fixed "spec said so" ;;
  *-F4) touch BROKEN; answer fixed "breaks the build" ;;
  *-F5) answer declined "stale: already fixed at this commit" ;;
  *-F6) printf '@Disabled\nclass ATest {}\n' >src/ATest.java; answer fixed "flaky test" ;;
  *)    exit 1 ;;
esac
STUB
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
jq -n --arg h "$(git rev-parse "${GH_HEAD:-origin/feat/x}")" '{headRefName: "feat/x", headRefOid: $h,
  isCrossRepository: false, state: "OPEN"}'
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" PR_REVIEW_FIX_VERIFY='test ! -f BROKEN' PR_REVIEW_LOCAL_CONFIG="$work/reviewers.local"

# Remote with main and the PR branch feat/x; the clone carries the review scripts and the fixer prompt.
git init -q --bare -b main "$work/remote.git"
git clone -q "$work/remote.git" "$work/repo" 2>/dev/null
cd "$work/repo"
mkdir -p scripts src specs/001 .claude/agents
cp -r "$SRC/scripts/review" scripts/
cp "$SRC/.claude/agents/review-fixer.md" .claude/agents/
echo "class A {}" >src/A.java
echo "spec" >specs/001/spec.md
printf '.review/\n' >.gitignore
git add -A && git commit -qm base && git push -q origin main
git checkout -qb feat/x && echo "class B {}" >src/B.java && git add -A && git commit -qm "feat: b" && git push -q -u origin feat/x
head="$(git rev-parse HEAD)"
git checkout -q main

round=".review/1/1"
new_round() {
  rm -rf .review/1 && mkdir -p "$round/bundle" "$round/logs"
  jq -n --arg h "$head" '{pr: 1, round: 1, mode: "full", head_sha: $h, base_ref: "main"}' >"$round/meta.json"
  jq -n '{findings: [range(1; 8) | {id: "F\(.)", severity: (if . == 1 then "major" else "minor" end), rule: "",
          title: "t\(.)", path: "src/A.java", line: 1, body: "b", sources: ["bugs-opus"], in_diff: true}],
          rejected: [], previous: [], reviewers: [{id: "bugs-opus", raw_findings: 7}]}' >"$round/aggregate.json"
  printf 'pr\tround\treviewer\tfound\tconfirmed\n1\t1\tbugs-opus\t7\t7\n' >"$round/stats.tsv"
  printf '# report\n' >"$round/report.md"
}
status_of() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .status' "$round/fixes.json"; }

# 1. All outcomes in one round, pushed.
new_round
scripts/review/fix.sh "$round" 2>"$work/err" || { fail "fix.sh exit $?"; cat "$work/err"; }
for pair in R1-F1:fixed R1-F2:owner R1-F3:owner R1-F4:not_fixed R1-F5:not_fixed R1-F6:owner R1-F7:not_fixed; do
  [[ "$(status_of "${pair%%:*}")" == "${pair#*:}" ]] || fail "status of ${pair%%:*}: $(status_of "${pair%%:*}"), want ${pair#*:}"
done
jq -e '.pushed' "$round/fixes.json" >/dev/null || fail "not pushed: $(jq -r .push_error "$round/fixes.json")"
git fetch -q origin
[[ "$(git rev-list --count "$head"..origin/feat/x)" == 1 ]] || fail "expected one fix commit on feat/x"
subject="$(git log -1 --format=%s origin/feat/x)"
[[ "$subject" == "fix(payment): guard the stale read with the event version (R1-F1)" ]] || fail "subject: $subject"
[[ "$(git show origin/feat/x:src/A.java)" == "class A { int fixed; }" ]] || fail "fix content"
git show origin/feat/x:specs/001/spec.md | grep -q changed && fail "protected change reached the branch"
[[ -d "$round/worktree" ]] && fail "worktree kept after push"
grep -qP '^1\t1\tfixer\t7\t1\tfix\tok\t' "$round/stats.tsv" || fail "stats row: $(grep fixer "$round/stats.tsv")"
grep -q '^## Auto-fix' "$round/report.md" || fail "report section"

# 2. A second run of the same round does nothing without --force.
scripts/review/fix.sh "$round" 2>/dev/null
[[ "$(grep -c fixer "$round/stats.tsv")" == 1 ]] || fail "re-run duplicated the stats row"

# 3. The PR head moved since the review → not run.
new_round
scripts/review/fix.sh "$round" 2>/dev/null   # origin/feat/x is now ahead of the reviewed head
jq -e '.status == "skipped" and (.reason | test("head moved"))' "$round/fixes.json" >/dev/null || fail "head moved: $(jq -c . "$round/fixes.json")"

# 4. Push off → commits stay in the worktree.
git push -q -f origin "$head:refs/heads/feat/x"
new_round
PR_REVIEW_FIX_PUSH=0 scripts/review/fix.sh "$round" 2>/dev/null
jq -e '(.pushed | not) and (.push_error | test("switched off"))' "$round/fixes.json" >/dev/null || fail "push off"
[[ -d "$round/worktree" ]] || fail "worktree removed although the commits were not pushed"
git worktree remove --force "$round/worktree"

# 5. Switched off in the local override and with PR_REVIEW_FIX=0.
new_round; echo "fixer off" >"$work/reviewers.local"
scripts/review/fix.sh "$round" 2>/dev/null
jq -e '.status == "skipped" and (.reason | test("switched off"))' "$round/fixes.json" >/dev/null || fail "fixer off"
: >"$work/reviewers.local"
new_round; PR_REVIEW_FIX=0 scripts/review/fix.sh "$round" 2>/dev/null
jq -e '.status == "skipped"' "$round/fixes.json" >/dev/null || fail "PR_REVIEW_FIX=0"

if [[ $failures -gt 0 ]]; then echo "$failures auto-fix test(s) failed"; exit 1; fi
echo "all auto-fix tests passed"
