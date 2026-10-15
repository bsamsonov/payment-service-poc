# Lane `boundaries` — modules, layers and dependencies

Facts: `facts.md` (components, new and removed dependencies, cross-module edges, cycles, new packages,
`package-info.java`, ports, event markers). Project rules: `AGENTS.md` ("Architecture"), ADRs in `adr/` (module
structure, technology stack), `architecture.md` if present, the design and plan in `spec/`, ArchUnit rules in the
repository. A rule written there and broken here is `drift`; a dependency or placement no document settles is
`needs-decision`.

## Layers (hexagonal)
- BND-1 `domain` depends on nothing outside the domain: no Spring, JPA, Jackson, HTTP, persistence or adapter types.
- BND-2 `application` depends on `domain` and its own ports only; adapters depend on `application` (they implement
  its ports or call its use cases), never the other way round; `config` only wires.
- BND-3 A port is shaped by what the core needs, in the core's language, one port per need; it does not leak the
  technology behind it (no provider DTOs, SQL types, HTTP status codes in port signatures).

## Modules
- BND-4 Each module has a public API (named interface: ports, commands, read models, events) and internals; another
  module uses only the public API. A new import of another module's internal package is a finding.
- BND-5 Dependencies between modules point one way and match the module map; a new cross-module edge in `facts.md`
  is either named in the design/ADR or a `needs-decision`. Cycles are always findings.
- BND-6 Data ownership: a module reads another module's data through that module's API, never through its repository,
  entity or table.
- BND-7 Infrastructure modules (for example a payment provider integration) implement the ports of the domain modules;
  domain modules do not know them.
- BND-8 Reactions across modules: direct call vs. event is a conscious choice; an event that must survive a crash needs
  an outbox (Spring Modulith event publication registry); a synchronous call into another module inside the caller's
  transaction couples their consistency.
- BND-9 The shared kernel (money, identifiers, clock) stays small, stable and free of module logic; growth of shared
  code is a finding unless the design names it.

## Placement and language
- BND-10 New code lives in the module and layer the design names (package table of the plan/design); code added but
  not named there is reported.
- BND-11 Aggregates: one transaction changes one aggregate (plus its own journal); other aggregates are referenced by
  id. An invariant across two aggregates or modules is a design question.
- BND-12 One concept, one name across modules, contract, tables and spec.

## Guards
- BND-13 Every accepted boundary rule has an automated check (ArchUnit, Spring Modulith `ApplicationModules.verify()`);
  a new module or a new kind of dependency without one is reported as a candidate check.
