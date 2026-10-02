#!/usr/bin/env bash
# Stop hook: run the fast check when the working tree has source changes.
# Exit code 2 returns the failure to Claude so it keeps working instead of stopping.
set -uo pipefail
input="$(cat)"
cd "${CLAUDE_PROJECT_DIR:-.}"

if [[ -z "$(git status --porcelain -- src pom.xml)" ]]; then
  exit 0
fi

log="$(mktemp)"
if ./mvnw -q -B verify -DskipITs -Djacoco.skip=true >"$log" 2>&1; then
  rm -f "$log"
  exit 0
fi

# Avoid an endless loop: if we already blocked once in this stop sequence, report but let Claude stop.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]]; then
  echo "Fast check still failing (see ./mvnw verify -DskipITs output). Stopping to let the user decide." >&2
  rm -f "$log"
  exit 0
fi

{
  echo "Fast check failed (./mvnw verify -DskipITs -Djacoco.skip=true). Fix before finishing:"
  grep -E "ERROR|FAIL|expected|but was" "$log" | head -40
} >&2
rm -f "$log"
exit 2
