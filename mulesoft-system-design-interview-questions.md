# MuleSoft System Design Interview — Questions and Answers

Standard 45–60 minute system design round for **MuleSoft Integration Architect / Senior Integration Engineer**.

Each problem is answered in interview order:

1. Clarify  
2. Requirements  
3. High-level design  
4. APIs and data  
5. Deep dive  
6. Failures and scale  
7. Trade-offs  

Draw while you talk. Name alternatives and why you rejected them.

**Runnable Mule 4 apps** for each question live in [`system-design-apps/`](system-design-apps/README.md) (Q1–Q8). Downstream systems are HTTP mocks; Object Store and VM queues stand in for SQL and Anypoint MQ.

---

## Interview method (use this on every question)

**Clarify (2–3 min)**  
Who calls us? Sync or async? Volume? SLA? Systems of record? Failure budget (lose data vs delay)?

**Requirements (3 min)**  
Write functional and non-functional on the board. Get the interviewer to nod.

**High-level (10 min)**  
Boxes: clients, Experience API, Process API, System APIs, queues, stores, Salesforce/SAP/DB/SFTP. Arrows labeled with protocol.

**Deep dive (20 min)**  
One or two hotspots: idempotency, fan-out, batch memory, Salesforce limits, compensations.

**Wrap (5 min)**  
Top 3 risks, MVP vs later, how you would monitor.

**Bar**

| Level | What it looks like |
|-------|--------------------|
| No | Connector list, happy path only |
| Hire | Layers + async boundary + idempotency + reject path + runtime choice |
| Strong | Control table, backpressure, dual-sink consistency, runbook, vCore budget |

---

# Question 1 — High-volume file ingestion

### Prompt

A retailer drops inventory CSV files on SFTP every night (10k–20M rows). POS also posts small JSON deltas over HTTPS. Downstream: SQL Server (store operations) and Salesforce Data Cloud (analytics). Ops needs success/fail reporting and email. Design the MuleSoft solution.

This is the most common MuleSoft design question (batch + SFTP + DB). It matches typical job ads and this style of production pipeline.

---

### 1. Clarify

Ask:

- File complete signal (`.done` file vs size stable vs ops HTTP start)?  
- Duplicate SKUs across files — last write wins or sum?  
- Must analytics match SQL in the same second?  
- Partial file (writer still uploading)?  
- Replay requirement?  
- PII in the file?

**Assume unless told otherwise:** last-write-wins on `SKU + StoreId` using row timestamp; SQL is operational truth; analytics may lag; HTTP start or scheduler; replay must not double-count.

---

### 2. Requirements

**Functional**

- Ingest CSV from SFTP and POS JSON.  
- Validate rows; persist good and bad separately.  
- Upsert operational inventory.  
- Feed analytics.  
- Job status and one summary email.  
- Safe replay.

**Non-functional**

- 20M rows in a night window (~2 hours).  
- Memory must not load 4 GB as one array.  
- At-least-once processing with **exactly-once effects** (upsert).  
- Availability: two workers, but **single claim** per file.  
- Security: SFTP keys in secrets; no payload in logs.

**Capacity (back of envelope)**

- 20M × 200 bytes ≈ 4 GB file.  
- Aggregator 500 rows × 8 threads ≈ 4k rows in flight, not 20M.  
- Target 10k–30k rows/s into SQL → ~10–30 minutes CPU/DB bound.

---

### 3. High-level design

```
Ops / Scheduler                    POS devices
       |                                |
       v                                v
 POST /ingestion/jobs              POST /pos/deltas
 (Experience: kickoff)             (Experience: small, 202)
       |                                |
       v                                v
  Job control DB                    Anypoint MQ
  (claim file, checksum)                |
       |                                |
       v                                v
 Process: Inventory Ingest ----------------+
       |                                   |
       |  stream CSV / consume MQ          |
       |  validate                         |
       +---> SQL Server upsert (source of truth)
       +---> outbox --> MQ --> Data Cloud loader
       +---> reject table
       +---> on-complete email
```

**API-led**

| Layer | App | Why |
|-------|-----|-----|
| Experience | Kickoff + POS + job status | Auth, partner/store identity, 202 |
| Process | Ingest + validation + fan-out | Business rules, job lifecycle |
| System | SFTP, SQL, Data Cloud, Email | One system each |

**Rejected:** one mega-flow; SFTP listener only (partial files); XA to SQL + Data Cloud.

---

### 4. APIs and data

**Kickoff**

```
POST /ingestion/jobs
Authorization: Bearer
Body: { "path": "/inbox/inv.csv", "source": "NIGHTLY" }
→ 202 { "jobId": "b-9f3", "status": "ACCEPTED" }

GET /ingestion/jobs/{jobId}
→ { "status": "RUNNING|SUCCEEDED|FAILED", "loaded": 19920000, "rejected": 8000 }
```

**POS**

```
POST /pos/deltas
Idempotency-Key: uuid
Body: { "sku", "storeId", "qty", "eventTs" }
→ 202 { "accepted": true }
```

**Tables**

```
ingest_job(job_id PK, path, checksum UNIQUE, status, claimed_by, loaded, rejected, started_at, finished_at)

inventory(sku, store_id, qty, event_ts, source, job_id)
  PRIMARY KEY (sku, store_id)

ingest_reject(job_id, row_num, payload, error_code, error_msg)
```

Upsert rule: update row only if `incoming.event_ts >= inventory.event_ts`.

---

### 5. Deep dive

**File completeness**  
Do not delete or parse while size is growing. Require `.done` or two equal size samples N seconds apart, or only start from `POST /ingestion/jobs`.

**Streaming + batch**  
SFTP read with CSV streaming. Mule batch: validate per record; aggregator bulk-insert; `ONLY_FAILURES` step writes rejects; `maxFailedRecords = -1` so 1% bad does not abort 20M.

**Two sinks**  
SQL commit + **outbox row** in the same SQL transaction (or insert outbox immediately after). Separate worker loads Data Cloud. Analytics SLA hours; store SLA minutes.

**Claim**  
`UPDATE ingest_job SET claimed_by = worker WHERE claimed_by IS NULL`. Two CloudHub workers cannot process the same file.

**Email**  
On-complete digest only. Email errors: on-error-continue; page Slack. Do not fail the job after data is loaded.

---

### 6. Failures and scale

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Truncated SFTP | Size / `.done` | Wait; quarantine; do not archive |
| Worker killed | Job `RUNNING` past timeout | Resume or restart; upsert is safe |
| Replay same file | Unique checksum | Return existing `jobId` unless `force` |
| Data Cloud slow | Queue depth | SQL already correct; scale loader |
| Email down | Send error | Continue; secondary alert |
| Two workers | Claim row | Second worker skips |

**Scale:** more batch workers only after claim works. Tune aggregator 200–1000. HTTP listener returns 202; never holds 20M rows.

---

### 7. Trade-offs

| Choice | Why | Cost |
|--------|-----|------|
| HTTP kickoff vs SFTP listener | Control, auth, no partial read | Ops must start or scheduler polls `.done` |
| Outbox vs dual JDBC | Independent SLAs | Analytics lag |
| `blockSize=1` + aggregator | Per-row fail vs bulk write | Extra batch overhead |
| Object Store for claim | Fast | Not multi-region; use DB claim |

**MVP:** SQL + reject + job API + email.  
**Later:** MQ to Data Cloud, POS path, multi-region active-passive scheduler.

---

# Question 2 — Customer 360 (read path)

### Prompt

Mobile and web need `GET /customers/{id}` combining Salesforce CRM, SAP billing, and optional loyalty. p95 &lt; 400 ms. Loyalty may be down. SAP p95 is 1.2 s. Peak 5k RPS. Salesforce 100k API calls/day.

---

### 1. Clarify

- Stale billing for 5–15 minutes acceptable?  
- GDPR erase SLA?  
- Same graph for IVR later?

**Assume:** slightly stale billing OK; loyalty optional; erase &lt; 60 s.

---

### 2. Requirements

**Functional:** one customer profile; partial response if loyalty fails; erase invalidates data.

**Non-functional:** p95 400 ms; 5k RPS; stay under Salesforce daily cap; PII not in CDN.

**Capacity:** 5k RPS × 86400 ≈ 432M GETs/day. Salesforce 100k/day → **must not call Salesforce per GET**.

---

### 3. High-level design

Hot path is a **read model**, not scatter-gather to SAP.

```
SF CDC / Platform Events --> System API SF --> Process: project Customer360
SAP IDoc / delta        --> System API SAP --/
Loyalty events (opt)    --> System API Loy --/

Customer360 store (Redis + SQL)
        ^
        |  GET (p95 in-process / Redis)
Experience: Mobile / Web / later IVR
```

**MVP if no CDC yet:** Experience scatter-gather Salesforce + loyalty (short timeout) + **cached** SAP. Still cannot hit SF 5k RPS — cache aggressively.

---

### 4. APIs

```
GET /customers/{id}
Authorization: user token
→ 200 {
    "id", "crm": {...}, "billing": {...} | stale flag,
    "loyalty": {...} | null,
    "asOf": "ISO-8601"
  }
→ 404, 401

POST /customers/{id}/erase   (internal GDPR)
→ 204  // delete projection + cache, publish erased
```

Cache key: `cust:{id}:v1`. TTL 5–15 min **and** explicit delete on CDC/erase.

---

### 5. Deep dive

- Scatter-gather **on the write/projection path**, not on 5k RPS GET.  
- Loyalty timeout 50–80 ms; null + `loyaltyUnavailable: true`.  
- Stampede: single-flight lock or serve stale.  
- IVR: `?fields=` or a thin Experience over the **same** store.  
- Circuit breaker around SAP projector, not around mobile GET.

---

### 6. Failures and scale

- Salesforce 401: pause projector; GET still serves last projection.  
- Erase: delete SQL row + Redis; do not wait for TTL.  
- Scale Experience horizontally (stateless). Rate-limit at API Manager per app (mobile vs web).

---

### 7. Trade-offs

Live SAP on GET meets freshness and **misses** p95. Projection meets p95 and **risks** stale billing — show `asOf`. CDN for this resource is wrong (PII).

---

# Question 3 — Place order (saga)

### Prompt

Website places an order: reserve warehouse stock, authorize payment, create Salesforce order, notify warehouse. Any step can fail. Warehouse reserve is **not** idempotent. No PAN in Mule. Orders &gt; $50k need human approval.

---

### 1. Clarify

Capture vs auth-only? Timeout for approval? Can we return 202?

**Assume:** auth then capture on ship; 202 OK; 48 h approval timeout.

---

### 2. Requirements

**Functional:** place, compensate (release stock, void auth), approve high value, never double reserve.

**Non-functional:** at-least-once workers; audit trail; PCI: token only.

---

### 3. High-level design

**Orchestration** (Process API owns the recipe). Choreography is weaker for money + stock.

```
POST /orders + Idempotency-Key
  → insert order PENDING + outbox   (DB commit)
  → 202 { orderId }

Worker (FIFO per orderId):
  PENDING_APPROVAL if amount > 50k  (wait for POST /orders/{id}/approve)
  RESERVE WMS      (ledger first)
  AUTH PSP         (token)
  CREATE SF        (outbox if SF down)
  NOTIFY WH
  COMPLETED

On failure: reverse — void auth, release stock, state COMPENSATED | MANUAL
```

---

### 4. APIs and data

```
POST /orders
Idempotency-Key: required
Body: { lines[], paymentToken, amount }
→ 202 { orderId, status }

GET /orders/{id}

POST /orders/{id}/approve     // secured ops/user

POST /internal/compensations/release-stock   // mTLS, saga only
```

```
orders(order_id, idempotency_key UNIQUE, status, amount, payment_token, sf_id, ...)
reservations(order_id PK, wms_reservation_id, status)
outbox(id, type, payload, published)
```

Same Idempotency-Key + same body → original order. Same key + different body → 409.

---

### 5. Deep dive

**Non-idempotent WMS:** insert `reservations(order_id)` **before** WMS call. If row exists, skip reserve. Crash after WMS success before ledger: reconcile job lists open WMS reservations.

**Salesforce down 2 h:** outbox `sf_create`; order not COMPLETED until SF ack; payment already authorized — document delayed capture.

**PAN:** hosted fields / PSP.js; Mule stores token only.

---

### 6. Failures

Poison JSON → DLQ + MANUAL. FIFO per `orderId` so steps do not race. HTTP timeout on Experience does not mean failure if intent row exists — client retries with same key.

---

### 7. Trade-offs

Sync 201 after all four systems: simpler UX, holds the request, fails often. 202 + saga: correct for this prompt. XA across WMS/PSP/SF: not available.

---

# Question 4 — Partner B2B (REST + SFTP + EDI)

### Prompt

200 retailers. Some REST, some SFTP CSV, some AS2/EDI 850. All become internal canonical orders. REST SLA 2 s. Files same business day. One partner must not starve others. 7-year signed archive for EDI.

---

### Design

- **Per-channel Experience** (adapter) → **one Process** canonical Order → System APIs (ERP, etc.).  
- API Manager: **per partner** client-id, SLA, IP allowlist.  
- Isolation: separate MQ destinations or partition key `partnerId`; spike arrest per client.  
- Idempotency: `(partnerId, poNumber)` unique. Replay yesterday+today → same order id, 200.  
- Bad EDI: quarantine raw blob; no guess-repair unless a tested partner quirk.  
- 7-year non-repudiation: object storage (WORM), not Object Store. Store hash, cert, timestamp.

**Rejected:** 200 Mule apps; shared unbounded HTTP pool.

---

# Question 5 — Notification hub

### Prompt

Many apps need email, SMS, Teams, Slack. Design one reusable MuleSoft service.

---

### Design

```
POST /notifications
{ "channel": "email|sms|teams", "to", "templateId", "data", "correlationId" }
→ 202 { notificationId }
```

Process routes by channel; System API per provider. Template in Exchange. Caller does not embed SMTP.

**Rule:** notification failure must not fail the **business** job that already committed (on-error-continue + secondary PagerDuty). Deduplicate by `correlationId + templateId`.

This is the reusable-asset question on architect JDs.

---

# Question 6 — Hybrid SAP extract

### Prompt

SAP is in the DC. No inbound internet. MuleSoft is mostly CloudHub 2.0. Nightly 2M-row extract. Design connectivity, HA, resume.

---

### Design

**Path (pick one, say why):**

1. CloudHub 2.0 Private Space + VPN/Direct Connect (cloud-first ops).  
2. RTF or small on-prem Mule beside SAP, outbound to Anypoint MQ (strictest SAP network).  
3. Reject: public HTTP to ECC.

**Extract:** delta by document number, not wall-clock watermark (DST). Checkpoint every N pages in DB. VPN drop → resume checkpoint.

**HA:** two tunnels; two System API replicas; competing consumers on MQ. Batch scheduler **active-passive** (one region).

**Secrets:** Secrets Manager; dual-valid password on rotation.

---

# Question 7 — Fault-tolerant platform (checklist question)

### Prompt

How do you design MuleSoft integrations so a dependency outage does not take down the business?

### Answer (board as a table)

| Concern | Pattern |
|---------|---------|
| Transient timeout | Retry + jitter; no retry on 4xx except one token refresh |
| Dependency down | Circuit breaker; queue; degrade (loyalty null) |
| Poison | Max retries → DLQ / reject table |
| Duplicate delivery | Idempotency key + DB unique |
| Worker death | Ack after durable write |
| Deploy | Drain listeners; persistent batch + upsert |
| Observe | `correlationId` + `jobId`; alert on lag, not CPU |
| Edge load | API Manager spike arrest → 429 |

Name error types: `HTTP:TIMEOUT`, `MULE:CONNECTIVITY`, `DB:*`. Catch-all `MULE:ANY` last.

---

# Question 8 — Enterprise API platform (CoE)

### Prompt

200 projects. Design the MuleSoft operating model.

### Answer

- Default: Experience / Process / System; exceptions documented.  
- Exchange is the catalog; no private laptop integrations to SAP.  
- Standard policies: OAuth or client-id, rate limit, JSON threat protection.  
- Shared error format, correlation id, secret pattern.  
- CI: MUnit → deploy dev → promote API Manager → prod.  
- vCore budget: isolate batch from Experience.  
- CoE review for new System APIs (system of record ownership).

Interviewers use this for “architect vs developer.”

---

# Short technical Q&A (screens)

**Q. When do you collapse API-led layers?**  
A. Single consumer, single system, no reuse in 12 months, or a pure batch firehose. Not to save one vCore if three channels share process logic.

**Q. Object Store vs MQ vs DB?**  
A. MQ = work to do. DB = money/audit/uniqueness. OS = short TTL cache or bookmark. OS is not a queue (TTL, no DLQ, no competing consumer).

**Q. Continue vs Propagate?**  
A. Propagate DB/SFTP (business failed). Continue email after successful load. Continue on DB insert hides failure.

**Q. CloudHub vs RTF?**  
A. CH2 for public elastic APIs. RTF/on-prem for data residency, PCI, or SAP RFC latency. Hybrid: System API near SAP, Process/Experience in CH2.

**Q. Why more workers can make SFTP worse?**  
A. Both process/delete the same file. Fix: DB claim.

**Q. Salesforce Bulk vs Composite vs CDC?**  
A. CDC/events for ongoing sync. Bulk 2.0 for nightly tens of thousands. Composite for interactive &lt; 25 records. Never Composite in a 20M loop.

**Q. Watermark?**  
A. Store source sequence (IDoc, replay id, file checksum) in a **DB** control table. `now()` in Object Store breaks on DST and multi-worker.

---

# 60-minute script (Question 1)

| Min | Activity |
|-----|----------|
| 0–5 | Clarify + write NFRs |
| 5–20 | HLD: job, stream, SQL truth, outbox, rejects |
| 20–35 | Completeness, claim, upsert, email continue |
| 35–50 | 20M memory, two workers, Data Cloud lag |
| 50–60 | Risks + MVP |

**Risks to say:** partial file, duplicate load, analytics vs ops SLA.

---

# Scoring

| Axis | 1 | 3 | 5 |
|------|---|---|---|
| Requirements | Jumps to connectors | Lists FR/NFR | Quantifies volume and SLA |
| Decomposition | One flow | API-led | Clear ownership + async boundary |
| Data | No keys | Basic mapping | Identity, LWW, upsert |
| Reliability | Happy path | Retry | Idempotency, DLQ, replay |
| Scale | More vCores | Pools | Claim, backpressure, 202 |
| Operability | Logs | Alerts | Job API, SLI lag, runbook |

Pass ≈ 3.5+ average.

---

# What job openings map to which question

| JD bullet | Use question |
|-----------|----------------|
| Batch, SFTP, DB, notifications | Q1 |
| Salesforce + low latency APIs | Q2 |
| Orchestration, ERP, payments | Q3 |
| Partners, EDI, API Manager | Q4 |
| Reusable assets, Exchange | Q5 |
| Hybrid, SAP, CloudHub/RTF | Q6 |
| HA, retries, monitoring | Q7 |
| Governance, HLD/LLD, CoE | Q8 |
