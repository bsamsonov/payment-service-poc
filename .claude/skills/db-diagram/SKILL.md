---
name: db-diagram
description: Builds an ER diagram of the database (Mermaid, with keys, relations, constraints, indexes and triggers) from the Flyway migrations and highlights schema changes against an open PR's base, main or any revision. Use whenever the user wants to see the database structure or its changes — "/db-diagram", "show the schema", "ER diagram", "what changed in the database in PR N", "diagram from migrations", "покажи схему базы", "нарисуй диаграмму таблиц", "что изменилось в базе в PR N" — and before reviewing migrations or after editing them, even if the word "diagram" is not used.
argument-hint: "[--pr <n> | --base <ref>] [--head <ref>] [--no-diff]"
---

# /db-diagram

The schema is created only by Flyway migrations, so they are the full source of truth. `scripts/db/db_diagram.py`
applies the migrations of two revisions (base and head) to two databases in a throwaway PostgreSQL container, reads
both schemas from the system catalog and compares them. SQL is not parsed: the diagram shows what the database really
ends up with, including `ALTER TABLE` in later migrations. Needs `docker`, `git`, `python3`; `gh` for `--pr`.
Takes a few seconds; the container is removed automatically.

## What to compare

Pick the mode from the request; if the user did not say, use the default.

| Request | Arguments | Shown → compared with |
|---|---|---|
| default, "my changes", "before commit" | *(none)* | working tree, **uncommitted changes included** → fork point from `origin/main` |
| "in PR N" | `--pr N` | PR head → fork point from its base branch (the working tree is not used) |
| "against revision / branch / commit X" | `--base X` | working tree → `X` |
| two given revisions | `--base X --head Y` | `Y` → `X` |
| plain schema, no highlighting | `--no-diff` | working tree |

The default mode shows uncommitted migration edits, `--pr` does not. While the schema is being reworked and the user
wants to see the result before committing, use the default mode.

## Run

```bash
python3 scripts/db/db_diagram.py [--pr N | --base REF] --title "<title>" --out <file.md>
```

`--out`, unless the user names a file: `target/db-diagram/pr<N>.md` in PR mode, otherwise
`target/db-diagram/<branch>.md` (`/` in the branch name replaced by `-`). The file is a generated artifact, rewritten
as a whole and not committed; notes about the schema go elsewhere.

Other options: `--migrations <dir>` (if auto-detection of `*/db/migration` fails), `--image postgres:NN` (default
`postgres:17`, as in the project), `--no-table-color` (see below).

## Output

Markdown in three parts:

1. **Changes** — the changes in words: tables, columns, constraints, indexes, triggers.
2. **Diagram** — Mermaid `erDiagram`. Columns in the physical order of the table: name, type, keys (`PK`/`FK`/`UK`),
   notes. Notes hold the rules of one column: `nullable`, `> 0`, ranges `100..599`, `length 1..100`, `~ '<regex>'`,
   `CHECK enum`, a composite `UNIQUE (a, b)` and an index `index (a, b desc)` on its first column. A relation shows
   the FK column and the delete rule: `payment_id (no cascade)` / `(cascade)` / `(set null)`. Changes:
   - the table gets a coloured border (green new, yellow changed, red removed) and a mark in its title;
   - rows of a changed table are marked 🟢 new column, 🟡 changed (with the old value), 🔴 removed;
     "🟡 constraint changed" means the column is the same but a constraint on it changed;
   - removed tables, columns and relations stay on the diagram to show what disappears.
3. **Constraints, indexes, triggers** — full definitions with the same marks, **only for what the diagram does not
   show**: multi-column `CHECK`s, enum values, partial and non-btree indexes, triggers, any change of an existing rule.

Domains are shown only as column types; their allowed values are in the `V…__coded_value_domains.sql` migration.

## What to tell the user

- The file path and what was compared (the "Shown" / "Compared with" lines of the header).
- The **Changes** section, briefly. If there are none, say so.
- How to view it: IntelliJ IDEA Markdown preview with Mermaid enabled (`Settings` → `Languages & Frameworks` →
  `Markdown` → `Mermaid`); GitHub renders Mermaid in `.md` files and PR comments.

Do not retell the diagram table by table. Comment on the schema itself (normalization, indexes) only if a review was
asked for.

## When something goes wrong

- **`migration V… failed`** — a migration does not apply to a clean database. That is a finding, not a script
  failure: show the PostgreSQL error. A common cause during a rework is a broken order of dependencies between files.
- **The preview shows code instead of a diagram** — the Mermaid extension is not enabled in the IDE.
- **Mermaid parse error on `classDef` / `class` lines** — the renderer is older than Mermaid 11 and cannot colour ER
  tables. Regenerate with `--no-table-color`: the 🟢🟡🔴 marks stay.
- **No Docker or image** — the script needs a running Docker; `postgres:17` is pulled on first use.

## Limitations

- PostgreSQL and schema `public` only; SQL migrations (`V…__*.sql`, then `R__*.sql`). Java migrations and Flyway
  placeholders (`${…}`) are not supported — if they appear, extend the script instead of working around it.
- Colour is per table (border); Mermaid cannot highlight a single row, so columns get coloured marks.
- A renamed column or table shows as removed + added: the catalog cannot tell them apart.
