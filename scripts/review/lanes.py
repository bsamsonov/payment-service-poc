#!/usr/bin/env python3
"""Specialist review lanes (L3) of /pr-review: decide which lanes a round needs and collect their facts.

A lane is switched on by a deterministic trigger on the diff of the round (diff_from..head, so a delta round runs a
lane only when its new commits touch the lane again). For every lane that is on, this script writes facts computed
without a model and copies the lane checklist; the `review-lane` agent judges them later.

  <round>/lanes.json                         — lanes that are on, with the reasons; lanes that are off
  <round>/bundle/lanes/<lane>/facts.md       — facts of the lane (no judgement)
  <round>/bundle/lanes/<lane>/checklist.md   — copy of scripts/review/lanes/<lane>.md from the working tree
  <round>/bundle/adr/                        — ADRs at the PR head, when any lane is on

Usage: scripts/review/lanes.py <round-dir>
Env:   PR_REVIEW_LANES       auto (default) | none | comma-separated lanes to force (e.g. db,api)
       PR_REVIEW_LANE_TOOLS  1 (default) | 0 — run external tools (squawk, oasdiff, redocly); 0 in tests/offline
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

LANES = ("db", "api", "boundaries", "guards")
SQUAWK = "squawk-cli@2.68.0"
REDOCLY = "@redocly/cli@2.64.0"
OASDIFF_IMAGE = "tufin/oasdiff:v1.33.0"
TOOL_TIMEOUT = 300
MAX_REASONS = 8

MAIN_JAVA = "src/main/java/"
LAYER_WORDS = ("domain", "application", "config", "adapter")
EVENT_MARKERS = re.compile(
    r"ApplicationEventPublisher|publishEvent\(|@EventListener|@TransactionalEventListener|"
    r"@ApplicationModuleListener|@ApplicationModule\b|@NamedInterface|@Externalized"
)
SUPPRESSION_MARKERS = re.compile(
    r"@SuppressWarnings|@SuppressFBWarnings|@Disabled|NOPMD|NOSONAR|CHECKSTYLE:OFF|spotless:off|allowEmptyShould|"
    r"<exclude>|<Match>|skipTests|skipITs|-DskipTests|continue-on-error|--no-verify|ignoreFailures|"
    r"failOnViolation>\s*false|failOnError>\s*false|haltOnFailure>\s*false|\|\|\s*true"
)
THRESHOLD_MARKERS = re.compile(r"<minimum>|<maximum>|<threshold>|<limit>|COVEREDRATIO|MISSEDCOUNT|<value>")
RULE_FILES = re.compile(
    r"^src/test/java/(.*/)?[^/]*(ArchitectureTest|Rules|ConventionsTest|ModulesTest|ModularityTest)\.java$"
    r"|^src/test/java/archfixture/"
)
GUARD_PATHS = re.compile(
    r"^(config/|pom\.xml$|\.mvn/|\.github/|lefthook\.yml$|scripts/hooks/|scripts/spec/|\.claude/settings\.json$|"
    r"\.claude/hooks/|AGENTS\.md$|CLAUDE\.md$|docs/review-checklist\.md$|docs/review-context\.md$)"
)
GUARD_MARKER_PATHS = re.compile(r"^(src/|config/|pom\.xml$|\.github/|\.mvn/|lefthook\.yml$|scripts/)")


# --- git helpers -------------------------------------------------------------------------------------------------

def git(*args: str, check: bool = True) -> str:
    res = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        sys.exit(f"[pr-review] ERROR: git {' '.join(args)}: {res.stderr.strip()}")
    return res.stdout


def log(msg: str) -> None:
    print(f"[pr-review] {msg}", file=sys.stderr)


def changed_files(base: str, head: str) -> list[tuple[str, str, str | None]]:
    """(status letter, path at head or deleted path, old path for renames)."""
    out = []
    for line in git("diff", "--name-status", "--find-renames", base, head).splitlines():
        parts = line.split("\t")
        status = parts[0][0]
        if status in "RC":
            out.append((status, parts[2], parts[1]))
        else:
            out.append((status, parts[1], None))
    return out


def parse_patch(patch: str) -> tuple[dict[str, list[tuple[int, str]]], dict[str, list[str]]]:
    """Added lines (path -> [(line in post-change file, text)]) and removed lines (path -> [text])."""
    added: dict[str, list[tuple[int, str]]] = defaultdict(list)
    removed: dict[str, list[str]] = defaultdict(list)
    path = old = None
    line = 0
    in_hunk = False
    for raw in patch.splitlines():
        if raw.startswith("diff --git "):
            path = old = None
            in_hunk = False
            continue
        if not in_hunk and raw.startswith("--- "):
            old = None if raw == "--- /dev/null" else raw[6:]
            continue
        if not in_hunk and raw.startswith("+++ "):
            path = old if raw == "+++ /dev/null" else raw[6:]
            continue
        if raw.startswith("@@ "):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            line = int(m.group(1)) if m else 0
            in_hunk = True
            continue
        if not in_hunk or path is None:
            continue
        if raw.startswith("+"):
            added[path].append((line, raw[1:]))
            line += 1
        elif raw.startswith("-"):
            removed[path].append(raw[1:])
        elif raw.startswith(" "):
            line += 1
    return added, removed


def tree_dirs(rev: str, prefix: str) -> set[str]:
    out = git("ls-tree", "-r", "-d", "--name-only", rev, "--", prefix, check=False)
    return set(out.splitlines())


def export_tree(rev: str, path: str, dest: Path) -> bool:
    """Extract `path` at `rev` into dest; False when the path does not exist at rev."""
    if not git("ls-tree", "--name-only", rev, "--", path, check=False).strip():
        return False
    archive = subprocess.run(["git", "archive", rev, path], capture_output=True)
    if archive.returncode != 0:
        return False
    subprocess.run(["tar", "-x", "-C", str(dest)], input=archive.stdout, check=True)
    return True


def run_tool(cmd: list[str], cwd: Path | None = None) -> tuple[int | None, str]:
    """Run an external tool; (exit code or None if it could not run, combined output)."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=TOOL_TIMEOUT, cwd=cwd,
                             env={**os.environ, "NO_COLOR": "1", "FORCE_COLOR": "0"})
    except FileNotFoundError:
        return None, f"not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return None, f"timed out after {TOOL_TIMEOUT}s"
    return res.returncode, (res.stdout + res.stderr).strip()


def fenced(text: str, limit: int = 200) -> list[str]:
    lines = text.splitlines() or ["(no output)"]
    if len(lines) > limit:
        lines = lines[:limit] + [f"… {len(lines) - limit} more lines"]
    return ["```", *lines, "```"]


# --- components (boundaries) -------------------------------------------------------------------------------------

def java_sources(rev: str) -> dict[str, tuple[str, list[tuple[int, str]]]]:
    """path -> (package, [(line, imported fully qualified name)]) for main Java files at rev."""
    out = git("grep", "-n", "-E", r"^(package|import) ", rev, "--", MAIN_JAVA + "*.java", check=False)
    files: dict[str, tuple[str, list[tuple[int, str]]]] = {}
    for raw in out.splitlines():
        # <rev>:<path>:<line>:<text>
        _, path, num, text = raw.split(":", 3)
        pkg, imports = files.get(path, ("", []))
        text = text.strip().rstrip(";")
        if text.startswith("package "):
            pkg = text[len("package "):].strip()
        else:
            name = text[len("import "):].strip()
            if name.startswith("static "):
                name = name[len("static "):].strip()
            imports.append((int(num), name))
        files[path] = (pkg, imports)
    return files


def root_package(rev: str, *sources: dict[str, tuple[str, list]]) -> str:
    """Package of the @SpringBootApplication class at rev; otherwise the common prefix of all main packages."""
    hits = git("grep", "-l", "@SpringBootApplication", rev, "--", MAIN_JAVA + "*.java", check=False).splitlines()
    for hit in hits:
        path = hit.split(":", 1)[1]
        for src in sources:
            if path in src and src[path][0]:
                return src[path][0]
    pkgs = sorted({pkg for src in sources for pkg, _ in src.values() if pkg})
    if not pkgs:
        return ""
    parts = [p.split(".") for p in pkgs]
    common = []
    for segs in zip(*parts):
        if len(set(segs)) != 1:
            break
        common.append(segs[0])
    return ".".join(common)


def target_package(name: str) -> str:
    """Package of an imported name: segments before the first capitalised one (a type)."""
    segs = []
    for seg in name.split("."):
        if seg == "*" or seg[:1].isupper():
            break
        segs.append(seg)
    return ".".join(segs)


def component(pkg: str, root: str) -> str | None:
    if not root or not (pkg == root or pkg.startswith(root + ".")):
        return None
    rel = pkg[len(root) + 1:].split(".") if pkg != root else []
    for i, seg in enumerate(rel):
        if seg in LAYER_WORDS:
            return ".".join(rel[: i + 3] if seg == "adapter" else rel[: i + 1])
    return ".".join(rel[:1]) or "(root)"


def module_of(comp: str) -> str:
    first = comp.split(".")[0]
    return "(single module)" if first in LAYER_WORDS or comp == "(root)" else first


def edges(sources: dict[str, tuple[str, list[tuple[int, str]]]], root: str) -> dict[tuple[str, str], tuple[str, int]]:
    """(from component, to component) -> first example (path, line)."""
    result: dict[tuple[str, str], tuple[str, int]] = {}
    for path, (pkg, imports) in sorted(sources.items()):
        src = component(pkg, root)
        if src is None:
            continue
        for line, name in imports:
            dst = component(target_package(name), root)
            if dst is None or dst == src:
                continue
            result.setdefault((src, dst), (path, line))
    return result


def cycles(edge_set: set[tuple[str, str]]) -> list[list[str]]:
    """Strongly connected components with more than one node (Tarjan)."""
    graph: dict[str, list[str]] = defaultdict(list)
    for a, b in edge_set:
        graph[a].append(b)
        graph.setdefault(b, [])
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    found: list[list[str]] = []
    counter = [0]

    def visit(v: str) -> None:
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on_stack.add(v)
        for w in graph[v]:
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on_stack:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            scc = []
            while True:
                w = stack.pop()
                on_stack.discard(w)
                scc.append(w)
                if w == v:
                    break
            if len(scc) > 1:
                found.append(sorted(scc))

    for v in sorted(graph):
        if v not in index:
            visit(v)
    return found


# --- lanes -------------------------------------------------------------------------------------------------------

class Round:
    def __init__(self, round_dir: Path) -> None:
        self.dir = round_dir
        self.bundle = round_dir / "bundle"
        meta = json.loads((round_dir / "meta.json").read_text())
        self.base = meta["base_sha"]
        self.head = meta["head_sha"]
        self.diff_from = meta["diff_from"]
        self.mode = meta["mode"]
        self.base_ref = meta.get("base_ref", "main")
        self.base_tip = meta.get("base_tip") or self.base
        self.files = changed_files(self.diff_from, self.head)
        self.added, self.removed = parse_patch((self.bundle / "diff.patch").read_text(errors="replace"))
        self.tools = os.environ.get("PR_REVIEW_LANE_TOOLS", "1") != "0"
        self._boundaries: dict | None = None

    def paths(self, pattern: re.Pattern | str) -> list[tuple[str, str, str | None]]:
        rx = re.compile(pattern) if isinstance(pattern, str) else pattern
        return [f for f in self.files if rx.search(f[1]) or (f[2] and rx.search(f[2]))]

    def marker_hits(self, rx: re.Pattern, path_rx: re.Pattern) -> list[tuple[str, int, str]]:
        return [(p, n, t.strip()) for p, lines in sorted(self.added.items()) if path_rx.search(p)
                for n, t in lines if rx.search(t)]

    # boundaries facts are needed both for the trigger and for facts.md
    def boundaries(self) -> dict:
        if self._boundaries is None:
            before, after = java_sources(self.diff_from), java_sources(self.head)
            root = root_package(self.head, after, before)
            e_before, e_after = edges(before, root), edges(after, root)
            comps_before = {c for c in (component(p, root) for p, _ in before.values()) if c}
            comps_after = {c for c in (component(p, root) for p, _ in after.values()) if c}
            dirs_before = tree_dirs(self.diff_from, MAIN_JAVA)
            self._boundaries = {
                "root": root,
                "components": sorted(comps_after),
                "new_components": sorted(comps_after - comps_before),
                "removed_components": sorted(comps_before - comps_after),
                "edges": e_after,
                "new_edges": {k: v for k, v in e_after.items() if k not in e_before},
                "removed_edges": sorted(k for k in e_before if k not in e_after),
                "cycles": cycles(set(e_after)),
                "new_cycles": [c for c in cycles(set(e_after)) if c not in cycles(set(e_before))],
                "new_packages": sorted({str(Path(p).parent) for s, p, _ in self.files
                                        if s in "AR" and p.startswith(MAIN_JAVA) and p.endswith(".java")
                                        and str(Path(p).parent) not in dirs_before}),
                "package_info": [(s, p) for s, p, _ in self.files
                                 if p.startswith(MAIN_JAVA) and p.endswith("package-info.java")],
                "ports": [(s, p) for s, p, _ in self.files if p.startswith(MAIN_JAVA) and p.endswith(".java")
                          and ("/port/" in p or p.endswith("Port.java"))],
                "events": self.marker_hits(EVENT_MARKERS, re.compile("^" + re.escape(MAIN_JAVA))),
            }
        return self._boundaries

    # -- triggers: list of reasons, empty = lane off --

    def trigger_db(self) -> list[str]:
        return [f"`{p}` {status_word(s)}" for s, p, _ in self.paths(r"^src/main/resources/db/")]

    def trigger_api(self) -> list[str]:
        reasons = [f"`{p}` {status_word(s)}" for s, p, _ in self.paths(r"^api/")]
        reasons += [f"`{p}` {status_word(s)} (web adapter)" for s, p, _ in self.paths(r"^src/main/java/.*/adapter/in/web/")]
        return reasons

    def trigger_boundaries(self) -> list[str]:
        b = self.boundaries()
        reasons = [f"new package `{p}`" for p in b["new_packages"]]
        reasons += [f"`{p}` {status_word(s)}" for s, p in b["package_info"]]
        reasons += [f"new dependency `{a}` → `{c}` (`{p}:{n}`)" for (a, c), (p, n) in sorted(b["new_edges"].items())]
        reasons += [f"port `{p}` {status_word(s)}" for s, p in b["ports"]]
        reasons += [f"event or module marker at `{p}:{n}`" for p, n, _ in b["events"]]
        return reasons

    def trigger_guards(self) -> list[str]:
        reasons = [f"`{p}` {status_word(s)}" for s, p, _ in self.paths(RULE_FILES)]
        reasons += [f"`{p}` {status_word(s)}" for s, p, _ in self.paths(GUARD_PATHS)]
        reasons += [f"suppression at `{p}:{n}`" for p, n, _ in self.marker_hits(SUPPRESSION_MARKERS, GUARD_MARKER_PATHS)]
        return reasons

    # -- facts --

    def header(self, lane: str, reasons: list[str]) -> list[str]:
        rng = f"`{self.diff_from[:7]}..{self.head[:7]}`" + (" (delta: commits since the previous round)"
                                                           if self.mode == "delta" else "")
        return [f"# Lane `{lane}` — facts (computed, no judgement)", "", f"- Range: {rng}",
                "- Switched on by:", *[f"  - {r}" for r in reasons], "", *self.base_moved()]

    def base_moved(self) -> list[str]:
        """Rule documents changed on the base branch after the PR branched off: the PR merges under those rules."""
        if self.base_tip == self.base:
            return []
        count = git("rev-list", "--count", f"{self.base}..{self.base_tip}", check=False).strip() or "?"
        changed = [line.split("\t")[-1] for line in
                   git("diff", "--name-status", self.base, self.base_tip, check=False).splitlines()]
        rules = [p for p in changed if RULE_FILES.search(p) or GUARD_PATHS.search(p) or p.startswith("docs/adr/")
                 or p in ("docs/architecture.md", "docs/product.md")]
        out = [f"## Base branch moved: `{self.base_ref}` is {count} commit(s) ahead of the merge-base "
               f"`{self.base[:7]}`", "",
               "The PR will merge under the rules at the tip of the base branch, not the ones it branched from. "
               "Read these files at the base tip "
               f"(`git show {self.base_tip[:7]}:<path>`; the working tree is usually a checkout of it):", ""]
        fixtures = [p for p in rules if p.startswith("src/test/java/archfixture/")]
        out += [f"- `{p}`" for p in rules if p not in fixtures] or ["- no rule documents changed"]
        if fixtures:
            out.append(f"- `src/test/java/archfixture/` — {len(fixtures)} fixture file(s) of the architecture rules")
        return out + [""]

    def facts_db(self) -> list[str]:
        out = ["## Changed files under `src/main/resources/db/`", ""]
        sql = []
        for s, p, old in self.paths(r"^src/main/resources/db/"):
            existed = bool(git("ls-tree", "--name-only", self.base, "--", old or p, check=False).strip())
            note = ""
            if s != "A" and existed and "/migration/" in (old or p):
                note = " — **EXISTS ON THE BASE BRANCH: a merged migration must not change**"
            out.append(f"- `{p}` {status_word(s)}{f' (from `{old}`)' if old else ''}{note}")
            if s != "D" and p.endswith(".sql"):
                sql.append(p)
        out += ["", "## All migrations at the PR head", ""]
        listing = git("ls-tree", "-r", "--name-only", self.head, "--", "src/main/resources/db/migration", check=False)
        out += [f"- `{p}`" for p in listing.splitlines()] or ["- none"]
        out += ["", f"## squawk (`{SQUAWK}`, rule `prefer-robust-stmts` excluded: Flyway runs a migration in a "
                    "transaction)", ""]
        if not sql:
            out.append("- no SQL files to lint")
        elif not self.tools:
            out.append("- skipped (PR_REVIEW_LANE_TOOLS=0)")
        else:
            with tempfile.TemporaryDirectory() as tmp:
                for p in sql:
                    dest = Path(tmp) / p
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_text(git("show", f"{self.head}:{p}"))
                rc, text = run_tool(["npx", "-y", SQUAWK, "--reporter", "gcc", "--exclude", "prefer-robust-stmts",
                                     *sql], cwd=Path(tmp))
            out += [f"- exit code: {rc if rc is not None else 'did not run'} (line numbers are 0-based)", "",
                    *fenced(text)]
        return out

    def facts_api(self) -> list[str]:
        out = ["## Changed contract and web adapter files", ""]
        out += [f"- `{p}` {status_word(s)}" for s, p, _ in self.paths(r"^api/|^src/main/java/.*/adapter/in/web/")]
        contract_dir = self.bundle / "lanes" / "api" / "contract"
        contract_dir.mkdir(parents=True, exist_ok=True)
        has_api = export_tree(self.head, "api", contract_dir)
        out += ["", "## Contract at the PR head", "",
                "Full copy: `lanes/api/contract/api/` (unchanged files included)." if has_api else "- no `api/` directory"]
        specs = [p for s, p, _ in self.paths(r"^api/.*\.ya?ml$") if s != "D"]
        deleted = [p for s, p, _ in self.paths(r"^api/") if s == "D"]
        out += [f"- **deleted contract file** `{p}`" for p in deleted]
        if not specs:
            return out
        if not self.tools:
            return out + ["", "- oasdiff and redocly skipped (PR_REVIEW_LANE_TOOLS=0)"]
        with tempfile.TemporaryDirectory() as tmp:
            base_dir, head_dir = Path(tmp, "base"), Path(tmp, "head")
            base_dir.mkdir()
            head_dir.mkdir()
            base_has_api = export_tree(self.base, "api", base_dir)
            export_tree(self.head, "api", head_dir)
            for p in specs:
                out += ["", f"## `{p}`", ""]
                if base_has_api and (base_dir / p).exists():
                    rc, text = run_tool(["docker", "run", "--rm", "-v", f"{tmp}:/w:ro", OASDIFF_IMAGE, "breaking",
                                         f"/w/base/{p}", f"/w/head/{p}", "--fail-on", "WARN"])
                    out += [f"### oasdiff breaking (base → head, `{OASDIFF_IMAGE}`), exit code: "
                            f"{rc if rc is not None else 'did not run'}", "", *fenced(text or "no breaking changes")]
                else:
                    out += ["- new contract file: nothing to compare with on the base branch"]
                rc, text = run_tool(["npx", "-y", REDOCLY, "lint", "--format", "stylish", p], cwd=head_dir)
                out += ["", f"### redocly lint (`{REDOCLY}`, built-in recommended rules), exit code: "
                            f"{rc if rc is not None else 'did not run'}", "", *fenced(text)]
        return out

    def facts_boundaries(self) -> list[str]:
        b = self.boundaries()
        out = [f"Root package: `{b['root'] or '(none)'}`. A component is the package up to its layer "
               "(`domain`, `application`, `config`, `adapter.<in|out>.<name>`); the first segment before a layer is "
               "the module (`(single module)` when the layers sit directly under the root). Dependencies come from "
               "`import` lines only (same-package references and fully qualified names are not seen).", ""]
        out += ["## Components at the PR head", ""]
        out += [f"- `{c}`{' **(new)**' if c in b['new_components'] else ''} — module `{module_of(c)}`"
                for c in b["components"]] or ["- none"]
        out += [f"- removed: `{c}`" for c in b["removed_components"]]
        out += ["", "## New dependencies between components", ""]
        if b["new_edges"]:
            out += ["| From | To | Cross-module | Example |", "|---|---|---|---|"]
            out += [f"| `{a}` | `{c}` | {'yes' if module_of(a) != module_of(c) else 'no'} | `{p}:{n}` |"
                    for (a, c), (p, n) in sorted(b["new_edges"].items())]
        else:
            out.append("- none")
        out += ["", "## Removed dependencies", ""]
        out += [f"- `{a}` → `{c}`" for a, c in b["removed_edges"]] or ["- none"]
        out += ["", "## All dependencies at the PR head", ""]
        out += [f"- `{a}` → `{c}`" for a, c in sorted(b["edges"])] or ["- none"]
        out += ["", "## Cycles at the PR head", ""]
        out += [f"- {'**new** ' if c in b['new_cycles'] else ''}{' ↔ '.join(f'`{x}`' for x in c)}"
                for c in b["cycles"]] or ["- none"]
        out += ["", "## New packages", ""] + ([f"- `{p}`" for p in b["new_packages"]] or ["- none"])
        out += ["", "## `package-info.java` changes", ""] + ([f"- `{p}` {status_word(s)}" for s, p in b["package_info"]]
                                                           or ["- none"])
        out += ["", "## Ports changed", ""] + ([f"- `{p}` {status_word(s)}" for s, p in b["ports"]] or ["- none"])
        out += ["", "## Events and module markers in added lines", ""]
        out += [f"- `{p}:{n}` — `{t}`" for p, n, t in b["events"]] or ["- none"]
        return out

    def facts_guards(self) -> list[str]:
        out = ["## Changed guard paths (rules, analyzers, build, CI, hooks, agent rules)", ""]
        seen = set()
        for s, p, _ in self.paths(RULE_FILES) + self.paths(GUARD_PATHS):
            if p in seen:
                continue
            seen.add(p)
            out.append(f"- `{p}` {status_word(s)}, +{len(self.added.get(p, []))}/-{len(self.removed.get(p, []))}")
        if not seen:
            out.append("- none")
        out += ["", "## Suppressions and skips in added lines", ""]
        out += [f"- `{p}:{n}` — `{t}`" for p, n, t in self.marker_hits(SUPPRESSION_MARKERS, GUARD_MARKER_PATHS)] \
            or ["- none"]
        out += ["", "## Removed lines in architecture rule files", ""]
        rule_removed = [(p, t.strip()) for p, lines in sorted(self.removed.items()) if RULE_FILES.search(p)
                        for t in lines if t.strip()]
        out += [f"- `{p}`: `{t}`" for p, t in rule_removed[:60]] or ["- none"]
        out += ["", "## Threshold lines changed in `pom.xml` and `config/`", ""]
        thr = [f"- `{p}:{n}` + `{t.strip()}`" for p, lines in sorted(self.added.items())
               if re.match(r"^(pom\.xml|config/)", p) for n, t in lines if THRESHOLD_MARKERS.search(t)]
        thr += [f"- `{p}` − `{t.strip()}`" for p, lines in sorted(self.removed.items())
                if re.match(r"^(pom\.xml|config/)", p) for t in lines if THRESHOLD_MARKERS.search(t)]
        out += thr or ["- none"]
        return out


def status_word(s: str) -> str:
    return {"A": "added", "M": "modified", "D": "deleted", "R": "renamed", "C": "copied", "T": "type changed"}.get(s, s)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: lanes.py <round-dir>")
    round_dir = Path(sys.argv[1]).resolve()
    if not (round_dir / "meta.json").is_file():
        sys.exit(f"[pr-review] ERROR: not a round directory: {round_dir}")
    scripts_dir = Path(__file__).resolve().parent
    rnd = Round(round_dir)

    setting = os.environ.get("PR_REVIEW_LANES", "auto").strip() or "auto"
    forced: list[str] = []
    if setting not in ("auto", "none"):
        forced = [x.strip() for x in setting.split(",") if x.strip()]
        unknown = [x for x in forced if x not in LANES]
        if unknown:
            sys.exit(f"[pr-review] ERROR: unknown lane(s): {', '.join(unknown)} (known: {', '.join(LANES)})")

    lanes_dir = rnd.bundle / "lanes"
    shutil.rmtree(lanes_dir, ignore_errors=True)
    on, off = [], []
    for lane in LANES:
        reasons = getattr(rnd, f"trigger_{lane}")() if setting != "none" else []
        if forced:
            reasons = reasons if lane in forced else []
            if lane in forced and not reasons:
                reasons = ["requested with PR_REVIEW_LANES"]
        if not reasons:
            off.append(lane)
            continue
        shown = reasons[:MAX_REASONS] + ([f"… and {len(reasons) - MAX_REASONS} more"] if len(reasons) > MAX_REASONS else [])
        d = lanes_dir / lane
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy(scripts_dir / "lanes" / f"{lane}.md", d / "checklist.md")
        facts = rnd.header(lane, shown) + getattr(rnd, f"facts_{lane}")()
        (d / "facts.md").write_text("\n".join(facts) + "\n")
        on.append({"id": lane, "reasons": shown})

    if on:
        adr = rnd.bundle / "adr"
        shutil.rmtree(adr, ignore_errors=True)
        adr.mkdir()
        with tempfile.TemporaryDirectory() as tmp:
            if export_tree(rnd.head, "docs/adr", Path(tmp)):
                for f in sorted(Path(tmp, "docs", "adr").glob("*.md")):
                    shutil.copy(f, adr / f.name)
        for doc in ("docs/architecture.md",):
            text = git("show", f"{rnd.head}:{doc}", check=False)
            if text:
                (rnd.bundle / Path(doc).name).write_text(text)

    (round_dir / "lanes.json").write_text(json.dumps({"setting": setting, "lanes": on, "off": off}, indent=2) + "\n")
    log("lanes: " + (", ".join(f"{x['id']} ({len(x['reasons'])} reasons)" for x in on) or "none"))


if __name__ == "__main__":
    main()
