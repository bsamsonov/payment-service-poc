#!/usr/bin/env bash
# Checks that acceptance criteria (ACs) in specs/ and acceptance tests reference each other.
#
# Usage: scripts/spec/check-ac-trace.sh [repo-root]
#
# Spec side: specs/NNN-name/spec.md, front matter `status:`, AC lines `- **AC-n** …`.
#   An AC line containing "(superseded by" is inactive; all ACs of a `Superseded` spec are inactive.
# Test side: `@DisplayName("NNN/AC-n: …")` in src/test/java (several ids allowed: "001/AC-1, 001/AC-2: …").
#
# Errors (exit 1):
#   - a test references an AC that does not exist or is inactive;
#   - a test uses an unqualified id (`AC-n:` without the spec number);
#   - an active AC of an `Implemented` spec has no test.
# Warnings: an active AC of an `Approved` spec has no test (the feature PR is in progress).
# `Draft` specs: their ACs are valid references but coverage is not checked.
set -euo pipefail

root="${1:-.}"
specs_dir="$root/specs"
tests_dir="$root/src/test/java"

errors=0
warnings=0
err() { echo "ERROR: $*"; errors=$((errors + 1)); }
warn() { echo "WARN:  $*"; warnings=$((warnings + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Spec side: "NNN/AC-n<TAB>state<TAB>status" per AC; state is active|inactive.
: >"$tmp/acs"
for spec in "$specs_dir"/[0-9][0-9][0-9]-*/spec.md; do
    [[ -e "$spec" ]] || continue
    id="$(basename "$(dirname "$spec")")"
    id="${id:0:3}"
    status="$(awk '/^---$/{n++; next} n==1 && /^status:/{print $2; exit}' "$spec")"
    case "$status" in
        Draft | Approved | Implemented | Superseded) ;;
        *) err "$spec: unknown or missing status '$status'"; continue ;;
    esac
    { grep -oE '^- \*\*AC-[0-9]+\*\*.*' "$spec" || true; } | while IFS= read -r line; do
        n="$(sed -E 's/^- \*\*AC-([0-9]+)\*\*.*/\1/' <<<"$line")"
        state=active
        if [[ "$status" == Superseded || "$line" == *"(superseded by"* ]]; then state=inactive; fi
        printf '%s/AC-%s\t%s\t%s\n' "$id" "$n" "$state" "$status"
    done >>"$tmp/acs"
done

# --- Test side: "file:line<TAB>display name" per @DisplayName, joining an annotation split across lines.
: >"$tmp/names"
if [[ -d "$tests_dir" ]]; then
    find "$tests_dir" -name '*.java' -print0 | sort -z | while IFS= read -r -d '' f; do
        awk -v f="$f" '
            open == 0 && /@DisplayName\(/ { open = 1; start = FNR; buf = "" }
            open == 1 {
                buf = buf $0
                if ($0 ~ /"[[:space:]]*\)/) {
                    sub(/.*@DisplayName\([[:space:]]*"/, "", buf)
                    sub(/"[[:space:]]*\).*/, "", buf)
                    printf "%s:%d\t%s\n", f, start, buf
                    open = 0
                }
            }' "$f"
    done >"$tmp/names"
fi

# --- References: "NNN/AC-n<TAB>file:line" per id found in a display name.
: >"$tmp/refs"
while IFS=$'\t' read -r loc name; do
    rest="$name"
    while [[ "$rest" =~ ([0-9]{3}/AC-[0-9]+) ]]; do
        printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$loc" >>"$tmp/refs"
        rest="${rest#*"${BASH_REMATCH[1]}"}"
    done
    unqualified="$(sed -E 's#[0-9]{3}/AC-[0-9]+##g' <<<"$name")"
    if [[ "$unqualified" =~ (^|[^A-Za-z0-9/])AC-[0-9]+ ]]; then
        err "$loc: unqualified AC id in \"$name\" (use NNN/AC-n)"
    fi
done <"$tmp/names"

# --- Every reference points to an existing active AC.
while IFS=$'\t' read -r ac loc; do
    state="$(awk -F'\t' -v ac="$ac" '$1 == ac {print $2; exit}' "$tmp/acs")"
    case "$state" in
        active) ;;
        inactive) err "$loc: $ac is superseded; reference the AC that replaced it" ;;
        *) err "$loc: $ac does not exist in specs/" ;;
    esac
done <"$tmp/refs"

# --- Every active AC of an Approved/Implemented spec has a test.
while IFS=$'\t' read -r ac state status; do
    [[ "$state" == active ]] || continue
    tests="$(awk -F'\t' -v ac="$ac" '$1 == ac {print $2}' "$tmp/refs" | paste -sd ' ' -)"
    if [[ -n "$tests" ]]; then
        echo "ok     $ac  $tests"
    elif [[ "$status" == Implemented ]]; then
        err "$ac has no test (spec is Implemented)"
    elif [[ "$status" == Approved ]]; then
        warn "$ac has no test yet (spec is Approved)"
    fi
done <"$tmp/acs"

echo "AC trace: $(wc -l <"$tmp/acs") ACs, $(wc -l <"$tmp/refs") test references, $errors error(s), $warnings warning(s)"
[[ "$errors" -eq 0 ]]
