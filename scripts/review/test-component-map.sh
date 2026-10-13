#!/usr/bin/env bash
# Tests for component-map.py on a throwaway fixture repository.
# Usage: scripts/review/test-component-map.sh
set -euo pipefail

map="$(cd "$(dirname "$0")" && pwd)/component-map.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
root="io/github/bsamsonov/paymentservice"

# java <source set> <package relative to the root, "" for the root> <class> [import relative to the root]...
java() {
    local set="$1" pkg="$2" class="$3" dir
    shift 3
    dir="src/$set/java/$root/${pkg//.//}"
    mkdir -p "$dir"
    {
        printf 'package io.github.bsamsonov.paymentservice%s;\n' "${pkg:+.$pkg}"
        for import in "$@"; do printf 'import io.github.bsamsonov.paymentservice.%s;\n' "$import"; done
        printf '%s\nclass %s { %s }\n' "${ANNOTATION:-}" "$class" "${BODY:-}"
    } >"$dir/$class.java"
}

commit() {
    git add -A
    git -c user.name=t -c user.email=t@example.com commit -q -m "$1"
    git rev-parse HEAD
}

# expect <case> <"has" | "lacks"> <fixed string> <output>
expect() {
    local name="$1" mode="$2" needle="$3" out="$4" found=lacks
    grep -qF -- "$needle" <<<"$out" && found=has
    if [[ "$found" != "$mode" ]]; then
        echo "FAIL: $name (output $found '$needle')"
        sed 's/^/    /' <<<"$out"
        failures=$((failures + 1))
    else
        echo "ok:   $name"
    fi
}

cd "$work"
git init -q .
java main "" App
java main domain Payment
java main domain Money
java main application CreatePayment domain.Payment
java main adapter.out.legacy LegacyStore application.CreatePayment
c1="$(commit base)"

java main domain Payment                      # modified below
echo '// changed' >>"src/main/java/$root/domain/Payment.java"
rm "src/main/java/$root/domain/Money.java"
git rm -rq "src/main/java/$root/adapter/out/legacy"
java main adapter.in.web PaymentsController application.CreatePayment 'adapter.in.web.api.PaymentsApi'
ANNOTATION='@Table(name = "payments")' java main adapter.out.persistence PaymentEntity
BODY='PaymentEntity entity; CreatePayment useCase; // Unrelated mention of LegacyStore' \
    java main adapter.out.persistence JpaPayments 'application.*' 'domain.Payment.Status'
# Plans: an open spec names existing and future classes; an implemented spec is ignored.
plan() {
    mkdir -p "specs/$1"
    printf -- '---\nid: %s\nstatus: %s\n---\n' "${1%%-*}" "$2" >"specs/$1/spec.md"
    shift 2
    { printf '## Components\n| Package | Classes | Notes |\n|---|---|---|\n'; printf '%s\n' "$@"; } >"specs/$plan_dir/plan.md"
}
plan_dir=001-core plan 001-core Approved \
    '| `adapter.out.persistence` | `PaymentEntity`, `JpaPayments` (implements `PaymentRepository`), `PaymentMapper` | `Ignored` |' \
    '| `adapter.out.stripe` | `StripeProvider` | |'
plan_dir=000-old plan 000-old Implemented '| `domain` | `Ghost` | |'
java main adapter.out.persistence Unplanned
java test adapter.out.persistence JpaPaymentsIT
mkdir -p docs && echo x >docs/notes.md
c2="$(commit change)"

echo y >>docs/notes.md
c3="$(commit docs-only)"

out="$("$map" "$c1" "$c2")"
expect "new component is marked added"         has   'class c_adapter_in_web,c_adapter_out_persistence,database added' "$out"
expect "existing component is marked changed"  has   'class c_domain changed' "$out"
expect "emptied component is marked removed"   has   'class c_adapter_out_legacy removed' "$out"
expect "class counts in the node label"        has   'c_domain["domain<br/>~1 −1"]' "$out"
expect "touched tests in the node label"       has   'persistence<br/>+3 tests 1"]' "$out"
expect "adapters are grouped by direction"     has   'subgraph g_adapter_out["adapter.out"]' "$out"
expect "kept dependency is a plain arrow"      has   'c_application --> c_domain' "$out"
expect "new dependency is highlighted"         has   'c_adapter_in_web ==> c_application' "$out"
expect "wildcard import is a dependency"       has   'c_adapter_out_persistence ==> c_application' "$out"
expect "nested class import is a dependency"   has   'c_adapter_out_persistence ==> c_domain' "$out"
expect "removed dependency is dashed"          has   'c_adapter_out_legacy -.-> c_application' "$out"
expect "new dependencies are listed"           has   '`adapter.in.web` → `application`' "$out"
expect "sub-packages fold into the component"  lacks 'adapter_in_web_api' "$out"
expect "untouched component has no class"      lacks 'c_application,' "$out"
expect "table lists classes and test files"    has   '| `adapter.out.persistence` | `JpaPayments`, `PaymentEntity`, `Unplanned` | — | — | 1 |' "$out"
expect "components sit inside the service"     has   'subgraph service["io.github.bsamsonov.paymentservice"]' "$out"
expect "table is linked to its component"      has   'c_adapter_out_persistence --> database' "$out"
expect "touched component is opened"           has   'subgraph s_adapter_out_persistence["adapter.out.persistence"]' "$out"
expect "untouched component stays collapsed"   lacks 'subgraph s_application' "$out"
expect "same-package use is a class edge"      has   'k_adapter_out_persistence_JpaPayments --> k_adapter_out_persistence_PaymentEntity' "$out"
expect "edge to a collapsed component"         has   'k_adapter_out_persistence_JpaPayments --> c_application' "$out"
expect "names in comments are not edges"       lacks 'JpaPayments --> c_adapter_out_legacy' "$out"
expect "entity is linked to its table"         has   'k_adapter_out_persistence_PaymentEntity --> t_payments' "$out"
expect "planned class is dashed"               has   'class k_adapter_out_persistence_PaymentMapper planned' "$out"
expect "planned component is dashed"           has   'class c_adapter_out_stripe planned' "$out"
expect "existing class is not planned"         lacks 'JpaPayments planned' "$out"
expect "names in parentheses are not classes"  lacks 'PaymentRepository' "$out"
expect "other plan columns are ignored"        lacks 'Ignored' "$out"
expect "implemented specs are ignored"         lacks 'Ghost' "$out"
expect "added class missing from the plan"     has   'not named in the plan: `adapter.out.persistence.Unplanned`' "$out"

out="$("$map" --all "$c1" "$c2")"
expect "--all opens untouched components"      has   'subgraph s_application["application"]' "$out"

out="$("$map" "$c2")"
expect "state: every component is opened"      has   'subgraph s_domain["domain"]' "$out"
expect "state: no change colors"               lacks 'classDef added' "$out"
expect "state: no table of changes"            lacks '<details>' "$out"
expect "state: planned classes are shown"      has   'k_adapter_out_stripe_StripeProvider["StripeProvider"]' "$out"

expect "no Java change prints nothing"         lacks 'mermaid' "$("$map" "$c2" "$c3")"
[[ -z "$("$map" "$c2" "$c3")" ]] || { echo "FAIL: output is not empty for a docs-only range"; failures=$((failures + 1)); }

if "$map" "$c1" no-such-ref >/dev/null 2>&1; then
    echo "FAIL: unknown ref must fail"
    failures=$((failures + 1))
else
    echo "ok:   unknown ref fails"
fi

(( failures == 0 )) || { echo "$failures test(s) failed"; exit 1; }
echo "all tests passed"
