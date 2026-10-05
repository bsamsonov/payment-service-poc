# Repository rulesets

GitHub does not read these files. They are the versioned source of the rulesets configured on the
repository, applied manually by the repository owner.

| File | Ruleset |
|---|---|
| `main.json` | Protects the default branch: no deletion or force push, linear history, PR with resolved conversations, rebase-only merge, required checks (`Build and test (JDK 21)`, `Secrets scan (gitleaks)`, `Analyze (java-kotlin)`), no new CodeQL high+ security alerts or errors. |

## Apply

```bash
R=bsamsonov/payment-service-poc
# create
gh api -X POST repos/$R/rulesets --input .github/rulesets/main.json
# update an existing ruleset
ID=$(gh api repos/$R/rulesets --jq '.[] | select(.name=="main") | .id')
gh api -X PUT repos/$R/rulesets/$ID --input .github/rulesets/main.json
```

The same JSON can be imported in the UI: Settings → Rules → Rulesets → New ruleset → Import a ruleset.
