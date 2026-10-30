#!/usr/bin/env python3
"""Guard of the auto-fix (autofix-findings.sh): may the change base..head be kept as an automatic fix of a review
finding, or must it go to the owner?

Usage: scripts/review/autofix_guard.py <base> <head> <main-ref>
  Prints the reasons why the change needs the owner, one per line, and exits 1 if there are any; exit 0 = allowed.
  Run it from the worktree that holds the change. The facts about the diff (changed files, modules, guard paths)
  come from specialist_lanes.py, so both judge a change the same way.
"""

from __future__ import annotations

import re
import subprocess
import sys

sys.dont_write_bytecode = True  # importing the module must not leave __pycache__/ in scripts/review

from specialist_lanes import (
    GUARD_MARKER_PATHS,
    GUARD_PATHS,
    MAIN_JAVA,
    RULE_FILES,
    SUPPRESSION_MARKERS,
    changed_files,
    git,
    java_sources,
    parse_patch,
    root_package,
    touched_modules,
)

PORT_PATH = re.compile(r"(/port/|Port\.java$)")
PORT_IMPORT = re.compile(r"^\s*import\s+[\w.]*\.port\.\w+")
IMPLEMENTS = re.compile(r"\b(?:class|record|enum)\s+(\w+)[^{;]*?\bimplements\s+([^{]+)\{")


def implemented(text: str) -> set[str]:
    """`Type:Interface` pairs declared in a Java source (generics stripped)."""
    out = set()
    for m in IMPLEMENTS.finditer(text):
        for t in re.sub(r"<[^<>]*>", "", m.group(2)).split(","):
            if t.strip():
                out.add(f"{m.group(1)}:{t.strip().split('.')[-1]}")
    return out


SPEC_PATHS = re.compile(r"^(specs/|openspec/|docs/adr/|api/)")
MIGRATIONS = "src/main/resources/db/"
# Added to a new test, these switch it off at run time without @Disabled: assumptions and conditional execution.
TEST_SKIP_MARKERS = re.compile(
    r"\bassume(True|False|That)?\s*\(|\bAssumptions\.|\bassumingThat\s*\(|@(Enabled|Disabled)(If|On|For|In)\w*"
)


def exists_at(rev: str, path: str) -> bool:
    return subprocess.run(["git", "cat-file", "-e", f"{rev}:{path}"], capture_output=True).returncode == 0


def protected_reasons(base: str, head: str, main_ref: str) -> list[str]:
    """Why a change base..head must go to the owner instead of an automatic fix: it touches what the fixer may not
    change — guards (rules, analyzers, CI, hooks, agent rules, review docs), the spec, ADRs or the API contract,
    a migration that already exists on the base branch — or it weakens checks (suppressions, skipped tests).

    Tests may only grow by new files: a new test file is free (unless it switches itself off with an assumption or
    conditional execution). Any change of an existing test file — also a line only added to it, a rename or a
    deletion — goes to the owner: it needs a reason and the owner's confirmation, since even an added line
    (e.g. `return;` at the top of a test) may narrow what is checked.

    Contracts and structure are the owner's too: any migration (also one added by this PR), ports, `package-info`,
    a new port implementation, wiring that refers to ports, and a change of main code in more than one module."""
    reasons = []
    files = changed_files(base, head)
    for status, path, old in files:
        if (old or path).startswith("src/test/") and status != "A":
            if status in "RC":
                reasons.append(f"`{old}` (test) renamed to `{path}`")
            elif status == "D":
                reasons.append(f"`{path}` (test) deleted")
            else:
                reasons.append(f"existing test `{path}` changed: needs a reason and the owner's confirmation")
        # A rename is checked at both ends: moving a file out of a protected place changes that place too.
        for p in dict.fromkeys(x for x in (path, old) if x):
            where = f"`{p}`" + (f" (moved to `{path}`)" if p == old and status == "R" else "")
            if GUARD_PATHS.search(p) or RULE_FILES.search(p):
                reasons.append(f"{where} is a guard (rules, analyzers, CI, agent rules)")
            elif SPEC_PATHS.search(p):
                reasons.append(f"{where} is the spec, an ADR or the API contract")
            elif p.startswith(MIGRATIONS):
                reasons.append(f"{where} is a migration that already exists on `{main_ref}`"
                               if exists_at(main_ref, p) else f"{where} is a migration (database schema)")
            elif p.startswith(MAIN_JAVA) and PORT_PATH.search(p):
                reasons.append(f"{where} is a port")
            elif p.startswith(MAIN_JAVA) and p.endswith("package-info.java"):
                reasons.append(f"{where} declares a package or module boundary")
    added, _ = parse_patch(git("diff", "--no-color", "--unified=0", base, head))
    root = root_package(head, java_sources(head), java_sources(base))
    mods = touched_modules(files, root)
    if len(mods) > 1:
        reasons.append(f"changes main code in {len(mods)} modules at once: " + ", ".join(f"`{m}`" for m in mods))
    for status, path, old in files:
        if status == "D" or not path.startswith(MAIN_JAVA) or not path.endswith(".java") or PORT_PATH.search(path):
            continue
        text = git("show", f"{head}:{path}", check=False)
        if not any(PORT_IMPORT.search(line) for line in text.splitlines()):
            continue
        before = git("show", f"{base}:{old or path}", check=False) if status != "A" else ""
        if implemented(text) != implemented(before):
            reasons.append(f"`{path}` adds or changes an implementation of a port")
        elif "/config/" in path:
            reasons.append(f"`{path}` wires ports (which implementation is used)")
    for path, lines in sorted(added.items()):
        if GUARD_MARKER_PATHS.search(path):
            reasons += [f"suppression added at `{path}:{n}`: `{t.strip()}`" for n, t in lines if SUPPRESSION_MARKERS.search(t)]
        if path.startswith("src/test/"):
            reasons += [f"test switched off at run time at `{path}:{n}`: `{t.strip()}`"
                        for n, t in lines if TEST_SKIP_MARKERS.search(t)]
    return reasons


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("usage: autofix_guard.py <base> <head> <main-ref>")
    reasons = protected_reasons(*sys.argv[1:4])
    print("\n".join(reasons))
    sys.exit(1 if reasons else 0)


if __name__ == "__main__":
    main()
