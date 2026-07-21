# Contributing to Atlas

Thanks for your interest! Atlas is a **learning laboratory** for distributed systems, so
contributions, questions and experiment ideas are all welcome — the goal is understanding,
not shipping a product.

## Ways to contribute

- **Questions & discussion** — open an issue; "how does the saga handle X?" is a valid issue.
- **Experiment proposals** — new resilience/scalability scenarios (see the experiment issue
  template).
- **Bug reports** — something doesn't behave as the diagrams/specs say.
- **Docs & diagrams** — clarity fixes, corrections where docs drift from code.
- **Code** — fixes and features on a specific service.

## Ground rules (from the project's design principles)

Atlas follows a few non-negotiable architectural rules. PRs that violate them won't be
merged:

- Microservices with a **database per service** — no cross-service DB access, joins, foreign
  keys, or shared entities.
- **No distributed transactions / 2PC** — distributed consistency uses the Saga pattern.
- **Events are immutable, past-tense facts**; prefer events over synchronous REST.
- Extract `UserId` from the JWT — never trust client-supplied identifiers.
- **Never commit secrets** (kubeconfigs, passwords, tokens) or environment-specific hosts.
- Constructor injection only; controllers hold no business logic.

## Multi-repo layout

Each service is its own repository. Open PRs against the repo you're changing. A change that
spans services is split per service and cross-linked (one Decision Record per affected
service).

## Workflow

1. Fork / branch from `main`.
2. Keep the change scoped to one service/concern.
3. Run the build locally: `./gradlew build` (formatting via Spotless and style via Checkstyle
   run in the build and in CI).
4. Add/adjust tests. Keep the behavior consistent with the service's diagrams and contracts.
5. Open a PR using the template; describe the behavior change and link any related issue/ADR.

## Commit & PR style

- Small, focused commits with clear messages.
- The PR description should explain **what changed and why**, not just how.

By contributing you agree your contributions are licensed under the project's Apache-2.0
license.
