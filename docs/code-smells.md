# Code smells report (PMD/CPD)

Maintainability hints on every pull request: complexity, size, coupling, dead code and copy-paste.
They complement the blocking checks (Error Prone/NullAway, SpotBugs, CodeQL), which look for bugs.

**Informational only.** Findings never fail the build or block a merge; the job is not a required check.

## How it works

| Part | File |
|---|---|
| Rules (short, curated list) | [`config/pmd/ruleset.xml`](../config/pmd/ruleset.xml) |
| Maven profile `smells`: PMD + CPD bound to `verify`, `failOnViolation=false` | [`pom.xml`](../pom.xml) |
| PMD/CPD XML → SARIF (level `note`) + Markdown summary | [`scripts/smells/to-sarif.py`](../scripts/smells/to-sarif.py) |
| CI job `Code smells (PMD/CPD)`: runs the profile, uploads SARIF to code scanning | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |

Where to see the results:

- **PR → Files changed**: annotations on changed lines (GitHub shows code-scanning results for the diff only);
- **Actions → the CI run → Summary**: table of all findings;
- **Security → Code scanning**: all open findings, filter `tool:PMD` or `tool:CPD`.

Locally:

```bash
./mvnw verify -Psmells -DskipTests            # findings are printed as "PMD Failure" / CPD warnings
python3 scripts/smells/to-sarif.py . target/pmd.xml target/cpd.xml target/smells   # optional: SARIF + table
```

Main sources only; generated code (`target/generated-sources`) and tests are excluded.
CPD reports duplicates of 100 tokens or more, ignoring annotations.

## Tuning

- A rule is noisy → remove it from `config/pmd/ruleset.xml` or raise its threshold
  (e.g. `<properties><property name="reportLevel" value="20"/></properties>` for `CognitiveComplexity`).
- A single justified exception → `@SuppressWarnings("PMD.RuleName")` with a comment explaining why
  (AGENTS.md: suppressions require a written justification).
- A finding becomes a hard rule → move the check to a blocking tool or to `docs/review-checklist.md`.

## Switching it off

1. **Temporarily, without a code change**: set the repository variable `CODE_SMELLS` to `off`
   (Settings → Secrets and variables → Actions → Variables, or `gh variable set CODE_SMELLS --body off`).
   The job is skipped. Back on: delete the variable (`gh variable delete CODE_SMELLS`).
2. **Remove completely** (one PR): delete the `code-smells` job from `ci.yml`, the `smells` profile and the
   `maven-pmd-plugin.version`/`pmd.version` properties from `pom.xml`, `config/pmd/`, `scripts/smells/`,
   this file and the mentions in `README.md`, `AGENTS.md`, `docs/review-context.md`.
3. **Old alerts**: once uploads stop, existing PMD/CPD alerts stay in Security → Code scanning. Delete the
   analyses of categories `code-smells-pmd` and `code-smells-cpd`
   (`gh api repos/{owner}/{repo}/code-scanning/analyses?tool_name=PMD`, then `DELETE …/analyses/<id>?confirm_delete`)
   or dismiss the alerts.

## Cost

Free for a public repository: GitHub-hosted runner minutes and code scanning (SARIF upload) are free for public
repos; PMD is open source. Adds about a minute of CI time, in parallel with the main build. No LLM calls.
If the repository becomes private, code scanning needs GitHub Code Security: switch the job off or keep only the
job summary (drop the upload steps).
