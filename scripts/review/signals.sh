#!/usr/bin/env bash
# Deterministic facts about a PR diff for the human review guide: size by area, sensitive paths, markers in added
# lines. No judgement here — the review-guide agent must account for every sensitive path it lists.
#
# Usage: scripts/review/signals.sh <patch-file> > bundle/signals.md
#   <patch-file>  the full PR diff with a/ b/ prefixes (pr.patch of the round, not the delta)
set -euo pipefail

patch="${1:?usage: signals.sh <patch-file>}"
[[ -s "$patch" ]] || { echo "signals.sh: empty or missing patch: $patch" >&2; exit 1; }

# One record per added line: path<TAB>line-in-post-change-file<TAB>text; and one per file: status, added, removed.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk -v files="$tmp/files.tsv" -v added="$tmp/added.tsv" '
  function flush() { if (path != "") printf "%s\t%s\t%d\t%d\n", path, status, plus, minus > files }
  /^diff --git / { flush(); path = ""; status = "modified"; plus = 0; minus = 0; inhunk = 0; next }
  /^new file mode/ && !inhunk { status = "added"; next }
  /^deleted file mode/ && !inhunk { status = "deleted"; next }
  /^rename to / && !inhunk { status = "renamed"; next }
  /^--- / && !inhunk { if ($0 != "--- /dev/null") path = substr($0, 7); next }
  /^\+\+\+ / && !inhunk { if ($0 != "+++ /dev/null") path = substr($0, 7); next }
  /^@@ / { split($3, a, ","); line = substr(a[1], 2) + 0; inhunk = 1; next }
  inhunk && /^\+/ { plus++; printf "%s\t%d\t%s\n", path, line, substr($0, 2) > added; line++; next }
  inhunk && /^-/ { minus++; next }
  inhunk && /^ / { line++; next }
  END { flush() }
' "$patch"
touch "$tmp/files.tsv" "$tmp/added.tsv"

area() {
  case "$1" in
    src/main/resources/db/migration/*) echo "migrations" ;;
    api/*) echo "contract" ;;
    src/main/java/*/domain/*) echo "main: domain" ;;
    src/main/java/*/application/*) echo "main: application" ;;
    src/main/java/*/adapter/in/*) echo "main: adapter.in" ;;
    src/main/java/*/adapter/out/*) echo "main: adapter.out" ;;
    src/main/java/*/config/*) echo "main: config" ;;
    src/main/java/*) echo "main: other" ;;
    src/main/resources/*) echo "runtime config" ;;
    src/test/*) echo "tests" ;;
    pom.xml|config/*|.mvn/*|mvnw*) echo "build and analyzers" ;;
    .github/*|.claude/*|scripts/*|lefthook.yml) echo "CI, hooks, agent tooling" ;;
    specs/*) echo "specs" ;;
    *) echo "docs and other" ;;
  esac
}

# Why a path always deserves a look. Empty output = not sensitive.
sensitive() {
  local path="$1" status="$2"
  case "$path" in
    src/main/resources/db/migration/*)
      if [[ "$status" == "added" ]]; then echo "new migration: permanent once merged"
      else echo "EXISTING migration $status: merged migrations must not change (RC-12)"; fi ;;
    api/*) echo "public contract" ;;
    pom.xml) echo "build: dependencies, plugins, gates" ;;
    src/main/resources/application*) echo "global runtime configuration" ;;
    src/main/java/*/config/*) echo "wiring and global beans" ;;
    src/test/java/*ArchitectureTest.java|src/test/java/*HexagonRules*|src/test/java/*ModuleRules*|src/test/java/*TestConventionsTest.java|src/test/java/archfixture/*)
      echo "architecture rules themselves" ;;
    config/*) echo "analyzer configuration or exclusions" ;;
    .github/*) echo "CI, required checks, ownership" ;;
    .claude/*|lefthook.yml|scripts/*) echo "hooks and agent tooling" ;;
    AGENTS.md|CLAUDE.md|docs/review-*.md|specs/README.md|specs/_template/*) echo "project rules and process" ;;
    docs/adr/*) echo "architecture decision record" ;;
    specs/*/spec.md) echo "spec text or status" ;;
  esac
}

total_files="$(wc -l <"$tmp/files.tsv")"
total_plus="$(awk -F'\t' '{s += $3} END {print s + 0}' "$tmp/files.tsv")"
total_minus="$(awk -F'\t' '{s += $4} END {print s + 0}' "$tmp/files.tsv")"
handwritten="$(awk -F'\t' '$1 ~ /^src\/main\/java\// {s += $3} END {print s + 0}' "$tmp/files.tsv")"

echo "# Signals (computed from the PR diff, no judgement)"
echo
echo "## Size"
echo "- $total_files files, +$total_plus / -$total_minus lines; production Java added: $handwritten lines" \
  "(project guideline: about 600 per PR)"
echo
echo "| Area | Files | Added | Removed |"
echo "|---|---|---|---|"
while IFS=$'\t' read -r path status plus minus; do
  printf '%s\t%s\t%s\n' "$(area "$path")" "$plus" "$minus"
done <"$tmp/files.tsv" \
  | awk -F'\t' '{f[$1]++; p[$1] += $2; m[$1] += $3} END {for (a in f) printf "| %s | %d | %d | %d |\n", a, f[a], p[a], m[a]}' \
  | sort -t'|' -k4,4nr

echo
echo "## Sensitive paths"
echo "Each line must be accounted for in the guide: an attention or line-by-line item, or an entry in \`cleared\` with the reason."
echo
found=false
while IFS=$'\t' read -r path status plus minus; do
  reason="$(sensitive "$path" "$status")"
  [[ -n "$reason" ]] || continue
  found=true
  echo "- \`$path\` ($status, +$plus/-$minus) — $reason"
done <"$tmp/files.tsv"
[[ "$found" == true ]] || echo "- none"

echo
echo "## New dependencies (added \`<artifactId>\` lines in pom.xml)"
deps="$(awk -F'\t' '$1 == "pom.xml" && $3 ~ /<artifactId>/ {gsub(/^[ \t]+|<\/?artifactId>/, "", $3); printf "- `%s` (pom.xml:%s)\n", $3, $2}' "$tmp/added.tsv")"
echo "${deps:-- none}"

# Markers in added lines: label, extended regex, path filter (regex).
marker() {
  local label="$1" regex="$2" paths="$3" hits
  hits="$(awk -F'\t' -v re="$regex" -v pre="$paths" '$1 ~ pre && $3 ~ re {printf "`%s:%s`\n", $1, $2}' "$tmp/added.tsv")"
  [[ -n "$hits" ]] || return 0
  echo "- **$label** ($(wc -l <<<"$hits")): $(head -6 <<<"$hits" | paste -sd, - | sed 's/,/, /g')$( (( $(wc -l <<<"$hits") > 6 )) && echo ", …")"
}
echo
echo "## Markers in added lines"
{
  marker "silenced checks" '@SuppressWarnings|@Disabled|NOPMD|NOSONAR|allowEmptyShould|<exclude>|<Match>|:OFF' '^(src/|config/|pom.xml)'
  marker "transaction boundaries" '@Transactional|TransactionTemplate|Propagation\.' '^src/main/'
  marker "persistence model" '@Version|@Immutable|Persistable|isNew\(|cascade *=|FetchType\.|nativeQuery|@Query' '^src/main/'
  marker "global serialization" 'ObjectMapper|JsonMapper|jackson|fail-on-unknown' '^src/main/'
  marker "schema constraints and triggers" '(check|CHECK) *\(|[Uu][Nn][Ii][Qq][Uu][Ee]|[Rr][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss]|[Tt][Rr][Ii][Gg][Gg][Ee][Rr]' '^src/main/resources/db/'
  marker "concurrency and scheduling" 'synchronized|@Async|@Scheduled|@Lock|LockModeType|@Retry' '^src/main/'
  marker "security" '@PreAuthorize|SecurityFilterChain|permitAll|csrf|hasAuthority|hasScope' '^src/main/'
  marker "outbound HTTP" 'RestClient|WebClient|HttpClient|Timeout|CircuitBreaker' '^src/main/'
  marker "spec status" '^status:' '^specs/'
} | grep . || echo "- none"
