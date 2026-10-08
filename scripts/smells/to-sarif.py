#!/usr/bin/env python3
"""Convert PMD and CPD XML reports to SARIF 2.1.0 for GitHub code scanning.

Usage: scripts/smells/to-sarif.py <repo-root> <pmd.xml> <cpd.xml> <out-dir>
Writes <out-dir>/pmd.sarif and <out-dir>/cpd.sarif; prints a Markdown summary to stdout.

Every result gets level "note": code smells are hints for the reviewer, so they must never
fail the "Code scanning results" check or block a merge. Paths are made relative to <repo-root>.
Standard library only (runs on a bare CI runner).
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SARIF_SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
PMD_NS = "{http://pmd.sourceforge.net/report/2.0.0}"
CPD_NS = "{https://pmd-code.org/schema/cpd-report}"


def relative(path: str, root: Path) -> str:
    try:
        return Path(path).resolve().relative_to(root).as_posix()
    except ValueError:
        return path


def region(start: str, end: str | None = None, col: str | None = None, end_col: str | None = None) -> dict:
    r = {"startLine": int(start)}
    if end:
        r["endLine"] = int(end)
    if col:
        r["startColumn"] = int(col)
    if end_col and end and end != start:
        r["endColumn"] = int(end_col)
    return r


def location(path: str, reg: dict, location_id: int | None = None) -> dict:
    loc = {"physicalLocation": {"artifactLocation": {"uri": path}, "region": reg}}
    if location_id is not None:
        loc["id"] = location_id
    return loc


def sarif(tool: str, version: str, info_uri: str, rules: list, results: list) -> dict:
    return {
        "$schema": SARIF_SCHEMA,
        "version": "2.1.0",
        "runs": [
            {
                "tool": {"driver": {"name": tool, "version": version, "informationUri": info_uri, "rules": rules}},
                "results": results,
            }
        ],
    }


def convert_pmd(report: Path, root: Path) -> tuple[dict, list]:
    tree = ET.parse(report).getroot()
    rules: dict[str, dict] = {}
    results, rows = [], []
    for file in tree.iter(f"{PMD_NS}file"):
        path = relative(file.get("name", ""), root)
        for v in file.iter(f"{PMD_NS}violation"):
            rule = v.get("rule", "unknown")
            message = " ".join((v.text or "").split())
            rules.setdefault(
                rule,
                {
                    "id": rule,
                    "name": rule,
                    "shortDescription": {"text": rule},
                    "helpUri": v.get("externalInfoUrl", ""),
                    "properties": {"tags": ["maintainability", "code-smell", v.get("ruleset", "")]},
                    "defaultConfiguration": {"level": "note"},
                },
            )
            line = v.get("beginline", "1")
            results.append(
                {
                    "ruleId": rule,
                    "level": "note",
                    "message": {"text": message},
                    "locations": [
                        location(path, region(line, v.get("endline"), v.get("begincolumn"), v.get("endcolumn")))
                    ],
                }
            )
            rows.append((path, int(line), rule, message))
    doc = sarif("PMD", tree.get("version", ""), "https://pmd.github.io", sorted(rules.values(), key=lambda r: r["id"]), results)
    return doc, rows


def convert_cpd(report: Path, root: Path) -> tuple[dict, list]:
    tree = ET.parse(report).getroot()
    rule_id = "DuplicatedCode"
    results, rows = [], []
    for dup in tree.iter(f"{CPD_NS}duplication"):
        files = [
            (relative(f.get("path", ""), root), f.get("line", "1"), f.get("endline"))
            for f in dup.findall(f"{CPD_NS}file")
        ]
        if not files:
            continue
        lines, tokens = dup.get("lines", "?"), dup.get("tokens", "?")
        for i, (path, line, end) in enumerate(files):
            others = [(p, ln, e) for j, (p, ln, e) in enumerate(files) if j != i]
            links = ", ".join(f"[{p}:{ln}]({k + 1})" for k, (p, ln, _) in enumerate(others))
            results.append(
                {
                    "ruleId": rule_id,
                    "level": "note",
                    "message": {"text": f"{lines} lines ({tokens} tokens) duplicated in {links}."},
                    "locations": [location(path, region(line, end))],
                    "relatedLocations": [location(p, region(ln, e), k + 1) for k, (p, ln, e) in enumerate(others)],
                }
            )
            rows.append((path, int(line), rule_id, f"{lines} lines duplicated in {len(others)} other place(s)"))
    rule = {
        "id": rule_id,
        "name": rule_id,
        "shortDescription": {"text": "Duplicated code (copy-paste)"},
        "helpUri": "https://docs.pmd-code.org/latest/pmd_userdocs_cpd.html",
        "properties": {"tags": ["maintainability", "code-smell", "duplication"]},
        "defaultConfiguration": {"level": "note"},
    }
    return sarif("CPD", tree.get("pmdVersion", ""), "https://pmd.github.io", [rule], results), rows


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[4])
    out.mkdir(parents=True, exist_ok=True)
    all_rows = []
    for name, convert, report in (("pmd", convert_pmd, sys.argv[2]), ("cpd", convert_cpd, sys.argv[3])):
        report_path = Path(report)
        if not report_path.is_file():
            print(f"{report}: not found", file=sys.stderr)
            return 1
        doc, rows = convert(report_path, root)
        (out / f"{name}.sarif").write_text(json.dumps(doc, indent=2), encoding="utf-8")
        all_rows += rows

    print("## Code smells (PMD/CPD)\n")
    if not all_rows:
        print("No code smells found.")
        return 0
    print(f"{len(all_rows)} finding(s). Informational only; they never fail the build.\n")
    print("| File | Line | Rule | Message |\n|---|---|---|---|")
    for path, line, rule, message in sorted(all_rows):
        print(f"| `{path}` | {line} | {rule} | {message.replace('|', '\\|')} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
