#!/usr/bin/env bash
# Tests for check-ac-trace.sh on throwaway fixture repositories.
# Usage: scripts/spec/test-check-ac-trace.sh
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check-ac-trace.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# spec <repo> <NNN> <status> <AC line>...
spec() {
    local repo="$1" id="$2" status="$3"
    shift 3
    mkdir -p "$repo/specs/$id-x"
    {
        printf -- '---\nid: %s\nstatus: %s\n---\n\n## Acceptance criteria\n' "$id" "$status"
        printf -- '%s\n' "$@"
    } >"$repo/specs/$id-x/spec.md"
}

# test_class <repo> <name> <java body>
test_class() {
    mkdir -p "$1/src/test/java/t"
    printf 'package t;\nclass %s {\n%s\n}\n' "$2" "$3" >"$1/src/test/java/t/$2.java"
}

# expect <case> <exit code> <grep pattern or ""> <repo>
expect() {
    local name="$1" want="$2" pattern="$3" repo="$4" out code=0
    out="$("$check" "$repo" 2>&1)" || code=$?
    if [[ "$code" -ne "$want" ]] || { [[ -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$out"; }; then
        echo "FAIL: $name (exit $code, want $want; pattern '$pattern')"
        sed 's/^/    /' <<<"$out"
        failures=$((failures + 1))
    else
        echo "ok:   $name"
    fi
}

r="$work/empty"; mkdir -p "$r"
expect "no specs, no tests" 0 "0 ACs" "$r"

r="$work/covered"
spec "$r" 001 Implemented '- **AC-1** Given a, then b.' '- **AC-2** Given c, then d.'
test_class "$r" CoveredTest '    @DisplayName("001/AC-1, 001/AC-2: both covered") void t() {}'
expect "implemented spec, all ACs covered" 0 "ok     001/AC-2" "$r"

r="$work/split"
spec "$r" 001 Implemented '- **AC-1** Given a, then b.'
test_class "$r" SplitTest '    @DisplayName(
            "001/AC-1: annotation split across lines")
    void t() {}'
expect "display name split across lines" 0 "ok     001/AC-1" "$r"

r="$work/missing"
spec "$r" 001 Implemented '- **AC-1** Given a, then b.' '- **AC-2** Given c, then d.'
test_class "$r" OneTest '    @DisplayName("001/AC-1: only one") void t() {}'
expect "implemented spec, AC without test" 1 "ERROR: 001/AC-2 has no test" "$r"

r="$work/approved"
spec "$r" 001 Approved '- **AC-1** Given a, then b.'
expect "approved spec, AC without test only warns" 0 "WARN:  001/AC-1" "$r"

r="$work/draft"
spec "$r" 001 Draft '- **AC-1** Given a, then b.'
test_class "$r" DraftTest '    @DisplayName("001/AC-1: draft reference") void t() {}'
expect "draft spec: reference is valid, no coverage check" 0 "0 error" "$r"

r="$work/unknown"
spec "$r" 001 Approved '- **AC-1** Given a, then b.'
test_class "$r" UnknownTest '    @DisplayName("001/AC-1, 001/AC-9: typo") void t() {}'
expect "reference to a missing AC" 1 "001/AC-9 does not exist" "$r"

r="$work/superseded-ac"
spec "$r" 001 Implemented '- **AC-1** Given a, then b.' '- **AC-2** (superseded by 002/AC-1) Given c, then d.'
spec "$r" 002 Approved '- **AC-1** Given c, then e.'
test_class "$r" OldTest '    @DisplayName("001/AC-1: kept") void a() {}
    @DisplayName("001/AC-2: replaced") void b() {}'
expect "reference to a superseded AC" 1 "001/AC-2 is superseded" "$r"
rm "$r/src/test/java/t/OldTest.java"
test_class "$r" NewTest '    @DisplayName("001/AC-1: kept") void a() {}
    @DisplayName("002/AC-1: replacement") void b() {}'
expect "superseded AC needs no test" 0 "0 error" "$r"

r="$work/superseded-spec"
spec "$r" 001 Superseded '- **AC-1** Given a, then b.'
expect "superseded spec needs no tests" 0 "0 error" "$r"

r="$work/unqualified"
spec "$r" 001 Approved '- **AC-2** Given a, then b.'
test_class "$r" LegacyTest '    @DisplayName("AC-2: no spec number") void t() {}'
expect "unqualified AC id" 1 "unqualified AC id" "$r"

r="$work/bad-status"
spec "$r" 001 Done '- **AC-1** Given a, then b.'
expect "unknown status" 1 "unknown or missing status" "$r"

echo
if [[ "$failures" -ne 0 ]]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
