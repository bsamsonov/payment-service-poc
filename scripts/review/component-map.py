#!/usr/bin/env python3
"""Component map: components, their boundaries, classes and dependencies as Markdown with Mermaid diagrams.

Usage: scripts/review/component-map.py [--all] <from-ref> <head-ref>   what a commit range changes
       scripts/review/component-map.py <ref>                          the state of the code at a commit

Two diagrams:
  1. components inside the service boundary, grouped by adapter direction, with dependencies between them
     and the database tables behind them;
  2. classes inside the components. For a range only the touched components are opened (the others stay
     single nodes); `--all` and the single-ref form open every component.
For a range, touched components and classes are colored, new and removed dependencies between components are
marked, and the changed classes are listed. Prints nothing when the range touches no Java code under the root
package.

Everything is read from git objects (no checkout, no build), so it works for any commit:
  - components: packages under ROOT_PACKAGE, cut to `adapter.<direction>.<name>` or to the first segment
    (`domain`, `application`, `config`, ...); classes of the root package itself form the `(root)` component;
  - classes: top-level types, one per source file;
  - dependencies: `import` statements plus names of classes of the same package (and of wildcard imports) used in
    the source. Fully qualified names used without an import are not seen;
  - tables: `@Table(name = "...")` on a class;
  - planned classes (dashed): the table `| Package | Classes | ... |` in `specs/NNN-*/plan.md` of specs that are
    not `Implemented`/`Superseded`. In the Classes cell every back-quoted capitalized name outside parentheses is
    a class; classes that already exist are not planned any more. A plan says nothing about dependencies, so
    planned classes have no arrows.

Standard library only.
"""

import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field

ROOT_PACKAGE = "io.github.bsamsonov.paymentservice"
ROOT_COMPONENT = "(root)"
MAIN_DIR = "src/main/java/" + ROOT_PACKAGE.replace(".", "/") + "/"
TEST_DIR = "src/test/java/" + ROOT_PACKAGE.replace(".", "/") + "/"
IMPORT = re.compile(
    r"^import\s+(?:static\s+)?" + re.escape(ROOT_PACKAGE) + r"((?:\.\w+)*)(\.\*)?\s*;", re.MULTILINE
)
COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)
STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')
TABLE = re.compile(r'@Table\s*\(\s*(?:[^)]*?\bname\s*=\s*)?"(\w+)"')
TYPE_NAME = re.compile(r"\b[A-Z]\w*\b")
# Not classes: counting them would only add noise to the map.
IGNORED_FILES = {"package-info.java", "module-info.java"}
PLAN_PATH = re.compile(r"^(specs/\d{3}-[^/]+)/plan\.md$")
CLOSED_SPEC = {"implemented", "superseded"}


def git(*args: str, ok_codes: tuple[int, ...] = (0,), stdin: str | None = None) -> bytes:
    result = subprocess.run(
        ["git", *args], capture_output=True, check=False, input=stdin.encode() if stdin is not None else None
    )
    if result.returncode not in ok_codes:
        sys.exit(f"component-map: git {' '.join(args)} failed: {result.stderr.decode().strip()}")
    return result.stdout


def component_of(segments: list[str]) -> str:
    """Component of a package given as segments relative to the root package."""
    if not segments:
        return ROOT_COMPONENT
    if segments[0] == "adapter":
        return ".".join(segments[:3])
    return segments[0]


def class_key(path: str, source_dir: str) -> str:
    """`adapter.out.persistence.PaymentEntity` for a source path; `App` for a class of the root package."""
    return path[len(source_dir) :].removesuffix(".java").replace("/", ".")


def component_of_key(key: str) -> str:
    return component_of(key.split(".")[:-1])


def package_of(segments: list[str]) -> tuple[str, str | None]:
    """Split import segments into (package, class): package segments are lower-case, the class is capitalized."""
    package = []
    for segment in segments:
        if not segment[0].islower():
            return ".".join(package), segment
        package.append(segment)
    return ".".join(package), None


@dataclass
class Snapshot:
    components: set[str] = field(default_factory=set)  # components that have source files
    classes: dict[str, set[str]] = field(default_factory=dict)  # class key -> keys of the classes it uses
    component_edges: set[tuple[str, str]] = field(default_factory=set)
    tables: dict[str, str] = field(default_factory=dict)  # table name -> class key


def sources(ref: str) -> dict[str, str]:
    """Path -> text of every Java source under MAIN_DIR at `ref`."""
    entries = []
    for line in git("ls-tree", "-r", ref, "--", MAIN_DIR).decode().splitlines():
        meta, path = line.split("\t", 1)
        if path.endswith(".java"):
            entries.append((meta.split()[2], path))
    if not entries:
        return {}
    batch = git("cat-file", "--batch", stdin="".join(sha + "\n" for sha, _ in entries))
    result, offset = {}, 0
    for _, path in entries:
        header_end = batch.index(b"\n", offset)
        size = int(batch[offset:header_end].split()[2])
        result[path] = batch[header_end + 1 : header_end + 1 + size].decode(errors="replace")
        offset = header_end + 1 + size + 1
    return result


def snapshot(ref: str) -> Snapshot:
    snap = Snapshot()
    parsed = {}
    for path, text in sources(ref).items():
        key = class_key(path, MAIN_DIR)
        snap.components.add(component_of_key(key))
        if path.rsplit("/", 1)[-1] in IGNORED_FILES:
            continue
        code = COMMENT.sub("", text)
        table = TABLE.search(code)
        if table:
            snap.tables[table.group(1)] = key
        parsed[key] = code
        snap.classes[key] = set()

    def qualified(package: str, name: str) -> str:
        return f"{package}.{name}" if package else name

    for key, code in parsed.items():
        own_package = key.rpartition(".")[0]
        visible = {own_package}
        for match in IMPORT.finditer(code):
            package, name = package_of(match.group(1).split(".")[1:])
            target_component = component_of(package.split(".") if package else [])
            if target_component != component_of_key(key):
                snap.component_edges.add((component_of_key(key), target_component))
            if name and qualified(package, name) in parsed:
                snap.classes[key].add(qualified(package, name))
            elif not name and match.group(2):
                visible.add(package)
        for name in set(TYPE_NAME.findall(STRING.sub('""', code))):
            for package in visible:
                target = qualified(package, name)
                if target in parsed and target != key:
                    snap.classes[key].add(target)
    for key, targets in snap.classes.items():
        for target in targets:
            if component_of_key(key) != component_of_key(target):
                snap.component_edges.add((component_of_key(key), component_of_key(target)))
    return snap


def planned_classes(ref: str) -> tuple[dict[str, str], set[str]]:
    """Classes named by the plans of open specs: {class key: plan path}, and the packages those plans describe."""
    classes, packages = {}, set()
    paths = git("ls-tree", "-r", "--name-only", ref, "--", "specs").decode().splitlines()
    for path in paths:
        match = PLAN_PATH.match(path)
        if not match:
            continue
        spec = git("show", f"{ref}:{match.group(1)}/spec.md", ok_codes=(0, 128)).decode(errors="replace")
        status = re.search(r"^status:\s*(\w+)", spec, re.MULTILINE)
        if status and status.group(1).lower() in CLOSED_SPEC:
            continue
        in_table = False
        for line in git("show", f"{ref}:{path}").decode(errors="replace").splitlines():
            if not line.lstrip().startswith("|"):
                in_table = False
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) >= 2 and cells[0].lower() == "package" and cells[1].lower().startswith("classes"):
                in_table = True
                continue
            package = re.match(r"`([a-z][\w.]*)`", cells[0]) if in_table and len(cells) >= 2 else None
            if not package:
                continue
            packages.add(package.group(1))
            names = cells[1]
            while (stripped := re.sub(r"\([^()]*\)", "", names)) != names:
                names = stripped
            for name in re.findall(r"`([A-Z]\w*)`", names):
                classes.setdefault(f"{package.group(1)}.{name}", path)
    return classes, packages


def changes(from_ref: str, head_ref: str) -> tuple[dict[str, str], dict[str, int]]:
    """Main classes changed in the range ({class key: "A" | "M" | "D"}) and test files touched per component."""
    main: dict[str, str] = {}
    tests: dict[str, int] = defaultdict(int)

    def record(status: str, path: str) -> None:
        if not path.endswith(".java") or path.rsplit("/", 1)[-1] in IGNORED_FILES:
            return
        if path.startswith(MAIN_DIR):
            main[class_key(path, MAIN_DIR)] = status
        elif path.startswith(TEST_DIR):
            tests[component_of_key(class_key(path, TEST_DIR))] += 1

    diff = git("diff", "--name-status", "--find-renames", from_ref, head_ref, "--", "src/main/java", "src/test/java")
    for line in diff.decode().splitlines():
        status, *paths = line.split("\t")
        if status.startswith("R"):
            # A rename shows up as a deleted and an added class: the map is keyed by class name.
            record("D", paths[0])
            record("A", paths[1])
        else:
            record(status[0] if status[0] in "AMD" else "M", paths[-1])
    return main, tests


def node_id(name: str, prefix: str = "c_") -> str:
    return "root" if name == ROOT_COMPONENT else prefix + re.sub(r"\W", "_", name)


class Diagram:
    """Mermaid flowchart with the styles shared by both diagrams; keeps edge indexes for linkStyle."""

    STYLES = {
        "added": "fill:#d4edda,stroke:#28a745,color:#000",
        "changed": "fill:#fff3cd,stroke:#d39e00,color:#000",
        "removed": "fill:#f8d7da,stroke:#d73a49,color:#000,stroke-dasharray:4",
        "planned": "fill:none,stroke:#6c757d,stroke-dasharray:5",
    }
    ARROWS = {
        "kept": ("-->", ""),
        "added": ("==>", "stroke:#28a745,stroke-width:3px"),
        "removed": ("-.->", "stroke:#d73a49,stroke-dasharray:4"),
    }

    def __init__(self) -> None:
        self.lines = ["```mermaid", "flowchart LR"]
        self.link_styles: list[str] = []
        self.kinds: dict[str, list[str]] = defaultdict(list)
        self.edges = 0

    def add(self, line: str) -> None:
        self.lines.append(line)

    def node(self, indent: str, ident: str, label: str, kind: str = "", shape: str = '["{}"]') -> None:
        self.lines.append(f"{indent}{ident}{shape.format(label)}")
        if kind in self.STYLES:
            self.kinds[kind].append(ident)

    def edge(self, source: str, target: str, kind: str = "kept") -> None:
        arrow, style = self.ARROWS[kind]
        self.lines.append(f"  {source} {arrow} {target}")
        if style:
            self.link_styles.append(f"  linkStyle {self.edges} {style}")
        self.edges += 1

    def render(self) -> list[str]:
        out = self.lines + self.link_styles
        for kind, members in self.kinds.items():
            out.append(f"  classDef {kind} {self.STYLES[kind]}")
            out.append(f"  class {','.join(members)} {kind}")
        return out + ["```", ""]


def render(from_ref: str, head_ref: str, expand_all: bool) -> str:
    state_only = from_ref == head_ref
    base, head = snapshot(from_ref), snapshot(head_ref)
    main, tests = ({}, {}) if state_only else changes(from_ref, head_ref)
    if not state_only and not main and not tests:
        return ""
    plan, plan_packages = planned_classes(head_ref)
    planned = {key: path for key, path in plan.items() if key not in head.classes}

    classes_of: dict[str, list[str]] = defaultdict(list)  # component -> class keys shown in it
    class_kind: dict[str, str] = {}
    for key in head.classes:
        class_kind[key] = {"A": "added", "M": "changed"}.get(main.get(key, ""), "")
    for key, status in main.items():
        if status == "D" and key not in head.classes:
            class_kind[key] = "removed"
    for key in planned:
        class_kind[key] = "planned"
    for key in sorted(class_kind):
        classes_of[component_of_key(key)].append(key)

    touched = {component_of_key(key) for key in main}

    def component_kind(component: str) -> str:
        if component in head.components:
            if component not in base.components:
                return "added"
            return "changed" if component in touched else ""
        return "removed" if component in base.components else "planned"

    all_edges = head.component_edges | base.component_edges
    components = sorted(head.components | base.components | {c for e in all_edges for c in e} | set(classes_of))

    def component_label(component: str) -> str:
        counts = defaultdict(int)
        for key in classes_of[component]:
            counts[main.get(key, "")] += 1
        parts = [f"{sign}{counts[key]}" for sign, key in (("+", "A"), ("~", "M"), ("−", "D")) if counts[key]]
        if tests.get(component):
            parts.append(f"tests {tests[component]}")
        name = ROOT_PACKAGE.rsplit(".", 1)[-1] if component == ROOT_COMPONENT else component
        return name + ("<br/>" + " ".join(parts) if parts else "")

    # 1. Components inside the service boundary.
    one = Diagram()
    one.add(f'  subgraph service["{ROOT_PACKAGE}"]')
    groups: dict[str, list[str]] = defaultdict(list)
    for component in components:
        segments = component.split(".")
        groups[".".join(segments[:2]) if len(segments) > 2 else ""].append(component)
    for group, members in sorted(groups.items()):
        indent = "      " if group else "    "
        if group:
            one.add(f'    subgraph {node_id(group, "g_")}["{group}"]')
        for component in members:
            one.node(indent, node_id(component), component_label(component), component_kind(component))
        if group:
            one.add("    end")
    one.add("  end")
    table_owners: dict[str, list[str]] = defaultdict(list)  # component -> its tables
    for table, key in sorted((head.tables | base.tables).items()):
        table_owners[component_of_key(key)].append(table)
    if table_owners:
        tables = sorted(head.tables | base.tables)
        kind = "added" if not base.tables else "changed" if set(head.tables) != set(base.tables) else ""
        one.node("  ", "database", "database<br/>" + "<br/>".join(tables), kind, '[("{}")]')
    added_edges = sorted(head.component_edges - base.component_edges)
    removed_edges = sorted(base.component_edges - head.component_edges)
    for kind, edges in (
        ("kept", sorted(head.component_edges & base.component_edges)),
        ("added", added_edges),
        ("removed", removed_edges),
    ):
        for source, target in edges:
            one.edge(node_id(source), node_id(target), kind)
    for component in sorted(table_owners):
        one.edge(node_id(component), "database")
    out = one.render()

    legend = (
        "arrows: dependencies found in the code · dashed: planned in `specs/*/plan.md`, not in the code yet"
        if state_only
        else "green: new, yellow: changed, red: removed, dashed: planned in `specs/*/plan.md`, plain: untouched · "
        "`+` added, `~` modified, `−` deleted classes, `tests` test files touched · arrows: dependencies found in "
        "the code (thick green: new, dashed red: removed)"
    )
    revisions = f"`{head_ref[:7]}`" if state_only else f"`{from_ref[:7]}..{head_ref[:7]}`"
    out.append(f"<sub>{revisions} · {legend}</sub>")
    for title, edges in (("New dependencies", added_edges), ("Removed dependencies", removed_edges)):
        if edges and not state_only:
            out += ["", f"**{title}:** " + ", ".join(f"`{s}` → `{t}`" for s, t in edges)]

    # 2. Classes inside the components.
    opened = {c for c in components if classes_of[c] and (state_only or expand_all or c in touched)}
    if opened:

        def endpoint(key: str) -> str:
            component = component_of_key(key)
            return node_id(key, "k_") if component in opened else node_id(component)

        class_edges = set()
        for key, targets in head.classes.items():
            for target in targets:
                if {component_of_key(key), component_of_key(target)} & opened and endpoint(key) != endpoint(target):
                    class_edges.add((endpoint(key), endpoint(target)))
        linked = {node for edge in class_edges for node in edge}

        two = Diagram()
        for component in components:
            if component in opened:
                name = ROOT_PACKAGE.rsplit(".", 1)[-1] if component == ROOT_COMPONENT else component
                two.add(f'  subgraph {node_id(component, "s_")}["{name}"]')
                for key in classes_of[component]:
                    two.node("    ", node_id(key, "k_"), key.rsplit(".", 1)[-1], class_kind[key])
                two.add("  end")
            elif node_id(component) in linked:
                two.node("  ", node_id(component), component_label(component).split("<br/>")[0])
        shown_tables = sorted(t for t, key in head.tables.items() if component_of_key(key) in opened)
        if shown_tables:
            two.add('  subgraph database["database"]')
            for table in shown_tables:
                two.node("    ", node_id(table, "t_"), table, "" if table in base.tables else "added", '[("{}")]')
            two.add("  end")
        for source, target in sorted(class_edges):
            two.edge(source, target)
        for table in shown_tables:
            two.edge(node_id(head.tables[table], "k_"), node_id(table, "t_"))
        scope = "all components" if state_only or expand_all else "touched components opened, the others collapsed"
        out += ["", f"**Classes** ({scope})", ""] + two.render()

    if state_only:
        return "\n".join(out).rstrip("\n") + "\n"

    def names(component: str, status: str) -> str:
        found = sorted(k.rsplit(".", 1)[-1] for k in main if main[k] == status and component_of_key(k) == component)
        return ", ".join(f"`{name}`" for name in found) or "—"

    out += [
        "" if out[-1] else None,
        "<details><summary>Changed classes by component</summary>",
        "",
        "| Component | Added | Modified | Deleted | Test files touched |",
        "|---|---|---|---|---|",
    ]
    out = [line for line in out if line is not None]
    for component in sorted(touched | set(tests)):
        out.append(
            f"| `{component}` | {names(component, 'A')} | {names(component, 'M')} | {names(component, 'D')} "
            f"| {tests.get(component, 0)} |"
        )
    unplanned = sorted(
        key for key, status in main.items() if status == "A" and key not in plan and key.rpartition(".")[0] in plan_packages
    )
    if unplanned:
        out += ["", "Added, but not named in the plan: " + ", ".join(f"`{key}`" for key in unplanned)]
    out += ["", "</details>"]
    return "\n".join(out) + "\n"


def main() -> None:
    args = [arg for arg in sys.argv[1:] if arg != "--all"]
    if len(args) not in (1, 2) or any(arg.startswith("--") for arg in args):
        sys.exit("\n".join(__doc__.split("\n\n")[1].splitlines()))
    refs = [git("rev-parse", "--verify", f"{ref}^{{commit}}").decode().strip() for ref in args]
    sys.stdout.write(render(refs[0], refs[-1], expand_all="--all" in sys.argv))


if __name__ == "__main__":
    main()
