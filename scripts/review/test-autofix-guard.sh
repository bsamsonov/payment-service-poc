#!/usr/bin/env bash
# Tests of scripts/review/autofix_guard.py (what an automatic fix may not change) on a throwaway git repository.
#
# Usage: scripts/review/test-autofix-guard.sh
set -euo pipefail

GUARD_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/autofix_guard.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
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
put src/test/java/x/app/ArchitectureTest.java 'class ArchitectureTest { void domainIsPure() {} }'
put docs/adr/0001-record.md         '# ADR 1'
git add -A && git commit -qm base
base="$(git rev-parse HEAD)"
scenario() { git checkout -q -B "$1" "$base"; }

# what an automatic fix may not change (exit 1 + reasons) and what it may (exit 0).
protected() {  # protected <name> <expected substring or "-" for allowed>; the fix is the last commit
  local out rc=0
  out="$(python3 "$GUARD_PY" HEAD~1 HEAD "$base" 2>&1)" || rc=$?
  if [[ "$2" == - ]]; then
    [[ $rc == 0 ]] && echo "ok   $1" || { echo "FAIL $1: expected allowed, got: $out"; failures=$((failures + 1)); }
  elif [[ $rc == 1 && "$out" == *"$2"* ]]; then echo "ok   $1"
  else echo "FAIL $1: expected '$2', got (exit $rc): $out"; failures=$((failures + 1)); fi
}
fix_commit() { git add -A && git commit -qm fix; }
scenario protect
put "$J/application/port/Repo.java" 'package x.app.application.port;
public interface Repo {}'
put "$J/adapter/out/db/JdbcRepo.java" 'package x.app.adapter.out.db;
import x.app.application.port.Repo;
public class JdbcRepo implements Repo { int a; }'
put "$J/config/Wiring.java" 'package x.app.config;
import x.app.application.port.Repo;
class Wiring { Repo repo; }'
put "$J/config/ClockConfig.java" 'package x.app.config;
class ClockConfig { int zone; }'
put src/main/resources/db/migration/V2__refunds.sql 'CREATE TABLE refunds (id uuid);'
git add -A && git commit -qm "pr code"
put "$J/application/Pay.java" 'package x.app.application;
import x.app.domain.Money;
public class Pay { Money m; int fixed; }'
fix_commit; protected "plain fix in one module: allowed" -
put "$J/adapter/out/db/JdbcRepo.java" 'package x.app.adapter.out.db;
import x.app.application.port.Repo;
public class JdbcRepo implements Repo { int b; }'
fix_commit; protected "adapter body: allowed" -
put "$J/config/ClockConfig.java" 'package x.app.config;
class ClockConfig { int utc; }'
fix_commit; protected "config without ports: allowed" -
put src/main/resources/db/migration/V2__refunds.sql 'CREATE TABLE refunds (id uuid PRIMARY KEY);'
fix_commit; protected "migration added by the PR" "is a migration (database schema)"
put "$J/application/port/Repo.java" 'package x.app.application.port;
public interface Repo { void save(); }'
fix_commit; protected "port" "is a port"
put "$J/application/package-info.java" 'package x.app.application;'
fix_commit; protected "package-info" "declares a package or module boundary"
put "$J/adapter/out/db/MemRepo.java" 'package x.app.adapter.out.db;
import x.app.application.port.Repo;
public class MemRepo implements Repo {}'
fix_commit; protected "new port implementation" "adds or changes an implementation of a port"
put "$J/config/Wiring.java" 'package x.app.config;
import x.app.application.port.Repo;
class Wiring { Repo other; }'
fix_commit; protected "wiring of ports" "wires ports"
put "$J/refund/domain/Refund.java" 'package x.app.refund.domain;
public record Refund(long amount) {}'
put "$J/application/Pay.java" 'package x.app.application;
import x.app.domain.Money;
public class Pay { Money m; int fixedTwice; }'
fix_commit; protected "two modules" "changes main code in 2 modules at once"
printf '#!/bin/sh\nexec java "$@"\n' >mvnw
fix_commit; protected "maven wrapper" "\`mvnw\` is a guard"
put src/test/java/x/app/PayTest.java 'class PayTest { @Test void pays() {} }'
fix_commit; protected "new test file: allowed" -
printf '  @Test void more() {}\n' >>src/test/java/x/app/PayTest.java
fix_commit; protected "line added to an existing test" "existing test \`src/test/java/x/app/PayTest.java\` changed"
git mv api/payments.yaml docs/payments.yaml
fix_commit; protected "contract moved out of api/" "\`api/payments.yaml\` (moved to \`docs/payments.yaml\`) is the spec"
git mv docs/adr/0001-record.md docs/0001-record.md
fix_commit; protected "ADR moved out of docs/adr/" "\`docs/adr/0001-record.md\` (moved to"
git mv src/main/resources/db/migration/V1__init.sql src/main/resources/V1__init.sql
fix_commit; protected "migration moved away" "is a migration that already exists"
put src/main/resources/db/migration/V1__init.sql 'CREATE TABLE payments (id uuid PRIMARY KEY);'
fix_commit; protected "migration already on main" "is a migration that already exists"
put src/test/java/x/app/ArchitectureTest.java 'class ArchitectureTest { void domainIsPure() { return; } }'
fix_commit; protected "architecture rule" "\`src/test/java/x/app/ArchitectureTest.java\` is a guard"
git mv src/test/java/x/app/PayTest.java src/test/java/x/app/PaymentTest.java
fix_commit; protected "test renamed" "(test) renamed to"
git mv src/test/java/x/app/PaymentTest.java PaymentTest.java
fix_commit; protected "test moved out of src/test" "(test) renamed to"
git rm -q PaymentTest.java && put src/test/java/x/app/OldTest.java 'class OldTest { @Test void a() {} }'
git add -A && git commit -qm "pr test"
git rm -q src/test/java/x/app/OldTest.java
fix_commit; protected "test deleted" "(test) deleted"
put src/test/java/x/app/SkipTest.java 'class SkipTest { @Test void s() { assumeTrue(false); } }'
fix_commit; protected "new test that switches itself off" "test switched off at run time"

echo
if (( failures )); then echo "$failures test(s) failed"; exit 1; fi
echo "all auto-fix guard tests passed"
