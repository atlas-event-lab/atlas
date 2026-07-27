# Atlas — API Gateway

> The single entry point to Atlas. Path-based reverse proxy; **routing only** — it does not
> hold business logic and does not validate JWTs.

Part of **[Atlas](https://github.com/atlas-event-lab)**. Unlike the domain services, the
gateway has **no Java code** — it is plain configuration:

- **Local (docker-compose):** an **nginx** reverse proxy (`nginx/nginx.conf`), listening on
  port 80, routing to each service by container name on its internal port 8080.
- **Kubernetes:** **ingress-nginx** (`atlas-ingress.yaml`) does the same edge routing, fronted
  by the cloud LoadBalancer.

## What it does

- Terminates all external traffic at one place and forwards by URL path prefix.
- **No path rewrite:** services own the `/api/v1` prefix in their controllers, so the full
  path is forwarded as-is.
- **Longest-prefix wins:** `/api/v1/me/bookings` is matched before `/api/v1/me`.
- Forwards the `Authorization` header untouched (`proxy_set_header Authorization`).

## What it does NOT do

- **It does not validate JWTs.** Authentication is enforced **per service**: each service is
  an OAuth2 resource server that validates the Keycloak-issued JWT and extracts `UserId`
  itself. The gateway only carries the token through.
- No rate limiting in the MVP (listed as future in the project spec).

## Routing table

| Path prefix | Target service |
|-------------|----------------|
| `/api/v1/bookings` | booking-service |
| `/api/v1/payments` | payment-service |
| `/api/v1/inventory` | inventory-service |
| `/api/v1/flights` | flight-service |
| `/api/v1/hotels` | hotel-service |
| `/api/v1/search` | search-service |
| `/api/v1/carts` | travel-cart-service |
| `/api/v1/me/` | user-service (profile, preferences, favorites) |
| `/api/v1/me/bookings` | search-service (booking history — see note) |
| `/health` | gateway health check (local nginx only) |

`wiremock` (fake payment provider) and the databases are **not** exposed at the edge —
cluster-internal only.

> **Status note (`/api/v1/me/bookings`).** The route is wired at the edge and the security
> layer references it, but the booking-history read model / endpoint is **not yet
> implemented** in search-service (there is no `BookingProjection` in code). Until it is,
> this path resolves to search-service but has no handler. Track it as a future item.

## Change routes

- Local: edit `nginx/nginx.conf` and restart the gateway container.
- Kubernetes: edit `atlas-ingress.yaml` (in the infra/gitops repo) and re-apply.

Keep both in sync — they encode the same routing contract, which derives from the services'
OpenAPI paths (never invent endpoints here).

## Where this lives

The nginx config ships with the local compose stack (atlas repo); the Ingress manifest ships
with the infra/GitOps repo. The gateway is not a standalone Java service repo.

## License

Apache-2.0 — see [`LICENSE`](../LICENSE).
