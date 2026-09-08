# Salesforce Customer 360 Hub (Mule 4)

Production-shaped **API-led** integration for a Senior / Tech Lead profile (MCD L1, L2, MCIA).

The hub is the system of interaction between **Salesforce Sales Cloud** (accounts, contacts, cases) and an **ERP customer master**. It covers real-time upsert, CDC-style events, nightly Bulk reconcile, OAuth token cache, idempotency, and CloudHub 2.0 deployment notes.

## Business problem

A mid-market manufacturer runs CRM in Salesforce and billing in ERP. Sales creates or updates accounts in Salesforce; finance owns the ERP customer id. Duplicate accounts, lost case context, and a nightly CSV dump were breaking quote-to-cash.

This solution:

1. Exposes a stable **Experience API** for portal / BFF consumers (not Salesforce shapes).
2. Orchestrates **Process APIs** for create/update, 360-read, case open, CDC, and bulk reconcile.
3. Isolates Salesforce and ERP behind **System APIs** so connector or org changes do not leak upward.

## Applications

| App | Layer | Port | Responsibility |
|---|---|---|---|
| `customer-experience-api` | Experience | 8081 | Portal/mobile contract, field filtering, OAuth-ready facade |
| `customer-process-api` | Process | 8082 | Canonical customer, scatter-gather 360, idempotent upsert, CDC, bulk |
| `sfdc-system-api` | System | 8083 | Salesforce REST/Composite/SOQL/Bulk 2.0 (live or mock) |
| `erp-system-api` | System | 8084 | ERP customer master (in-memory store for local runs) |

## Architecture (API-led)

```
Portal / Mobile / BFF
        |  OAuth 2.0 + Client ID (API Manager)
        v
Experience API  (customer-experience-api)
        |
        v
Process API     (customer-process-api)
        |-------------------------------|
        v                               v
SFDC System API                  ERP System API
(REST, Composite, Bulk, CDC)     (customer master)
        |
        v
Salesforce org  OR  embedded mock (salesforce.mode=mock)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for HLD, sequence diagrams, failure modes, and pattern decisions.

## Salesforce patterns demonstrated

| Pattern | Where |
|---|---|
| REST CRUD + SOQL | `sfdc-system-api` accounts/contacts/cases |
| Composite (Account + Contact in one call) | `POST /composite/account-contact` |
| Bulk 2.0 ingest (nightly) | Process `POST /customers/sync/bulk` → System bulk job |
| CDC / Platform Event style webhook | Process `POST /events/salesforce-cdc` |
| OAuth token cache (Object Store) | `sfdc-client.xml` |
| Idempotency (Idempotency-Key) | Process upsert + Object Store |
| Scatter-gather 360 read | Process GET customer |
| Until-successful + DLQ-style error | Process Salesforce writes |
| Canonical DataWeave model | `dwl/` in process API |

Production orgs would swap the HTTP Salesforce client for **Anypoint Salesforce Connector** (Replay CDC, Bulk job status, Platform Events) without changing Experience or Process contracts.

## Local run (mock Salesforce)

1. Import each module into Anypoint Studio 7.x (Mule 4.9 / Java 17) **or** deploy the four apps to a local runtime.
2. Start in order: `erp-system-api` → `sfdc-system-api` → `customer-process-api` → `customer-experience-api`.
3. Default `salesforce.mode` is `mock`. No Salesforce org required.
4. Import [postman/Customer-360.postman_collection.json](postman/Customer-360.postman_collection.json).
5. `POST http://localhost:8081/api/v1/customers` with header `Idempotency-Key: demo-001`.

To point at a real org, set `salesforce.mode=live` and inject Connected App credentials via CloudHub 2.0 secure properties (never commit secrets).

## CI/CD

GitHub Actions runs `mvn -pl salesforce-customer-hub -am test` when the Mule Maven plugin and Exchange are available. Pipeline design (Connected App, CH 2.0, MUnit gates) is in [docs/DEPLOYMENT-CLOUDHUB2.md](docs/DEPLOYMENT-CLOUDHUB2.md).

## Resume bullets (use as-is)

- Designed API-led Customer 360 (Experience / Process / System) between Salesforce Sales Cloud and ERP; canonical DataWeave 2.0 model; Composite upsert for Account+Contact.
- Implemented Salesforce REST, Bulk 2.0 nightly reconcile, and CDC webhook handling with Object Store idempotency and until-successful retries.
- Defined API Manager policies (OAuth 2.0, Client ID, spike control), correlation IDs, and CloudHub 2.0 topology with env-specific secure properties and MUnit coverage.

## Interview pack

Walk through [docs/INTERVIEW-NARRATIVE.md](docs/INTERVIEW-NARRATIVE.md) in 20 minutes: design, failure, performance, security, leadership.
