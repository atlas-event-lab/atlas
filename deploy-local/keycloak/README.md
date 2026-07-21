# Keycloak realm for the local stack

Your Atlas realm — clients, roles, users — is **yours** (SDD: don't invent identity here).
The local `docker compose` stack imports whatever realm JSON you drop in this folder.

## What to do

Export your `atlas` realm and save it here as `realm-atlas.json`:

```bash
# from a running Keycloak that has your realm
/opt/keycloak/bin/kc.sh export --realm atlas --file realm-atlas.json --users realm_file
# then copy realm-atlas.json into deploy-local/keycloak/
```

The compose mounts this folder at `/opt/keycloak/data/import` and Keycloak starts with
`--import-realm`, so the realm is created on first boot.

## What the realm must contain for the QUICKSTART

- realm name **`atlas`** (the services validate `iss = .../realms/atlas`).
- a client the QUICKSTART can use with **Direct Access Grants** (password grant) enabled —
  e.g. a public `atlas-web` client, or a confidential `atlas-loadtest` client + secret.
- at least one **test user** with a known password.

## Issuer note

The stack addresses Keycloak as `http://host.docker.internal:8180` from both the host and
the containers, so a token you obtain from the host validates inside the services (the `iss`
claim matches). If you export a realm that pins a different frontend URL, clear it (leave the
realm's `frontendUrl` empty) so the hostname settings in `docker-compose.yml` apply.

> Never commit a realm export that contains real user credentials or client secrets. Use
> test-only accounts. Add `realm-atlas.json` to `.gitignore` if it holds secrets.
