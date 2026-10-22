#!/usr/bin/env python3
"""ER diagram of a Flyway-managed PostgreSQL schema, with changes against a base revision highlighted.

How it works: the migrations of two revisions (base and head) are applied to two databases in a throwaway
PostgreSQL container, both schemas are read from the system catalog, compared, and rendered as Markdown with a
Mermaid `erDiagram` plus a list of constraints, indexes and triggers. Reading the catalog instead of parsing SQL
means the diagram shows what the database really ends up with (including `ALTER TABLE` in later migrations).

Only the standard library, `git` and `docker` are needed (`gh` for --pr).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

ADDED, REMOVED, CHANGED, SAME = "added", "removed", "changed", "same"
MARK = {ADDED: "🟢", REMOVED: "🔴", CHANGED: "🟡", SAME: ""}
WORD = {ADDED: "new", REMOVED: "removed", CHANGED: "changed", SAME: ""}

INTROSPECT_SQL = r"""
select coalesce(jsonb_object_agg(c.relname, jsonb_build_object(
  'columns', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', a.attname,
             'type', format_type(a.atttypid, a.atttypmod),
             'not_null', a.attnotnull,
             'default', pg_get_expr(d.adbin, d.adrelid)) order by a.attnum), '[]'::jsonb)
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped),
  'constraints', (
    select coalesce(jsonb_object_agg(k.conname, jsonb_build_object(
             'type', k.contype,
             'def', pg_get_constraintdef(k.oid),
             'columns', (select coalesce(jsonb_agg(a.attname order by u.ord), '[]'::jsonb)
                         from unnest(k.conkey) with ordinality u(attnum, ord)
                         join pg_attribute a on a.attrelid = k.conrelid and a.attnum = u.attnum),
             'ref_table', (select r.relname from pg_class r where r.oid = k.confrelid))), '{}'::jsonb)
    from pg_constraint k where k.conrelid = c.oid),
  'indexes', (
    select coalesce(jsonb_object_agg(ic.relname, pg_get_indexdef(i.indexrelid)), '{}'::jsonb)
    from pg_index i join pg_class ic on ic.oid = i.indexrelid
    where i.indrelid = c.oid
      and not exists (select 1 from pg_constraint k where k.conindid = i.indexrelid)),
  'triggers', (
    select coalesce(jsonb_object_agg(t.tgname, pg_get_triggerdef(t.oid)), '{}'::jsonb)
    from pg_trigger t where t.tgrelid = c.oid and not t.tgisinternal)
)), '{}'::jsonb)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relname <> 'flyway_schema_history';
"""


def run(cmd: list[str], *, cwd: Path | None = None, stdin: str | None = None, check: bool = True) -> str:
    result = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(cmd)}\n{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


# ---------------------------------------------------------------- migrations

def version_key(filename: str) -> tuple:
    version = re.match(r"V([0-9._]+)__", filename).group(1)
    return tuple(int(part) for part in re.split(r"[._]", version) if part)


def ordered(files: dict[str, str]) -> list[tuple[str, str]]:
    """Flyway order: versioned migrations by version, then repeatable ones by description."""
    versioned = sorted((n for n in files if re.match(r"V[0-9._]+__.*\.sql$", n)), key=version_key)
    repeatable = sorted(n for n in files if re.match(r"R__.*\.sql$", n))
    return [(name, files[name]) for name in versioned + repeatable]


def find_migration_dir(repo: Path) -> str:
    tracked = run(["git", "ls-files", "--", "*db/migration/*.sql"], cwd=repo).split()
    on_disk = [str(p.relative_to(repo)) for p in repo.glob("src/**/db/migration/*.sql")]
    dirs = sorted({str(Path(p).parent) for p in tracked + on_disk if "/test/" not in p})
    if not dirs:
        raise SystemExit("no db/migration/*.sql found; pass --migrations <dir relative to the repo>")
    if len(dirs) > 1:
        raise SystemExit(f"several migration directories found, pass --migrations: {', '.join(dirs)}")
    return dirs[0]


def migrations_at(repo: Path, ref: str | None, directory: str) -> dict[str, str]:
    """Migration files of a git revision, or of the working tree when ref is None."""
    if ref is None:
        return {p.name: p.read_text(encoding="utf-8") for p in sorted((repo / directory).glob("*.sql"))}
    names = run(["git", "ls-tree", "--name-only", ref, f"{directory}/"], cwd=repo).split()
    return {Path(n).name: run(["git", "show", f"{ref}:{n}"], cwd=repo) for n in names if n.endswith(".sql")}


# ---------------------------------------------------------------- database

class Postgres:
    def __init__(self, image: str):
        self.image = image
        self.name = f"db-diagram-{uuid.uuid4().hex[:8]}"

    def __enter__(self) -> "Postgres":
        run(["docker", "run", "-d", "--rm", "--name", self.name, "-e", "POSTGRES_PASSWORD=diagram", self.image])
        deadline = time.time() + 60
        # TCP answers only after the image's init restart, so this is the real "ready".
        while subprocess.run(["docker", "exec", self.name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
                             capture_output=True).returncode != 0:
            if time.time() > deadline:
                raise SystemExit("PostgreSQL container did not become ready in 60 s")
            time.sleep(0.5)
        return self

    def __exit__(self, *_: object) -> None:
        subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)

    def psql(self, database: str, sql: str, what: str) -> str:
        result = subprocess.run(
            ["docker", "exec", "-i", self.name, "psql", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1",
             "-q", "-At", "-f", "-"], input=sql, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"{what} failed:\n{result.stderr.strip()}")
        return result.stdout

    def schema(self, database: str, files: dict[str, str]) -> dict:
        self.psql("postgres", f"create database {database};", f"create database {database}")
        for name, sql in ordered(files):
            self.psql(database, sql, f"migration {name} ({database})")
        return json.loads(self.psql(database, INTROSPECT_SQL, "schema introspection"))


# ---------------------------------------------------------------- diff

def status(old: object, new: object) -> str:
    if old is None:
        return ADDED
    if new is None:
        return REMOVED
    return SAME if old == new else CHANGED


def diff_named(old: dict, new: dict) -> list[dict]:
    """Compare two name -> definition maps; removed items are kept so the report can show them."""
    return [{"name": name, "status": status(old.get(name), new.get(name)),
             "old": old.get(name), "new": new.get(name)} for name in sorted(old.keys() | new.keys())]


def diff_columns(old: list[dict], new: list[dict]) -> list[dict]:
    old_by, new_by = {c["name"]: c for c in old}, {c["name"]: c for c in new}
    rows = [{"name": c["name"], "status": status(old_by.get(c["name"]), c), "old": old_by.get(c["name"]), "new": c}
            for c in new]
    rows += [{"name": c["name"], "status": REMOVED, "old": c, "new": None} for c in old if c["name"] not in new_by]
    return rows


def diff_schema(base: dict, head: dict) -> list[dict]:
    tables = []
    for name in sorted(base.keys() | head.keys()):
        old, new = base.get(name), head.get(name)
        empty = {"columns": [], "constraints": {}, "indexes": {}, "triggers": {}}
        o, n = old or empty, new or empty
        table = {
            "name": name,
            "columns": diff_columns(o["columns"], n["columns"]),
            "constraints": diff_named(o["constraints"], n["constraints"]),
            "indexes": diff_named(o["indexes"], n["indexes"]),
            "triggers": diff_named(o["triggers"], n["triggers"]),
        }
        parts = table["columns"] + table["constraints"] + table["indexes"] + table["triggers"]
        table["status"] = (ADDED if old is None else REMOVED if new is None
                           else CHANGED if any(p["status"] != SAME for p in parts) else SAME)
        tables.append(table)
    return tables


# ---------------------------------------------------------------- rendering

TYPE_ALIASES = [
    (r"character varying", "varchar"), (r"timestamp with time zone", "timestamptz"),
    (r"timestamp without time zone", "timestamp"), (r"time with time zone", "timetz"),
    (r"time without time zone", "time"), (r"double precision", "float8"), (r"\bcharacter\b", "char"),
]


def short_type(pg_type: str) -> str:
    for pattern, alias in TYPE_ALIASES:
        pg_type = re.sub(pattern, alias, pg_type)
    # Mermaid attribute words allow only letters, digits, - _ ( ) [ ]
    return re.sub(r"[^A-Za-z0-9_()\[\]-]", "_", pg_type.replace(", ", "_").replace(",", "_"))


def quote(text: str) -> str:
    return text.replace('"', "'")


def touched_columns(table: dict) -> set[str]:
    """Columns of a changed table whose constraints changed while the column itself did not."""
    if table["status"] != CHANGED:
        return set()
    return {name for c in table["constraints"] if c["status"] != SAME
            for name in (c["new"] or c["old"])["columns"]}


def column_note(row: dict, constraint_changed: bool = False) -> str:
    col, old = row["new"] or row["old"], row["old"]
    notes = []
    if row["status"] != SAME:
        notes.append(f"{MARK[row['status']]} {WORD[row['status']]}")
    elif constraint_changed:
        notes.append(f"{MARK[CHANGED]} constraint changed")
    if row["status"] == CHANGED:
        if old["type"] != col["type"]:
            notes.append(f"was {short_type(old['type'])}")
        if old["not_null"] != col["not_null"]:
            notes.append("was NOT NULL" if old["not_null"] else "was nullable")
        if old["default"] != col["default"]:
            notes.append(f"default was {old['default'] or 'none'}")
    if not col["not_null"]:
        notes.append("nullable")
    if col["default"] is not None:
        notes.append("default " + re.sub(r"::[a-z ]+(\[\])?", "", col["default"]))
    return ", ".join(notes)


def simplify(expr: str) -> str:
    """A CHECK expression as a person would write it: no casts, no redundant parentheses."""
    expr = re.sub(r"::[a-z_]+(?: varying| precision)?(\(\d+\))?(\[\])?", "", expr)
    expr = re.sub(r"(?<!\w)\(([\w.]+)\)", r"\1", expr)  # (status) -> status, char_length(x) stays
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        for i, ch in enumerate(expr):
            depth += {"(": 1, ")": -1}.get(ch, 0)
            if depth == 0 and i < len(expr) - 1:
                return expr
        expr = expr[1:-1]
    return expr


def check_rule(column: str, definition: str) -> str | None:
    """Short form of a CHECK that constrains this column alone: "> 0", "0..amount", "CHECK enum"."""
    match = re.fullmatch(r"CHECK \((.*)\)( NOT VALID)?", definition, re.S)
    if not match:
        return None
    expr = simplify(match.group(1))
    for subject, prefix in ((re.escape(column), ""), (rf"(?:char_)?length\({re.escape(column)}\)", "length ")):
        rng = re.fullmatch(rf"\({subject} >= (\S+)\) AND \({subject} <= (\S+)\)", expr)
        if rng:
            return f"{prefix}{rng.group(1)}..{rng.group(2)}"
        if re.fullmatch(rf"{subject} = ANY \(.*\)|{subject} IN \(.*\)", expr):
            return "CHECK enum"
        cmp = re.fullmatch(rf"{subject} (<>|<=|>=|<|>|=|~\*?) (.+)", expr)
        if cmp:
            return f"{prefix}{cmp.group(1)} {cmp.group(2)}"
    return "CHECK " + (expr if len(expr) <= 60 else expr[:57] + "...")


def index_columns(definition: str) -> list[str]:
    match = re.search(r"USING \w+ \((.*?)\)(?: INCLUDE| WHERE|$)", definition)
    return [c.strip() for c in match.group(1).split(",")] if match else []


def column_rules(table: dict, column: str, removed: bool) -> list[tuple[str, str | None]]:
    """Rules a reader needs next to the column: its CHECKs, composite UNIQUE and indexes it leads.
    Multi-column CHECKs that are not a simple range stay in the list below the diagram.
    Each rule comes with the name of the constraint or index when the rule says all of it (so the list below
    can skip it), or None when the short form loses something (enum values, a cut expression, a WHERE)."""
    side = "old" if removed else "new"
    rules = []
    for c in table["constraints"]:
        con = c[side]
        if not con:
            continue
        if con["type"] == "c":
            # check_rule matches only expressions with this column as the subject; a generic multi-column
            # CHECK would not explain itself next to one column, so it stays in the list below.
            rule = check_rule(column, con["def"]) if column in con["columns"] else None
            if rule and (con["columns"] == [column] or not rule.startswith("CHECK ")):
                lossy = rule == "CHECK enum" or rule.endswith("...")
                rules.append((rule, None if lossy else c["name"]))
        elif con["type"] == "u" and len(con["columns"]) > 1 and con["columns"][0] == column:
            rules.append((f"UNIQUE ({', '.join(con['columns'])})", c["name"]))
    for i in table["indexes"]:
        definition = i[side]
        if not definition:
            continue
        columns = index_columns(definition)
        if columns and columns[0].split()[0] == column:
            kind = "unique index" if definition.startswith("CREATE UNIQUE") else "index"
            where = " partial" if " WHERE " in definition else ""
            shown = ", ".join(c.replace(" DESC", " desc") for c in columns)
            exact = not where and " INCLUDE " not in definition and " USING btree " in definition
            rules.append((f"{kind}{where} ({shown})" if len(columns) > 1 else f"{kind}{where}",
                          i["name"] if exact else None))
    return rules


def shown_on_diagram(table: dict) -> dict[str, set[str]]:
    """Names of constraints and indexes the diagram already says in full, per side ("new" / "old")."""
    shown: dict[str, set[str]] = {"new": set(), "old": set()}
    for side in shown:
        for c in table["constraints"]:
            con = c[side]
            if not con:
                continue
            simple_fk = re.fullmatch(r"FOREIGN KEY \([\w, ]+\) REFERENCES \w+\(id\)"
                                     r"( ON DELETE (CASCADE|SET NULL|SET DEFAULT|RESTRICT))?", con["def"])
            if con["type"] == "p" or (con["type"] == "u" and len(con["columns"]) == 1) \
                    or (con["type"] == "f" and simple_fk):
                shown[side].add(c["name"])
    for row in table["columns"]:
        side = "old" if row["new"] is None else "new"
        shown[side] |= {name for _, name in column_rules(table, row["name"], row["new"] is None) if name}
    return shown


def on_delete(definition: str) -> str:
    match = re.search(r"ON DELETE (CASCADE|SET NULL|SET DEFAULT|RESTRICT)", definition)
    return match.group(1).lower() if match else "no cascade"


def column_keys(table: dict, column: str, removed: bool) -> list[str]:
    side = "old" if removed else "new"
    keys = []
    for kind, label in (("p", "PK"), ("f", "FK"), ("u", "UK")):
        for c in table["constraints"]:
            con = c[side]
            # Composite unique constraints are listed below the diagram instead: UK on one column would mislead.
            if con and con["type"] == kind and column in con["columns"] and (kind != "u" or len(con["columns"]) == 1):
                keys.append(label)
                break
    return keys


def relationships(tables: list[dict]) -> list[str]:
    lines = []
    for table in tables:
        for c in table["constraints"]:
            con = c["new"] or c["old"]
            if con["type"] != "f":
                continue
            side = "new" if c["new"] else "old"
            columns = {r["name"]: r[side] for r in table["columns"] if r[side]}
            nullable = any(not columns[name]["not_null"] for name in con["columns"] if name in columns)
            unique = any(k[side] and k[side]["type"] in ("p", "u") and k[side]["columns"] == con["columns"]
                         for k in table["constraints"])
            arrow = ("|o" if nullable else "||") + "--" + ("o|" if unique else "o{")
            label = f'{", ".join(con["columns"])} ({on_delete(con["def"])})'
            if c["status"] != SAME and table["status"] not in (ADDED, REMOVED):
                label = f"{MARK[c['status']]} {label} ({WORD[c['status']]})"
            lines.append(f'    {con["ref_table"]} {arrow} {table["name"]} : "{quote(label)}"')
    return lines


def mermaid(tables: list[dict], color_tables: bool) -> str:
    out = ["```mermaid", "erDiagram"]
    out += relationships(tables)
    for table in tables:
        title = table["name"]
        if table["status"] != SAME:
            title = f'{title}["{title} {MARK[table["status"]]} {WORD[table["status"]]}"]'
        out += ["", f"    {title} {{"]
        touched = touched_columns(table)
        for row in table["columns"]:
            col = row["new"] or row["old"]
            keys = ", ".join(column_keys(table, row["name"], row["new"] is None))
            # In a new or removed table every row has the table's status, so the header marker is enough.
            whole = table["status"] in (ADDED, REMOVED)
            note = column_note({**row, "status": SAME} if whole else row, row["name"] in touched)
            rules = [text for text, _ in column_rules(table, row["name"], row["new"] is None)]
            note = ", ".join([n for n in [note] if n] + rules)
            line = f"        {row['name']} {short_type(col['type'])}"
            line += f" {keys}" if keys else ""
            line += f' "{quote(note)}"' if note else ""
            out.append(line)
        out.append("    }")
    if color_tables:
        colored = [t for t in tables if t["status"] != SAME]
        if colored:
            out += ["",
                    # Only the border: the default theme fill stays, as in the hand-drawn diagrams.
                    "    classDef added stroke:#1a7f37,stroke-width:2px",
                    "    classDef removed stroke:#cf222e,stroke-width:2px",
                    "    classDef changed stroke:#d4a72c,stroke-width:2px"]
            out += [f"    class {t['name']} {t['status']}" for t in colored]
    out.append("```")
    return "\n".join(out)


def details(tables: list[dict]) -> str:
    """Constraints, indexes and triggers the diagram does not already say in full: multi-column CHECKs, enum
    values, partial indexes, triggers, and every change of an existing constraint (the diagram shows no "was")."""
    out = []
    for table in tables:
        shown = shown_on_diagram(table)
        sections = [("Constraints", table["constraints"], lambda v: v["def"]),
                    ("Indexes", table["indexes"], lambda v: v), ("Triggers", table["triggers"], lambda v: v)]
        body = []
        for title, items, text in sections:
            lines = []
            for item in items:
                status = item["status"]
                side = "old" if status == REMOVED else "new"
                if status != CHANGED and item["name"] in shown[side]:
                    continue
                marker = f"{MARK[status]} " if status != SAME else ""
                current = text(item["new"] if item["new"] is not None else item["old"])
                line = f"- {marker}`{item['name']}`: `{current}`"
                if status == CHANGED:
                    line += f" — was `{text(item['old'])}`"
                elif status == REMOVED:
                    line += " — removed"
                lines.append(line)
            if lines:
                body += [f"**{title}**", "", *lines, ""]
        if body:
            mark = f" {MARK[table['status']]} {WORD[table['status']]}" if table["status"] != SAME else ""
            out += [f"### `{table['name']}`{mark}", "", *body]
    return "\n".join(out) if out else "Nothing beyond the diagram."


def summary(tables: list[dict]) -> str:
    lines = []
    for table in tables:
        if table["status"] == SAME:
            continue
        if table["status"] in (ADDED, REMOVED):
            lines.append(f"- {MARK[table['status']]} table `{table['name']}` {WORD[table['status']]}")
            continue
        for kind in ("columns", "constraints", "indexes", "triggers"):
            for item in table[kind]:
                if item["status"] != SAME:
                    lines.append(f"- {MARK[item['status']]} `{table['name']}`: {kind[:-1].replace('indexe', 'index')} "
                                 f"`{item['name']}` {WORD[item['status']]}")
    return "\n".join(lines) if lines else "No schema changes."


def render(tables: list[dict], *, title: str, base_label: str, head_label: str, files: list[str],
           color_tables: bool) -> str:
    return "\n".join([
        f"# {title}", "",
        f"Generated by the `db-diagram` skill from Flyway migrations: {', '.join(f'`{f}`' for f in files) or 'none'}.",
        "",
        f"- **Shown:** {head_label}", f"- **Compared with:** {base_label}", "",
        "Legend: 🟢 new · 🟡 changed · 🔴 removed (kept on the diagram to show what disappears). "
        "Columns are in the physical order of the table.", "",
        "## Changes", "", summary(tables), "",
        "## Diagram", "", mermaid(tables, color_tables), "",
        "## Constraints, indexes, triggers", "",
        "Only what the diagram does not show: multi-column checks, enum values, partial indexes, triggers, changes "
        "of existing rules. Keys, single-column checks, unique constraints and plain indexes are on the diagram.", "", details(tables)]).rstrip() + "\n"


# ---------------------------------------------------------------- main

def resolve(repo: Path, args: argparse.Namespace) -> tuple[str | None, str | None, str, str]:
    """Returns (base ref or None for an empty schema, head ref or None for the working tree, labels)."""
    def short(ref: str) -> str:
        return run(["git", "rev-parse", "--short", ref], cwd=repo).strip()

    if args.pr:
        pr = json.loads(run(["gh", "pr", "view", str(args.pr), "--json", "baseRefName,headRefOid,headRefName,title"],
                            cwd=repo))
        run(["git", "fetch", "-q", "origin", pr["baseRefName"], pr["headRefOid"]], cwd=repo, check=False)
        head = pr["headRefOid"]
        base = run(["git", "merge-base", f"origin/{pr['baseRefName']}", head], cwd=repo).strip()
        return (base, head, f"`{pr['baseRefName']}` at the PR's fork point (`{short(base)}`)",
                f"PR #{args.pr} «{pr['title']}», `{pr['headRefName']}` (`{short(head)}`)")

    head = args.head
    head_label = f"`{head}` (`{short(head)}`)" if head else "working tree (uncommitted changes included)"
    if args.no_diff:
        return None, head, "nothing (plain diagram)", head_label
    if args.base:
        return args.base, head, f"`{args.base}` (`{short(args.base)}`)", head_label
    main = next((r for r in ("origin/main", "main", "origin/master", "master")
                 if subprocess.run(["git", "rev-parse", "-q", "--verify", r], cwd=repo, capture_output=True)
                 .returncode == 0), None)
    if main is None:
        raise SystemExit("no main/master branch found; pass --base <ref> or --no-diff")
    base = run(["git", "merge-base", main, head or "HEAD"], cwd=repo).strip()
    return base, head, f"`{main}` at the fork point (`{short(base)}`)", head_label


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=".", help="git repository with the migrations (default: current directory)")
    parser.add_argument("--migrations", help="migration directory relative to the repo (default: auto-detected)")
    parser.add_argument("--pr", type=int, help="compare an open pull request with its base branch (needs gh)")
    parser.add_argument("--base", help="revision to compare with (default: fork point from main)")
    parser.add_argument("--head", help="revision to show (default: working tree, uncommitted changes included)")
    parser.add_argument("--no-diff", action="store_true", help="plain diagram without change highlighting")
    parser.add_argument("--no-table-color", action="store_true",
                        help="skip Mermaid classDef colouring (for renderers older than Mermaid 11)")
    parser.add_argument("--image", default="postgres:17", help="PostgreSQL image (default: postgres:17)")
    parser.add_argument("--title", default="Database schema")
    parser.add_argument("--out", help="output Markdown file (default: stdout)")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    directory = args.migrations or find_migration_dir(repo)
    base_ref, head_ref, base_label, head_label = resolve(repo, args)
    head_files = migrations_at(repo, head_ref, directory)
    base_files = migrations_at(repo, base_ref, directory) if base_ref else {}
    if not head_files and not base_files:
        raise SystemExit(f"no migrations in {directory} on either side")

    with Postgres(args.image) as pg:
        head = pg.schema("head", head_files)
        base = head if args.no_diff else pg.schema("base", base_files)

    tables = diff_schema(base, head)
    text = render(tables, title=args.title, base_label=base_label, head_label=head_label,
                  files=[name for name, _ in ordered(head_files)], color_tables=not args.no_table_color)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="utf-8")
        changed = sum(1 for t in tables if t["status"] != SAME)
        print(f"{args.out}: {len(tables)} tables, {changed} with changes", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
