<!-- Thanks for contributing to Atlas! Keep PRs scoped to one service/concern. -->

## What & why

<!-- What behavior changes and why. Link the issue/ADR this relates to. -->

Closes #

## Type of change

- [ ] Bug fix
- [ ] Feature
- [ ] Docs / diagrams
- [ ] Experiment
- [ ] Refactor / chore

## Checklist

- [ ] Scoped to a single service/concern (multi-service changes are split per repo).
- [ ] Consistent with the service's diagrams/contracts (no invented endpoints or events).
- [ ] Respects the non-negotiables: database-per-service, no 2PC/saga only, events are
      immutable past-tense facts, `UserId` from JWT.
- [ ] `./gradlew build` passes (Spotless + Checkstyle + tests).
- [ ] No secrets, kubeconfigs, or environment-specific hosts committed.
- [ ] Tests added/updated.

## Notes for reviewers

<!-- Anything worth calling out: trade-offs, follow-ups, risks. -->
