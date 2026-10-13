#!/usr/bin/env python3
"""Component map of a change: which components a commit range touches, as Markdown with a Mermaid diagram.

Usage: scripts/review/component-map.py <from-ref> <head-ref>
Prints the section body to stdout; prints nothing when the range touches no Java code under the root package.

Everything is read from git objects (no checkout, no build), so it works for any pair of commits:
  - components: packages under ROOT_PACKAGE, cut to `adapter.<direction>.<name>` or to the first segment
    (`domain`, `application`, `config`, ...); classes of the root package itself form the `(root)` component;
  - dependencies: `import` statements between components, at <head-ref> and at <from-ref> (to mark new and
    removed ones). Fully qualified names used without an import are not seen;
  - changes: `git diff --name-status` of main and test sources, counted per component.

Standard library only.
"""

import re
import subprocess
import sys
from collections import defaultdict

ROOT_PACKAGE = "io.github.bsamsonov.paymentservice"
ROOT_COMPONENT = "(root)"
MAIN_DIR = "src/main/java/" + ROOT_PACKAGE.replace(".", "/") + "/"
TEST_DIR = "src/test/java/" + ROOT_PACKAGE.replace(".", "/") + "/"
IMPORT = re.compile(r"^import\s+(?:static\s+)?" + re.escape(ROOT_PACKAGE) + r"((?:\.\w+)*)(?:\.\*)?\s*;")
# Not classes: counting them would only add noise to the map.
IGNORED_FILES = {"package-info.java", "module-info.java"}


def git(*args: str, ok_codes: tuple[int, ...] = (0,)) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    if result.returncode not in ok_codes:
        sys.exit(f"component-map: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def component_of(segments: list[str]) -> str:
    """Component of a package given as segments relative to the root package."""
    if not segments:
        return ROOT_COMPONENT
    if segments[0] == "adapter":
        return ".".join(segments[:3])
    return segments[0]


def component_of_path(path: str, source_dir: str) -> str:
    return component_of(path[len(source_dir) :].split("/")[:-1])


def snapshot(ref: str) -> tuple[set[str], set[tuple[str, str]]]:
    """Components that have source files at `ref`, and the import dependencies between components."""
    components = {
        component_of_path(path, MAIN_DIR)
        for path in git("ls-tree", "-r", "--name-only", ref, "--", MAIN_DIR).splitlines()
        if path.endswith(".java")
    }
    edges = set()
    # Exit code 1 means "no matches" (e.g. no cross-package imports yet).
    grep = git("grep", "-h", "--full-name", "-H", "-E", "^import ", ref, "--", MAIN_DIR, ok_codes=(0, 1))
    for line in grep.splitlines():
        path, _, statement = line[len(ref) + 1 :].partition(":")
        match = IMPORT.match(statement)
        if not match or not path.endswith(".java"):
            continue
        # Package segments are lower-case; the first capitalized segment is the class.
        package = []
        for segment in match.group(1).split(".")[1:]:
            if not segment[0].islower():
                break
            package.append(segment)
        source, target = component_of_path(path, MAIN_DIR), component_of(package)
        if source != target:
            edges.add((source, target))
    return components, edges


def changes(from_ref: str, head_ref: str) -> tuple[dict, dict]:
    """Per component: {"A": [...], "M": [...], "D": [...]} class names of main code, and the number of test files."""
    main: dict[str, dict[str, list[str]]] = defaultdict(lambda: {"A": [], "M": [], "D": []})
    tests: dict[str, int] = defaultdict(int)

    def record(status: str, path: str) -> None:
        name = path.rsplit("/", 1)[-1]
        if not path.endswith(".java") or name in IGNORED_FILES:
            return
        if path.startswith(MAIN_DIR):
            main[component_of_path(path, MAIN_DIR)][status].append(name.removesuffix(".java"))
        elif path.startswith(TEST_DIR):
            tests[component_of_path(path, TEST_DIR)] += 1

    diff = git("diff", "--name-status", "--find-renames", from_ref, head_ref, "--", "src/main/java", "src/test/java")
    for line in diff.splitlines():
        status, *paths = line.split("\t")
        if status.startswith("R"):
            old, new = paths
            same = old.startswith(MAIN_DIR) == new.startswith(MAIN_DIR) and (
                component_of_path(old, MAIN_DIR if old.startswith(MAIN_DIR) else TEST_DIR)
                == component_of_path(new, MAIN_DIR if new.startswith(MAIN_DIR) else TEST_DIR)
            )
            if same:
                record("M", new)
            else:
                record("D", old)
                record("A", new)
        else:
            record(status[0] if status[0] in "AMD" else "M", paths[-1])
    return main, tests


def node_id(component: str) -> str:
    return "root" if component == ROOT_COMPONENT else "c_" + re.sub(r"\W", "_", component)


def render(from_ref: str, head_ref: str) -> str:
    base_components, base_edges = snapshot(from_ref)
    head_components, head_edges = snapshot(head_ref)
    main, tests = changes(from_ref, head_ref)
    if not main and not tests:
        return ""

    def status(component: str) -> str:
        if component not in head_components and component in base_components:
            return "removed"
        if component not in base_components:
            return "added"
        return "changed" if component in main else "untouched"

    # Import targets without sources in git (generated code) still get a node.
    components = sorted(
        head_components | base_components | {c for edge in head_edges | base_edges for c in edge} | set(main)
    )

    def label(component: str) -> str:
        counts = main.get(component, {})
        parts = [f"{sign}{len(counts[key])}" for sign, key in (("+", "A"), ("~", "M"), ("−", "D")) if counts.get(key)]
        if tests.get(component):
            parts.append(f"tests {tests[component]}")
        name = ROOT_PACKAGE.rsplit(".", 1)[-1] if component == ROOT_COMPONENT else component
        return f'{node_id(component)}["{name}{"<br/>" + " ".join(parts) if parts else ""}"]'

    out = ["```mermaid", "flowchart LR"]
    groups: dict[str, list[str]] = defaultdict(list)
    for component in components:
        segments = component.split(".")
        groups[".".join(segments[:2]) if len(segments) > 2 else ""].append(component)
    for group, members in sorted(groups.items()):
        if group:
            out.append(f'  subgraph {node_id(group)}["{group}"]')
        out.extend(f"  {'  ' if group else ''}{label(component)}" for component in members)
        if group:
            out.append("  end")

    added_edges, removed_edges = sorted(head_edges - base_edges), sorted(base_edges - head_edges)
    styles = []
    index = 0
    for arrow, edges, style in (
        ("-->", sorted(head_edges & base_edges), ""),
        ("==>", added_edges, "stroke:#28a745,stroke-width:3px"),
        ("-.->", removed_edges, "stroke:#d73a49,stroke-dasharray:4"),
    ):
        for source, target in edges:
            out.append(f"  {node_id(source)} {arrow} {node_id(target)}")
            if style:
                styles.append(f"  linkStyle {index} {style}")
            index += 1
    out.extend(styles)
    out += [
        "  classDef added fill:#d4edda,stroke:#28a745,color:#000",
        "  classDef changed fill:#fff3cd,stroke:#d39e00,color:#000",
        "  classDef removed fill:#f8d7da,stroke:#d73a49,color:#000,stroke-dasharray:4",
    ]
    for kind in ("added", "changed", "removed"):
        members = [node_id(c) for c in components if status(c) == kind]
        if members:
            out.append(f"  class {','.join(members)} {kind}")
    out += ["```", ""]

    out.append(
        f"<sub>`{from_ref[:7]}..{head_ref[:7]}` · green: new component, yellow: changed, red: removed, plain: untouched · "
        "`+` added, `~` modified, `−` deleted classes, `tests` test files touched · arrows: imports between components "
        "(thick green: new, dashed red: removed)</sub>"
    )
    for title, edges in (("New dependencies", added_edges), ("Removed dependencies", removed_edges)):
        if edges:
            out += ["", f"**{title}:** " + ", ".join(f"`{s}` → `{t}`" for s, t in edges)]

    def names(component: str, key: str) -> str:
        return ", ".join(f"`{n}`" for n in sorted(main.get(component, {}).get(key, []))) or "—"

    out += [
        "",
        "<details><summary>Changed classes by component</summary>",
        "",
        "| Component | Added | Modified | Deleted | Test files touched |",
        "|---|---|---|---|---|",
    ]
    for component in sorted(set(main) | set(tests)):
        out.append(
            f"| `{component}` | {names(component, 'A')} | {names(component, 'M')} | {names(component, 'D')} "
            f"| {tests.get(component, 0)} |"
        )
    out += ["", "</details>"]
    return "\n".join(out) + "\n"


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1].split("\n")[0])
    from_ref, head_ref = (git("rev-parse", "--verify", f"{ref}^{{commit}}").strip() for ref in sys.argv[1:])
    sys.stdout.write(render(from_ref, head_ref))


if __name__ == "__main__":
    main()
