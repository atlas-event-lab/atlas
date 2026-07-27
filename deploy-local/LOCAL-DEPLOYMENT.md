# Atlas — Local deployment (Docker Compose)

Bring up the whole platform **on your machine** and run a booking end to end — handy for
poking the API by hand. It does **not** replace a real cluster: the load, scalability and
resilience **experiments only run on Kubernetes** — for that, see
[`DEPLOYMENT-RUNBOOK.md`](../DEPLOYMENT-RUNBOOK.md).

> Run the commands below **from the repo root** (the `atlas/` folder).

## Prerequisites

- Docker + Docker Compose
- ~6 GB free RAM (Kafka + Postgres + Keycloak + 8 services + the fake provider)
- `curl` and `jq` for the walkthrough
- **Your Keycloak realm export** at `deploy-local/keycloak/realm-atlas.json` (identity is
  yours — see [`keycloak/README.md`](./keycloak/README.md)). The
  realm must be named `atlas`, have a Direct-Access-Grants client, and a test user.

## 1. Start the stack

```bash
git clone https://github.com/atlas-event-lab/atlas.git
cd atlas
# drop your realm export in deploy-local/keycloak/realm-atlas.json first
DB_PASSWORD=atlas docker compose up -d
docker compose ps        # wait until services are healthy
```

What comes up: one PostgreSQL (a database per service), Kafka (KRaft), Keycloak on
`:8180`, Redis, the fake payment provider (WireMock), and the eight services behind the
nginx **API Gateway on `http://localhost:8080`**. Service schemas are created by Flyway on
first boot.

> The published `docker-compose.yml` pulls prebuilt images from GHCR
> (`ghcr.io/atlas-event-lab/atlas-*`). To build from source instead, use the workspace
> compose (which has `build:` contexts for each service).
>
> First boot takes a few minutes while Keycloak imports the realm and services run
> migrations. `docker compose logs -f <service>` to watch.

## 2. Get a token

Atlas uses Keycloak-issued JWTs. Keycloak is reached at `host.docker.internal:8180` (the
issuer the services validate), which your host resolves too. Request a token for a realm
test user:

```bash
TOKEN=$(curl -s http://host.docker.internal:8180/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=atlas-web \
  -d username='<test-user>' \
  -d password='<test-password>' | jq -r .access_token)
```

> Use the client and test user from your realm export. On Docker Desktop
> `host.docker.internal` resolves out of the box; on Linux Compose maps it via
> `extra_hosts`. Don't commit real credentials.

## 3. Browse the catalog

```bash
curl -s http://localhost:8080/api/v1/search/flights -H "Authorization: Bearer $TOKEN" | jq
curl -s http://localhost:8080/api/v1/search/hotels  -H "Authorization: Bearer $TOKEN" | jq
```

## 4. Create a booking (kicks off the saga)

```bash
curl -s -X POST http://localhost:8080/api/v1/bookings \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  -d '{
        "flight": { "flightId": "<id>" },
        "hotel":  { "roomTypeId": "<id>", "checkIn": "2026-09-01", "checkOut": "2026-09-04" },
        "currency": "USD",
        "total": { "amount": 850.00, "currency": "USD" }
      }' | jq
```

The booking returns `PENDING`. Behind the scenes: Inventory reserves capacity →
`inventory.reserved` (with the amount) → Payment charges the fake provider →
`payment.succeeded` → Booking becomes `CONFIRMED`.

## 5. Watch it confirm

```bash
BID=<bookingId-from-step-4>
watch -n1 "curl -s http://localhost:8080/api/v1/bookings/$BID \
  -H 'Authorization: Bearer $TOKEN' | jq .status"
# PENDING → INVENTORY_RESERVED → CONFIRMED
```

## 6. Try the failure paths (optional)

The fake payment provider (WireMock) can simulate `SUCCESS`, `DECLINED`, `TIMEOUT` and
`DUPLICATE` based on the request. Point a booking at a declining/timeout amount or mapping to
watch the saga compensate: the booking goes `FAILED`/`EXPIRED` and Inventory releases the
held capacity (`inventory.released`). See the
[resilience experiments](https://github.com/atlas-event-lab/atlas) for scripted scenarios.

## Observability (optional)

If you enabled the observability profile, open Grafana at `http://localhost:3000` to see the
RED, Kafka and per-service dashboards, with traces threaded by `traceId` across the saga.

## Tear down

```bash
docker compose down          # keep volumes
docker compose down -v       # also drop all data
```

## Troubleshooting

- **401 Unauthorized** — token expired or wrong realm/client; re-run step 2.
- **Booking stuck at PENDING** — check `docker compose logs inventory-service`; capacity may
  be exhausted (`inventory.rejected` → booking `FAILED`).
- **Booking stuck at INVENTORY_RESERVED** — check `payment-service` and `wiremock` logs; the
  recovery sweeper re-drives stale payments within its interval.
