#!/usr/bin/env bash
# Tests of scripts/review/lanes.py (triggers and facts of the specialist lanes) on a throwaway git repository.
# External tools are off (PR_REVIEW_LANE_TOOLS=0): no network, no docker.
#
# Usage: scripts/review/test-lanes.sh
set -euo pipefail

LANES_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lanes.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PR_REVIEW_LANE_TOOLS=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
failures=0

repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
J=src/main/java/x/app
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
put "$J/domain/Money.java"          'package x.app.domain;
public record Money(long amount) {}'
put "$J/application/Pay.java"       'package x.app.application;
import x.app.domain.Money;
public class Pay { Money m; }'
put src/main/resources/db/migration/V1__init.sql 'CREATE TABLE payments (id uuid CONSTRAINT payments_pk PRIMARY KEY);'
put api/payments.yaml               'openapi: 3.1.0'
put pom.xml                         '<project><minimum>0.80</minimum></project>'
put src/test/java/x/app/ArchitectureTest.java 'class ArchitectureTest { void domainIsPure() {} }'
put docs/adr/0001-record.md         '# ADR 1'
put README.md                       'readme'
git add -A && git commit -qm base
base="$(git rev-parse HEAD)"

# Run lanes.py for the range base..HEAD (or $2..HEAD) and print the ids of the lanes that are on.
run_lanes() {
  local name="$1" from="${2:-$base}" mode="${3:-full}" dir="$work/rounds/$1"
  mkdir -p "$dir/bundle"
  git diff --find-renames --src-prefix=a/ --dst-prefix=b/ "$from" HEAD >"$dir/bundle/diff.patch"
  printf '{"base_sha":"%s","head_sha":"%s","diff_from":"%s","mode":"%s"}\n' \
    "$base" "$(git rev-parse HEAD)" "$from" "$mode" >"$dir/meta.json"
  python3 "$LANES_PY" "$dir" 2>/dev/null
  jq -r '[.lanes[].id] | join(",")' "$dir/lanes.json"
}

check() {  # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

check_facts() {  # check_facts <name> <round> <lane> <fixed string>
  if grep -qF -- "$4" "$work/rounds/$2/bundle/lanes/$3/facts.md" 2>/dev/null; then echo "ok   $1"
  else echo "FAIL $1: '$4' not in lanes/$3/facts.md"; failures=$((failures + 1)); fi
}

scenario() { git checkout -q -B "$1" "$base"; }

scenario docs
put README.md 'readme 2'
git commit -qam docs
check "docs only: no lanes" "" "$(run_lanes docs)"
check "docs only: no adr copy" "no" "$([[ -d "$work/rounds/docs/bundle/adr" ]] && echo yes || echo no)"

scenario new-migration
put src/main/resources/db/migration/V2__refunds.sql 'CREATE TABLE refunds (id uuid);'
git add -A && git commit -qm v2
check "new migration: db" "db" "$(run_lanes new-migration)"
check_facts "new migration: listed" new-migration db 'V2__refunds.sql` added'
check "new migration: adr copied" "yes" "$([[ -f "$work/rounds/new-migration/bundle/adr/0001-record.md" ]] && echo yes || echo no)"
check "new migration: checklist copied" "yes" \
  "$([[ -s "$work/rounds/new-migration/bundle/lanes/db/checklist.md" ]] && echo yes || echo no)"
check "PR_REVIEW_LANES=none" "" "$(PR_REVIEW_LANES=none run_lanes none-set)"
check "PR_REVIEW_LANES=api forces api only" "api" "$(PR_REVIEW_LANES=api run_lanes forced)"
check_facts "forced lane: reason" forced api 'requested with PR_REVIEW_LANES'

scenario edit-migration
put src/main/resources/db/migration/V1__init.sql 'CREATE TABLE payments (id uuid PRIMARY KEY, x int);'
git commit -qam edit
check "edited migration: db" "db" "$(run_lanes edit-migration)"
check_facts "edited migration: flagged" edit-migration db 'EXISTS ON THE BASE BRANCH'

scenario contract
put api/payments.yaml 'openapi: 3.1.1'
git commit -qam api
check "contract change: api" "api" "$(run_lanes contract)"
check_facts "contract copy" contract api 'lanes/api/contract/api/'
check "contract copied" "yes" "$([[ -f "$work/rounds/contract/bundle/lanes/api/contract/api/payments.yaml" ]] && echo yes || echo no)"

scenario web-adapter
put "$J/adapter/in/web/PaymentController.java" 'package x.app.adapter.in.web;
import x.app.application.Pay;
class PaymentController { Pay p; }'
git add -A && git commit -qm web
check "web adapter: api and boundaries (new package, new edge)" "api,boundaries" "$(run_lanes web-adapter)"
check_facts "web adapter: new edge" web-adapter boundaries '| `adapter.in.web` | `application` | no |'

scenario leak
put "$J/domain/Money.java" 'package x.app.domain;
import x.app.application.Pay;
public record Money(long amount) { static Pay p; }'
git commit -qam leak
check "domain imports application: boundaries" "boundaries" "$(run_lanes leak)"
check_facts "leak: new edge" leak boundaries '| `domain` | `application` | no |'
check_facts "leak: new cycle" leak boundaries '**new** `application` ↔ `domain`'

scenario module
put "$J/refund/domain/Refund.java" 'package x.app.refund.domain;
import x.app.domain.Money;
public record Refund(Money amount) {}'
put "$J/refund/application/port/RefundProvider.java" 'package x.app.refund.application.port;
public interface RefundProvider {}'
git add -A && git commit -qm module
check "new module: boundaries" "boundaries" "$(run_lanes module)"
check_facts "new module: component" module boundaries '`refund.domain` **(new)** — module `refund`'
check_facts "new module: cross-module edge" module boundaries '| `refund.domain` | `domain` | yes |'
check_facts "new module: port" module boundaries 'RefundProvider.java` added'

scenario event
put "$J/application/Pay.java" 'package x.app.application;
import x.app.domain.Money;
public class Pay { Money m; void f(org.springframework.context.ApplicationEventPublisher e) { e.publishEvent(m); } }'
git commit -qam event
check "event in existing code: boundaries" "boundaries" "$(run_lanes event)"

scenario suppression
put "$J/application/Pay.java" 'package x.app.application;
import x.app.domain.Money;
@SuppressWarnings("NullAway")
public class Pay { Money m; }'
git commit -qam suppress
check "suppression: guards" "guards" "$(run_lanes suppression)"
check_facts "suppression: listed" suppression guards 'Pay.java:3'

scenario threshold
put pom.xml '<project><minimum>0.70</minimum></project>'
put src/test/java/x/app/ArchitectureTest.java 'class ArchitectureTest { }'
git commit -qam threshold
check "threshold and rule change: guards" "guards" "$(run_lanes threshold)"
check_facts "threshold: added line" threshold guards '<minimum>0.70</minimum>'
check_facts "rule removed line" threshold guards 'void domainIsPure() {}'

scenario delta
put src/main/resources/db/migration/V2__refunds.sql 'CREATE TABLE refunds (id uuid);'
git add -A && git commit -qm v2
mid="$(git rev-parse HEAD)"
put README.md 'readme 3'
git commit -qam docs
check "delta without new migration: no lanes" "" "$(run_lanes delta "$mid" delta)"
check "full range of the same PR: db" "db" "$(run_lanes delta-full)"

scenario behind
put src/main/resources/db/migration/V2__refunds.sql 'CREATE TABLE refunds (id uuid);'
git add -A && git commit -qm v2
git checkout -q main
put AGENTS.md 'new rule'
git add -A && git commit -qm rule
tip="$(git rev-parse main)"
git checkout -q behind
run_lanes behind >/dev/null
jq --arg tip "$tip" '. + {base_ref: "main", base_tip: $tip}' "$work/rounds/behind/meta.json" >"$work/m.json"
mv "$work/m.json" "$work/rounds/behind/meta.json"
python3 "$LANES_PY" "$work/rounds/behind" 2>/dev/null
check_facts "base moved: noted" behind db 'is 1 commit(s) ahead of the merge-base'
check_facts "base moved: rule file listed" behind db '- `AGENTS.md`'
check "base not moved: no section" "no" "$(grep -q 'Base branch moved' "$work/rounds/new-migration/bundle/lanes/db/facts.md" && echo yes || echo no)"

scenario two-modules
put "$J/refund/domain/Refund.java" 'package x.app.refund.domain;
public record Refund(long amount) {}'
git add -A && git commit -qm refund
mid="$(git rev-parse HEAD)"
put "$J/refund/domain/Refund.java" 'package x.app.refund.domain;
public record Refund(long amount, String reason) {}'
put "$J/domain/Money.java" 'package x.app.domain;
public record Money(long amount, String currency) {}'
git commit -qam both
check "two modules: boundaries" "boundaries" "$(run_lanes two-modules "$mid" delta)"
check_facts "two modules: listed" two-modules boundaries 'changes in 2 modules at once: `(single module)`, `refund`'
check "one module: no lanes" "" "$(git checkout -q -B one-module "$mid" && put "$J/refund/domain/Refund.java" 'package x.app.refund.domain;
public record Refund(long amount, long fee) {}' && git commit -qam one && run_lanes one-module "$mid" delta)"

echo
if (( failures )); then echo "$failures test(s) failed"; exit 1; fi
echo "all lanes tests passed"
