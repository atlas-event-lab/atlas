---
adr_id: ADR-0006
title: Adopt code-first API contracts (OpenAPI generated from code)
service: Cross-cutting
status: COMPLETED
date: 2026-07-02
depends_on:
  - SPEC-PROJECT-001
  - SPEC-CONSTRAINTS-001
---

# ADR-0006 — Code-first: the service code is authoritative; OpenAPI is generated

# Status

`PENDING` (created 2026-07-02). Cross-cutting methodology change. Recorded once (not one
ADR per service, `DR-002`) because it alters the SDD process itself, not any single
service's behavior; per-service effect is the mechanical regeneration of each contract.

# Context

The original SDD stance is **spec-first**: the hand-written specification is the source of
truth and code must follow it (`CLAUDE.md` → *Source of Truth Priority*; `constraints.md`
API rules, notably *"every REST endpoint originates from an OpenAPI contract; never invent
endpoints"*). In practice the static contracts under `docs/contracts/openapi/*.yaml` and
the running controllers **drifted**:

- `HotelController` was mapped to `/admin/api/v1/hotels` while `hotel.yaml` (and the
  nginx/Ingress routing) modelled `/api/v1/hotels` — the endpoint was unreachable and the
  hand-written contract no longer described the real surface. `flight` had the same case.
- The services already run **springdoc**, which emits an accurate OpenAPI document from the
  actual controllers + DTOs + validation annotations at `/v3/api-docs` (roadmap §1.1).

Maintaining a second, hand-written source of truth in parallel with the code guarantees
recurring drift and double edits. The team has decided the **code is what ships**, so the
code should be authoritative and the contract should be **derived from it**.

# Decision

1. **The service code is the source of truth for the API surface.** Spring controllers,
   DTOs, and validation/annotation metadata define the real contract.
2. **The OpenAPI contract is a generated artifact**, produced by springdoc
   (`/v3/api-docs`) from the running code. The files under `docs/contracts/openapi/*.yaml`
   become **generated, verified outputs** — not hand-maintained inputs.
3. **Contract review moves into code review.** A new or changed endpoint is designed and
   reviewed in the controller/DTO PR; the regenerated contract is the checkable output of
   that change. This replaces "author the contract first, then implement it".
4. **CI publishes and diffs the generated contract** so the committed `*.yaml` never drifts
   from code: a job starts the app (or uses the springdoc Gradle plugin), exports
   `/v3/api-docs`, and fails the build if the committed contract differs from the generated
   one (regenerate-and-commit, not hand-edit).

(Alternative considered: keep spec-first and add a CI check that code matches the
hand-written contract. Rejected — it keeps two sources of truth and the heavier authoring
burden, without removing the drift class we actually hit.)

# Consequences

**Positive.** One source of truth (the code that ships); drift between contract and reality
is eliminated by construction; less double-authoring; the contract is always executable and
current; routing (nginx/Ingress by `/api/v1/...` prefix) can be validated against a
generated, real surface.

**Negative / trade-offs.** Loses the up-front design discipline of writing the contract
before code — API design now depends on reviewers catching shape issues in the controller
PR. The rule *"never invent endpoints"* loosens in letter, so governance must ensure new
endpoints still get deliberate design review (in code review) rather than appearing ad hoc.
Consumer-driven expectations must rely on the generated contract + CI diff, not a frozen
hand-written file. AsyncAPI (Kafka) is **out of scope** here — events remain spec-first
until a separate decision revisits them.

# Documents to update at implementation

- `CLAUDE.md` — rework *Source of Truth Priority* and *Development Workflow*: the OpenAPI
  contract is generated from code, not read as the authoritative input before implementing.
  Keep Feature/Domain/Service specs as the **behavioral** source of truth; the change is
  specifically about the **API shape** (endpoints/DTOs), which is now code-owned.
- `docs/constraints.md` — amend the API rule(s) that state every endpoint originates from an
  OpenAPI contract and that DTOs/endpoints are never invented outside it; reword to
  "the API surface is code-first; the OpenAPI contract is generated and CI-verified".
  Preserve the intent (no undesigned endpoints) via the code-review gate.
- `docs/deployment/deployment-roadmap.md` §1.1 — note that the static contracts are now the
  **generated** representation (reconciles the existing "worth reconciling per SDD" caveat).
- Add the CI generation/diff job (springdoc export → compare with committed `*.yaml`).

# Implementation tasks

- Wire the springdoc OpenAPI export in each service build (Gradle plugin or a boot-and-dump
  step) and a CI check that fails on drift between generated and committed contract.
- Regenerate `docs/contracts/openapi/*.yaml` from the current code and commit them as
  generated outputs (header comment marking them generated — do not hand-edit).
- Apply the `CLAUDE.md` / `constraints.md` / roadmap wording changes above.
- Flip this ADR to `COMPLETED` and update the register + `SPECS-INDEX.md` (`DR-003`,
  `DR-005`) once the above are merged.
