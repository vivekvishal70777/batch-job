# Architecture — Salesforce Customer 360 Hub

## Context

**System of record for sales relationship:** Salesforce Account + Contact.  
**System of record for billing identity:** ERP customer id.  
**System of interaction:** this MuleSoft hub.

## API-led split (MCIA decision)

| Layer | API | Why this layer |
|---|---|---|
| Experience | `customer-experience-api` | Portal needs a slim JSON contract, pagination, and no Salesforce field names. A second Experience API (e.g. ERP UI) can reuse Process without change. |
| Process | `customer-process-api` | Owns canonical customer, orchestration, idempotency, 360 merge, CDC, bulk. This is the only layer allowed to call more than one System API. |
| System | `sfdc-system-api` | Encapsulates Salesforce auth, Composite, SOQL, Bulk, error mapping. Process never sees `SObject` XML/JSON. |
| System | `erp-system-api` | Encapsulates ERP customer master. Swap mock for SAP/S/4 or NetSuite later. |

**What we did not put in Experience:** Salesforce Composite calls, token handling, bulk jobs. That would couple the portal to CRM and break reuse.

**What we did not put in System:** “create customer in CRM and ERP.” That is process orchestration.

## Canonical model

```json
{
  "customerId": "CUST-8F2A",
  "externalIds": {
    "salesforceAccountId": "001xx000003DHP0",
    "salesforceContactId": "003xx000004TMI9",
    "erpCustomerId": "ERP-10042"
  },
  "account": {
    "name": "Northwind Manufacturing",
    "type": "Customer",
    "industry": "Manufacturing",
    "billing": { "city": "Austin", "state": "TX", "country": "US", "postalCode": "78701" }
  },
  "primaryContact": {
    "firstName": "Ana",
    "lastName": "Diaz",
    "email": "ana.diaz@northwind.example",
    "phone": "+1-512-555-0142"
  },
  "status": "ACTIVE",
  "sourceSystem": "SALESFORCE"
}
```

Process API is the only writer of `customerId`. Salesforce and ERP ids live under `externalIds`.

## Runtime topology (CloudHub 2.0)

- Four apps in one **Private Space**, shared VPC to Salesforce (allowlisted login + instance) and ERP.
- Experience API: 2 replicas, 0.2 vCore, autoscaling on CPU.
- Process API: 2 replicas (idempotency store is persistent Object Store / Redis in prod).
- System APIs: 1–2 replicas; Salesforce System API sized for Bulk concurrency limits.
- Ingress: HTTPS only; Experience is the only public API. Process and System are **internal**.

See `DEPLOYMENT-CLOUDHUB2.md` for CH 2.0 vs RTF.

## Sequence — create customer (happy path)

1. Experience receives `POST /customers` + `Idempotency-Key`.
2. Process checks Object Store; duplicate key returns stored response (200) without calling Salesforce.
3. Process calls SFDC System `POST /composite/account-contact` (until-successful, 3 attempts, 2s backoff).
4. Process calls ERP System `POST /customers` with Salesforce ids.
5. Process stores mapping `customerId ↔ sfdc ↔ erp` and returns 201.

Compensation: if ERP fails after Salesforce succeeds, Process records `CUSTOM:PARTIAL_COMMIT`, raises a case-style alert payload, and retries ERP asynchronously (not two-phase commit — Salesforce is not an XA resource).

## Sequence — 360 GET

Scatter-gather:

- SFDC System: Account + Contact + open Cases
- ERP System: credit status + erpCustomerId

Merge in DataWeave. If Salesforce 404 and ERP hit → 404 only if both miss; otherwise partial resource with `warnings[]`.

## Sequence — CDC

Salesforce (or mock) POSTs Change Event to Process `/events/salesforce-cdc`.

- `replayId` stored in Object Store (dedupe).
- Account change → patch ERP.
- Contact change → patch Salesforce Contact mapping only if email changed (avoid loops).
- Loop prevention: `sourceSystem` header; Process ignores events it just wrote (`origin=MULE`).

## Sequence — nightly Bulk

Scheduler (prod) or `POST /customers/sync/bulk` (ops).

1. ERP System exports changed customers since watermark (Object Store).
2. SFDC System opens Bulk 2.0 ingest job, uploads CSV, closes job.
3. Poll job status (until-successful).
4. Persist watermark only on `JobComplete`.

## Error model

All APIs return:

```json
{
  "correlationId": "c0a8-...",
  "apiName": "customer-process-api",
  "errorCode": "PRC-SFDC-TIMEOUT",
  "httpStatus": 504,
  "message": "Salesforce Account upsert timed out after retries",
  "timestamp": "2026-08-12T17:00:00Z"
}
```

| HTTP | When |
|---|---|
| 400 | Schema / RAML violation |
| 404 | Account not found in Salesforce and ERP |
| 409 | Idempotency key reuse with different body |
| 422 | Salesforce FIELD_CUSTOM_VALIDATION |
| 429 | Mapped from Salesforce `REQUEST_LIMIT_EXCEEDED` |
| 502 | Downstream malformed |
| 504 | Exhausted until-successful |

## Non-functional

| Concern | Choice |
|---|---|
| Idempotency | `Idempotency-Key` header, 24h TTL Object Store |
| Correlation | `X-Correlation-Id` generated if absent; logged on every hop |
| Salesforce limits | Token cache; Bulk for >200 records; no chatty GET-in-loop |
| Streaming | Bulk CSV streamed; 360 GET is small and in-memory |
| Secrets | Secure properties / CH 2.0 secrets; Connected App JWT in prod |
| Observability | JSON logs with correlationId, sfdcLimitRemaining (from `Sforce-Limit-Info`) |
