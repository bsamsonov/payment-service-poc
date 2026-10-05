#!/usr/bin/env bash
# PostToolUse hook: format a Java file right after Claude edits it.
set -euo pipefail
file="$(jq -r '.tool_input.file_path // empty')"
[[ "$file" == *.java ]] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"
# Spotless accepts a regex of absolute paths.
./mvnw -q -B spotless:apply -DspotlessFiles="$(printf '%s' "$file" | sed 's/[.[\*^$()+?{|]/\\&/g')" >/dev/null 2>&1 || true
