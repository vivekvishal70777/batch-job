# MuleSoft system design applications

One Mule 4.9 application per interview design (Questions 1–8).  
Salesforce, SAP, WMS, PSP, SMTP, and SFTP are **HTTP mocks** so the apps import in Studio without those systems.

Runtime: Mule **4.9**, Java **17**. Object Store + VM queues stand in for SQL / Anypoint MQ.

| App | Port | Design | What it implements |
|-----|------|--------|--------------------|
| `q1-inventory-ingestion` | 8081 | High-volume file ingest | `202` job kickoff, POS deltas, LWW upsert, rejects, analytics outbox, email digest |
| `q2-customer-360` | 8082 | Customer 360 read path | GET from cache; projector scatter-gather; loyalty timeout; GDPR erase |
| `q3-order-saga` | 8083 | Place order saga | Idempotency-Key, approval &gt; $50k, WMS ledger, PSP token, SF outbox, compensate |
| `q4-partner-b2b` | 8084 | Partner REST/CSV/EDI | Per-partner adapters, canonical order, EDI quarantine |
| `q5-notification-hub` | 8085 | Notification hub | Dedup, route email/SMS/chat, notify failure does not fail caller |
| `q6-hybrid-sap-extract` | 8086 | Hybrid SAP extract | Document-number watermark, page checkpoint, mock SAP |
| `q7-fault-tolerant-patterns` | 8087 | Fault tolerance | Idempotent work, retry, circuit breaker, DLQ |
| `q8-enterprise-platform-template` | 8088 | CoE / platform | client_id, standard errors, catalog, `/live` `/ready` |

Each app also exposes:

- `GET /live`
- `GET /ready`

## Import

Anypoint Studio: **File → Import → Anypoint Studio project from File System** (or open the `pom.xml` as a Mule Maven project).

```bash
cd system-design-apps/q1-inventory-ingestion
mvn clean package -DskipTests
```

## Try it (after the app is running)

**Q1 ingest**

```bash
curl -s -X POST http://localhost:8081/api/v1/ingestion/jobs \
  -H 'Content-Type: application/json' \
  -d '{"path":"classpath://inbox/inventory-sample.csv","source":"NIGHTLY"}'

curl -s http://localhost:8081/api/v1/ingestion/jobs/{jobId}
curl -s 'http://localhost:8081/api/v1/inventory/SKU-100?storeId=STORE-01'

curl -s -X POST http://localhost:8081/api/v1/pos/deltas \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: pos-1' \
  -d '{"sku":"SKU-100","storeId":"STORE-01","qty":9,"eventTs":"2026-09-08T12:00:00Z"}'
```

**Q2 customer 360**

```bash
curl -s -X POST http://localhost:8082/api/v1/internal/project/c-1
curl -s http://localhost:8082/api/v1/customers/c-1
curl -s -X POST http://localhost:8082/api/v1/customers/c-1/erase
```

**Q3 order saga**

```bash
curl -s -X POST http://localhost:8083/api/v1/orders \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: k1' \
  -d '{"amount":1200,"paymentToken":"tok_123","lines":[{"sku":"SKU-100","qty":1}]}'

curl -s -X POST http://localhost:8083/api/v1/orders \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: k2' \
  -d '{"amount":60000,"paymentToken":"tok_123","lines":[]}'
# then POST /api/v1/orders/{id}/approve
```

**Q4 B2B**

```bash
curl -s -X POST http://localhost:8084/api/v1/partners/acme/orders \
  -H 'Content-Type: application/json' \
  -d '{"poNumber":"PO-1","lines":[{"sku":"SKU-1","qty":2}]}'

curl -s -X POST http://localhost:8084/api/v1/partners/acme/edi \
  -H 'Content-Type: text/plain' \
  --data 'ISA*00* ST*850*PO-9'
```

**Q5 notifications**

```bash
curl -s -X POST http://localhost:8085/api/v1/notifications \
  -H 'Content-Type: application/json' \
  -d '{"channel":"email","to":"ops@example.com","templateId":"job-digest","correlationId":"b-1","data":{}}'
```

**Q6 SAP extract**

```bash
curl -s -X POST http://localhost:8086/api/v1/extracts/run
curl -s http://localhost:8086/api/v1/extracts/watermark
```

**Q7 resilience**

```bash
curl -s -X POST http://localhost:8087/api/v1/work \
  -H 'Content-Type: application/json' \
  -d '{"workId":"w1","fail":false}'
curl -s -X POST http://localhost:8087/api/v1/circuit/close
```

**Q8 platform**

```bash
curl -s http://localhost:8088/api/v1/catalog
curl -s http://localhost:8088/api/v1/demo
curl -s -H 'client_id: demo' http://localhost:8088/api/v1/demo
```

## Mapping to the interview write-up

See `mulesoft-system-design-interview-questions.md`. Q1–Q8 here match Questions 1–8 there.

Durable SQL Server / SFTP / Anypoint MQ from the original `ingestion-batch-pipeline` can replace Object Store and VM in production without changing the Experience contracts.
