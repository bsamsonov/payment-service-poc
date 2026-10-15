# Lane `api` — public contract

Facts: `facts.md` (changed files, `oasdiff breaking`, `redocly lint`), full contract at the head in
`lanes/api/contract/api/`. Project rules: ADR-0006 (contract-first), ADR-0007 (identifiers), `context.md`, `AGENTS.md`
("Errors and API"), the spec ("API changes", acceptance criteria). A rule written there and broken here is `drift`;
a choice no document settles is `needs-decision`.

## Compatibility
- API-1 Everything a client can observe is permanent after release: paths, fields, status codes, error codes, enum
  values. A breaking change (removed or renamed field or path, narrower type, new required request field, new status
  code for an existing scenario) is a finding once the contract is published; before the first release it is a
  `needs-decision` with its cost. `oasdiff breaking` output is a fact, not yet a finding.
- API-2 Versioning: the change stays inside the version the project uses (`/api/v1`); an incompatible change asks
  for a version decision.

## Ownership and shape
- API-3 Each module owns its contract file and its paths (one file per module); a path, schema or example of one
  module does not appear in another module's file. Shared schemas (`Problem`, money) are referenced, not copied with
  differences.
- API-4 Resources are nouns of the domain language; the same concept has the same name in contract, spec, code and
  tables. Non-CRUD actions are modelled the same way everywhere.
- API-5 A response of one module does not carry data owned by another module (for example, refund totals in a
  payment response).

## Types and errors
- API-6 Money is an integer in minor units plus an ISO 4217 currency; identifiers are strings; timestamps RFC 3339
  with offset; enums are strings and the contract says what a client does with an unknown value.
- API-7 Errors are `application/problem+json` (RFC 9457) with stable, listed error codes; syntax and schema errors are
  `400`, business rules `422`; no stack traces, SQL, provider ids or PII in `detail`.
- API-8 Unsafe operations state their idempotency behaviour (`Idempotency-Key`, what a repeat with another body does).
- API-9 Every status code in the contract is produced by the code and covered by an acceptance criterion; no code the
  service never returns; examples validate against their schemas.

## Code against contract
- API-10 Hand-written web code (`adapter.in.web`) implements the generated interfaces; it does not add endpoints,
  parameters or response fields that the contract does not declare, and does not bypass generated DTOs.
