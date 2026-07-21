---
adr_id: ADR-0012
title: Automated code formatting (Spotless) and static style checks (Checkstyle) in build & CI
service: Cross-cutting
status: COMPLETED
date: 2026-07-09
depends_on:
  - SPEC-CODING-STANDARDS
  - ADR-0006
---

# ADR-0012 — Enforce formatting (Spotless) and style (Checkstyle) in build + CI

# Status

`COMPLETED`. Cross-cutting methodology/tooling change; recorded once (not one per service,
like ADR-0006) because it alters the build/CI process uniformly, not any single service's
behavior.

**What was applied (all 8 services):**
- `build.gradle` — added `com.diffplug.spotless` (palantirJavaFormat, remove-unused-imports,
  trim-trailing-whitespace, end-with-newline) and the `checkstyle` plugin, wired to a shared
  `config/checkstyle/checkstyle.xml`. `checkstyleTest` is disabled so the style gate targets
  main sources.
- CI (`.github/workflows/ci.yml`) — the build step now runs
  `./gradlew spotlessCheck checkstyleMain test`.

**Checkstyle ruleset (lean by design, to pass the palantir-formatted existing code):**
LineLength(120), RedundantImport, UnusedImports, NeedBraces (with
`allowSingleLineStatement=true` — single-line guard clauses like `if (x) return y;` are kept
as-is by palantir and allowed), EmptyStatement, OneStatementPerLine, UpperEll, EqualsHashCode.
Formatting is owned by Spotless, so Checkstyle is a light safety net. Intentionally deferred
(to tighten later): `AvoidStarImport` (travel-cart still uses star imports) and naming rules.

**One-time adoption step (per service repo):** run `./gradlew spotlessApply` once, review the
formatting diff and commit it. Until that first `spotlessApply` is committed, `spotlessCheck`
in CI reports the existing code as unformatted; after it, the gate stays green.

# Context

`coding-standards.md` defines conventions (naming, iteration, Lombok, layering) but nothing
**mechanically enforces** them. Observed drift: classic `for` loops where Stream/for-each
reads better, single-letter lambda/variable names, and inconsistent formatting between
services. Manual review is the only gate, so style nits consume review time and slip
through unevenly. ADR-0006 already establishes a CI pipeline (OpenAPI generate + diff),
so there is a natural home for additional build-time gates.

# Decision

1. **Auto-formatting via Spotless + palantir-java-format.** Each service's Gradle build
   SHALL apply the Spotless plugin with **palantir-java-format** (4-space indentation,
   matching the existing code — google-java-format's 2-space would reformat the whole
   tree). Spotless also enforces import order, trailing-whitespace and end-of-file rules.
   `spotlessApply` formats; `spotlessCheck` fails the build on unformatted code.
2. **Static style checks via Checkstyle.** A shared Checkstyle ruleset (one file at the
   repo root, imported by every service) SHALL encode the mechanically-checkable rules
   from `coding-standards.md` — notably: no single-letter identifiers (except generic type
   params), no `System.out`, no star imports, method/parameter naming, and basic size
   limits. `checkstyleMain` runs in the build.
3. **CI enforcement.** CI SHALL run `spotlessCheck` and `checkstyleMain` (alongside the
   ADR-0006 contract diff) and fail on violation. Formatting/style is thus a gate, not a
   review preference.
4. **Rollout.** A first repo-wide `spotlessApply` + Checkstyle-baseline commit normalizes
   the tree; that commit is formatting-only and reviewed as such. Rules that would be too
   noisy initially MAY start as warnings and be promoted to errors incrementally.
5. **Scope.** Java only (Spotless/Checkstyle). The "prefer Stream over `for`" guidance is
   advisory (hard to encode reliably in Checkstyle) and stays a review point.

# Consequences

**Positive.** Consistent formatting with zero review effort; mechanical enforcement of the
naming/`System.out`/import rules; smaller, cleaner diffs; less bikeshedding. Fits the
existing CI.

**Negative / trade-offs.** One large normalization diff up front (mitigated: formatting-only
commit). A slightly slower build (extra tasks). Checkstyle can only enforce a subset of the
standards — semantic rules (Stream preference, "names add context") still rely on review.
palantir-java-format is opinionated; developers give up per-file formatting preferences.

# Documents to update at implementation

- `docs/coding-standards.md` — add a **Formatting & Static Analysis** section pointing to
  Spotless (palantir-java-format) + Checkstyle as the enforced tooling.
- `docs/constraints.md` — add a Code-Quality rule: builds SHALL run `spotlessCheck` +
  `checkstyleMain` and CI SHALL fail on violation.
- Per-service `build.gradle` — apply and configure the plugins; add the shared Checkstyle
  ruleset at the repo root.
- CI workflow(s) — run the checks.

# Implementation tasks

- Add the shared `checkstyle.xml` (repo root) encoding the mechanical rules.
- Apply Spotless (palantir-java-format) + Checkstyle to every service `build.gradle`.
- Run the one-time `spotlessApply` normalization commit.
- Wire `spotlessCheck` + `checkstyleMain` into CI.
- Flip to `COMPLETED` and update the register + `SPECS-INDEX.md` when merged
  (`DR-003`, `DR-005`).
