# Atlas — System Diagrams

Visual documentation of how Atlas works. These diagrams are
**informative** — the authoritative behavior lives in each service and its contracts. They
are rendered directly by GitHub (Mermaid).

> **Implementation status (keep current).** Eight services are implemented and event-wired:
> User, Flight, Hotel, Inventory, Travel Cart, Booking, Payment, Search. The API Gateway is
> configuration-only (routing/auth). Notification is planned. The diagrams show the target
> system; planned pieces are marked.

## Index

1. [System context](#1-system-context) · this page
2. [Microservices architecture](#2-microservices-architecture) · this page
3. [Booking saga — create, confirm, compensate](./booking-saga.md)
4. [Inventory — availability model & reservation lifecycle](./inventory.md)
5. [Payment — lifecycle, idempotency, recovery](./payment.md)
6. [Search — CQRS read models](./search-cqrs.md)
7. [Kafka topics & event map](./events-and-topics.md)

---

## 1. System context

Who uses Atlas and which infrastructure it talks to. The **API Gateway** is the single
entry point; **Keycloak** issues the JWTs every service validates.

```mermaid
flowchart TB
    traveler([Traveler])
    admin([Catalog Admin])

    subgraph atlas[Atlas Platform]
        gw[API Gateway]
        services[8 domain services]
        kafka{{Apache Kafka}}
        stores[(PostgreSQL · one DB per service)]
    end

    kc[(Keycloak<br/>OIDC / JWT)]
    psp[[Fake Payment Provider<br/>WireMock]]
    obs[[Observability<br/>Prometheus · Loki · Tempo · Grafana]]

    traveler -->|search, book, pay| gw
    admin -->|manage flights / hotels| gw
    gw -->|forward Authorization| services
    services -.->|validate JWT| kc
    services <--> kafka
    services --> stores
    services -->|charge| psp
    services -.->|metrics · logs · traces| obs
```

---

## 2. Microservices architecture

Each service owns its database and communicates through Kafka events; synchronous REST is
used only for queries and commands that need an immediate response. No service reads another
service's database.

```mermaid
flowchart LR
    client([Client])
    gw[API Gateway]
    kc[(Keycloak)]

    client --> gw
    booking -.->|each service validates JWT| kc

    subgraph write[Write side]
        user[User]
        cart[Travel Cart]
        booking[Booking]
        inventory[Inventory]
        payment[Payment]
    end
    subgraph catalog[Catalog]
        flight[Flight]
        hotel[Hotel]
    end
    subgraph read[Read side · CQRS]
        search[Search]
    end

    kafka{{Kafka · domain events}}
    psp[[Fake Payment Provider]]

    gw --> user & cart & booking & flight & hotel & search

    booking -->|booking.*| kafka
    inventory -->|inventory.*| kafka
    payment -->|payment.*| kafka
    flight -->|flight.*| kafka
    hotel -->|hotel.*| kafka

    kafka -->|booking.created| inventory
    kafka -->|inventory.reserved| booking
    kafka -->|inventory.reserved amount| payment
    kafka -->|payment outcome| booking
    kafka -->|catalog + availability events| search
    payment --> psp

    user --> udb[(user-db)]
    flight --> fdb[(flight-db)]
    hotel --> hdb[(hotel-db)]
    inventory --> idb[(inventory-db)]
    cart --> cdb[(cart-db)]
    booking --> bdb[(booking-db)]
    payment --> pdb[(payment-db)]
    search --> sdb[(search-db)]
```

### Per-service internals (representative: Booking)

Every service follows the same layering: a thin REST controller, an application/domain
layer holding the business rules, a Kafka consumer for inbound saga events, and a
**transactional outbox** so state changes and event publication commit atomically.

```mermaid
flowchart TB
    rest[REST Controller<br/>no business logic] --> app[Application / Domain<br/>state machine · rules]
    consumer[Kafka Consumer<br/>idempotent] --> app
    app --> repo[(Service DB)]
    app --> outbox[(Outbox table)]
    relay[Outbox Relay] --> repo
    relay --> kafka{{Kafka}}
    outbox -.polled by.-> relay
```

The outbox relay reads committed rows and publishes to Kafka at-least-once; consumers
deduplicate on the envelope `eventId`, which makes the whole chain idempotent.
