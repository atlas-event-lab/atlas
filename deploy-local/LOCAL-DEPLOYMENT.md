# Atlas — Local deployment (Docker Compose)

Run the complete Atlas platform locally with Docker Compose and execute a booking end to end.

This environment is useful for exploring the APIs, Kafka events, Saga flow, authentication, and service
interactions. It does not replace the Kubernetes environment: the scalability, resilience, and
load experiments only run on Kubernetes. See [`DEPLOYMENT-RUNBOOK.md`](../DEPLOYMENT-RUNBOOK.md).

> Run the commands below from the deploy-local/ directory unless stated otherwise.

## Prerequisites

- Docker + Docker Compose
- ~6 GB free RAM (Kafka + Postgres + Keycloak + 8 services + the fake provider)
- `curl` and `jq` for the walkthrough
- uuidgen (available by default on macOS; on Linux, use any UUID generator)

## 1. Start the stack

```bash
git clone https://github.com/atlas-event-lab/atlas.git
cd atlas/deploy-local

docker compose up -d
docker compose ps        # wait until services are healthy
```

The stack includes:

- PostgreSQL with one database per service
- Kafka in KRaft mode
- Keycloak
- Redis
- WireMock as the fake payment provider
- NGINX as the API Gateway
- the eight Atlas services

The public entry points are:

- API Gateway   http://localhost:8080
- Keycloak      http://localhost:8180
- PostgreSQL    localhost:5432
- Kafka         localhost:9092
- Redis         localhost:6379

The application services are exposed through the NGINX API Gateway on:
http://localhost:8080

#### Keycloak is fully configured automatically 
No manual Keycloak configuration is required.
On startup, Keycloak automatically imports: **deploy-local/keycloak/atlas-realm.json**
The imported realm contains:

```yaml
Realm: 
  atlas 

Realm role: 
  ADMIN 

Users: 
  atlas-user 
    role: none 
     
  atlas-admin 
    role: ADMIN 
Clients: 
  atlas-web 
  atlas-loadtest
```

Default local passwords are controlled by environment variables:

**ATLAS_USER_PASSWORD**
**ATLAS_ADMIN_PASSWORD**

The Compose defaults are:

**atlas-user  / atlas-user**
**atlas-admin / atlas-admin**

You can override them without modifying the realm file:

```bash
ATLAS_USER_PASSWORD='user-secret' \
ATLAS_ADMIN_PASSWORD='admin-secret' \
docker compose up -d
```

The Keycloak administrator account (admin) is only for the Keycloak master realm and is not required
for the Atlas application walkthrough.

The local realm is intended for development only. Do not reuse these credentials in a shared or
production environment.

## 2. Get a token

```bash
TOKEN=$(curl -s http://localhost:8180/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=atlas-web \
  -d username='atlas-user' \
  -d password='${ATLAS_USER_PASSWORD:-atlas-user}' | jq -r .access_token)
```
For endpoints protected by the ADMIN role, use atlas-admin:
```bash
ADMIN_TOKEN=$(curl -s http://localhost:8180/realms/atlas/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=atlas-web \
  -d username=atlas-admin \
  -d password="${ATLAS_ADMIN_PASSWORD:-atlas-admin}" \
  | jq -r .access_token)
```
atlas-user intentionally has no roles. Most application endpoints only require authentication.
Administrative catalog operations require the ADMIN realm role.

## 3. Browse the catalog

```bash
curl -s http://localhost:8080/api/v1/flights -H "Authorization: Bearer $TOKEN" | jq
curl -s http://localhost:8080/api/v1/hotels  -H "Authorization: Bearer $TOKEN" | jq
```

## 4. Reconcile the catalog
Catalog reconciliation is protected by the **ADMIN** role, so use **ADMIN_TOKEN**:
```bash
curl -s -X POST \ http://localhost:8080/api/v1/flights/reconciliation \ -H "Authorization: Bearer $ADMIN_TOKEN" | jq
```
This publishes the catalog data consumed by Inventory and Search.

Check the service logs if you want to follow the event flow:

docker compose logs -f inventory-service
docker compose logs -f search-service

## 5. Create a booking (kicks off the saga)

The booking starts the Saga flow.

First, choose a resourceId from an available flight returned by the catalog endpoint in step 3.

```bash
curl -s -X POST http://localhost:8080/api/v1/bookings \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H 'Content-Type: application/json' \
  -d '{
        "travelers": [
            {
                "firstName": "John",
                "lastName": "Doe",
                "dateOfBirth": "1977-06-13",
                "nationality": "US",
                "documentType": "DNI",
                "documentNumber": "1111111",
                "email": "example@mail.com",
                "phoneNumber": "999999999"
            }
        ],
        "items": [
          {
            "type": "FLIGHT",
            "unitPrice": {
                        "amount": 991.80,
                        "currency": "USD"
                    },
            "quantity": 4,
            "resourceId": "f5672fd8-2bcd-43ac-b2b3-72aa405a016a"
          }
        ],  
        "total": {
            "amount": 3967.20,
            "currency": "USD"
        }
      }' | jq
```

## 6. Watch it confirm

Query the booking repeatedly:

```bash
BID=<bookingId-from-step-5>
url -s http://localhost:8080/api/v1/bookings/$BID \
  -H 'Authorization: Bearer $TOKEN' | jq .status
```
A successful flow should progress through states such as:

```bash
PENDING -> INVENTORY_RESERVED -> CONFIRMED
```

You can observe the participating services while the Saga executes:

```bash
docker compose logs -f booking-service
docker compose logs -f inventory-service
docker compose logs -f payment-service
```

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
