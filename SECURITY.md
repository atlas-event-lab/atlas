# Security Policy

Atlas is a learning laboratory, not a production service — but it demonstrates security
practices, so responsible reporting is appreciated.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Instead, report it privately
via GitHub's *"Report a vulnerability"* (Security → Advisories) on the affected repository, or
by email to the maintainer listed on the organization profile.

Include: the repo, a description, reproduction steps, and the potential impact. You can expect
an acknowledgement within a few days.

## Scope & expectations

- Atlas is intended to run on trial/lab infrastructure. Do not test against any deployment you
  do not own.
- No bug-bounty rewards are offered.

## Secrets hygiene

This project treats committed secrets as security issues. If you find a credential, private
key, kubeconfig, or environment-specific host committed to any repo or its history, please
report it privately. Maintainers rotate the credential and purge it from history.
Secret scanning (e.g. gitleaks) runs in CI to prevent regressions.
