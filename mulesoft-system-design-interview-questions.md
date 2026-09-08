# MuleSoft System Design Interview Questions (with model answers)

A question bank for **senior / staff integration engineers** and **MuleSoft architects**. Questions emphasize architecture trade-offs, not connector trivia.

**How to use this**

- **45–60 min design round:** pick **one** scenario from Section 2, then 2–3 probes from Section 3.
- **30 min deep dive:** one topic from Section 3 plus a short sketch of a related scenario.
- Score **trade-offs, failure modes, and operability** more than RAML syntax.
- Model answers are **interviewer keys**, not scripts. Reward equivalent designs that name the same risks.

Expected signals of a strong answer: API-led (or a justified alternative), idempotency, backpressure, error taxonomy (retry vs DLQ vs poison), observability, security (OAuth, secrets, network), and a clear runtime choice (CloudHub 2.0, Runtime Fabric, hybrid).

---

## 1. Warm-up (5–8 minutes)

Use 2–3 of these to calibrate seniority before a full design.

### 1. API-led connectivity

**Q.** Draw Experience, Process, and System APIs for an order-to-cash flow that touches Salesforce, SAP, and a warehouse WMS. When would you **collapse** layers (and why)?

**Model answer**

- **Experience:** channel-shaped contracts — `POST /mobile/orders`, `POST /b2b/orders`, `GET /portal/orders/{id}`. Authn for that channel, pagination, field filtering, no SAP IDoc types leaking out.
- **Process:** `POST /orders` orchestration — validate, reserve inventory, price/tax, persist Salesforce order, post to SAP, notify WMS. Owns saga state, idempotency, canonical **Order**.
- **System:** thin, stable wrappers — Salesforce Composite/REST, SAP OData/RFC, WMS HTTP/JMS. 1:1 with the system, retries and connector config live here, not in Experience.

**Collapse when:** a single consumer and a single system (no reuse in 12 months); a batch-only firehose with no interactive API; or a System API that would be a pass-through with no mapping. Do **not** collapse to “one mega-app” just to save vCores if three channels will share inventory + payment logic.

**Weak:** drawing three boxes with the same RAML; putting Salesforce session handling in the Experience API.

---

### 2. Sync vs async

**Q.** A B2B partner posts 50k invoices at 9:00 AM. Design the MuleSoft surface they call. What is synchronous, what is queued, and how do you return a correlation ID?

**Model answer**

- **Do not** process 50k invoices inside one HTTP request. Sync path: `POST /invoices/batches` accepts a file URL or a bounded payload (or `202` after storing to object storage / SFTP), validates envelope (partner id, count, checksum), persists a **batch job** row, publishes to Anypoint MQ, returns **`202 Accepted`** with `batchId` / `Location: /invoices/batches/{id}`.
- Sync validation only: auth, schema of the *manifest*, payload size limits, spike arrest.
- Async workers: parse, validate line items, call System APIs, write rejects.
- Status API: `GET /invoices/batches/{id}` with counts, `failed` link to reject file.
- Correlation: generate `batchId` (UUID) at the Experience edge; set `correlationId` on the Mule event; pass both in MQ headers and logs.

**Weak:** `foreach` 50k Salesforce creates on the listener thread; returning `200` only after SAP posts.

---

### 3. Runtime placement

**Q.** Compare CloudHub 2.0, Runtime Fabric (RTF), and on-prem Mule for: VPC/private SAP, PCI card data, bursty public APIs, and a 2-hour nightly batch. Pick one stack per case.

**Model answer**

| Case | Pick | Why |
|------|------|-----|
| Private SAP (no inbound internet) | **CH2 Private Space + VPN/TGW**, or **RTF in the DC**, or a **small on-prem Mule bridge** that only talks outbound | SAP never needs a public listener. CH2 Private Space if network team will peer; RTF if Kubernetes already exists next to SAP. |
| PCI card data | **RTF or on-prem in the PCI VPC**; tokenize as early as possible | Reduce CH2 scope; never persist PAN in Object Store / logs. PSP tokenization at Experience edge. |
| Bursty public APIs | **CH2** with autoscale + API Manager | Elastic vCores, Anypoint policies at the edge. |
| 2-hour nightly batch | **CH2 scheduled worker** *or* RTF with a dedicated node pool | Batch needs disk/memory more than elastic HTTP. Avoid mixing with latency-sensitive Experience APIs on the same workers. |

**Weak:** “everything on CloudHub” with no path to SAP; “on-prem for all” with no ops story.

---

### 4. Object Store vs Anypoint MQ vs DB

**Q.** You need exactly-once-ish processing of payment events. Which store for watermarks, which for queues, which for audit? What breaks if Object Store is used as a queue?

**Model answer**

- **Queue:** Anypoint MQ (or Kafka/JMS if enterprise standard). Visibility timeout, DLQ, competing consumers. FIFO queue only if you need per-key ordering.
- **Watermark / processed-key cache:** Object Store v2 **or** Redis for short TTL idempotency keys (`paymentId`, 24–72 h). OS is not a source of truth for money.
- **Audit / exactly-once-ish:** **DB unique constraint** on `payment_event_id` (or outbox table). Consume → insert audit (ignore duplicate) → call PSP / update status. The DB row is the lock.
- **Object Store as a queue fails:** no durable competing-consumer semantics, TTL eviction, size limits, no DLQ, not queryable, workers can lose messages, not for payloads.

**Weak:** “Object Store for everything”; claiming exactly-once from MQ alone.

---

### 5. Streaming vs materialize

**Q.** A 4 GB CSV lands on SFTP. How do DataWeave streaming, batch job `blockSize`, and DB bulk insert interact? Where does heap blow up?

**Model answer**

- Read with **streaming MIME** (`outputMimeType="text/csv; streaming=true"`). DataWeave `output application/json deferred=true` (or stay in CSV/Java iterator) so you do not build a 4 GB `Array`.
- Batch **input** still persists records to the batch store (disk/DB depending on config). `blockSize` = how many records a thread pulls per grab. Aggregator size = JDBC batch size.
- **Heap blow-ups:** `payload map { ... }` to `application/json` without deferred; `readUrl` entire file; converting to Java `ArrayList`; logging the payload; `foreach` without streaming; aggregator `size` too large; `batch:commit` of huge in-memory lists; attaching the full file to email.

**Weak:** “DataWeave is streaming so memory is O(1)” while using `output application/java` of all rows.

---

## 2. Full system design scenarios (45–60 minutes)

Ask the candidate to **whiteboard** components, APIs, queues, stores, and failure paths. After 20 minutes, inject a constraint from the “twists” list.

---

### Scenario A — Multi-source inventory ingestion (retail)

**Prompt.** Design a MuleSoft platform that ingests nightly store inventory files (CSV on SFTP), near-real-time POS deltas (HTTPS), and a weekly master-data dump from SAP. Downstream: SQL Server (operational) and Salesforce Data Cloud (analytics). Files range from 10k to 20M rows. Duplicate SKUs across files are common. Ops needs email alerts and a success/failure record store.

#### Model architecture

```
Partners / stores
  SFTP CSV ──► [Job starter: HTTP or scheduler] ──► Job control table (batchId, checksum)
  HTTPS POS ──► Experience API (small JSON) ──► Anypoint MQ ──► Process worker
  SAP dump ──► System API (pagination/CDC) ──► same Process inventory ingest

Process: validate → enrich SKU from MDM cache → fan-out
  ├─ SQL Server (upsert operational)     [SLA: minutes]
  └─ MQ ──► Data Cloud loader            [SLA: hours]
Reject table + on-complete email digest
```

- **File path:** do not use an always-on SFTP listener as the only trigger (partial files). Prefer **done-file / size-stable check**, or ops `POST /ingestion/jobs` with path. Stream CSV → Mule **batch job**: step 1 validate; aggregator bulk-insert success; step `ONLY_FAILURES` writes rejects. `maxFailedRecords=-1` if 1% poison must not abort 20M rows.
- **POS path:** sync `202` or `200` with validation only; async apply to SQL. Spike arrest per store.
- **SAP path:** System API pages by `changedSince` **sequence**, not wall clock.
- **Identity:** canonical key `sku + storeId`. Quantity conflicts: **event-time LWW** (payload `Timestamp`) not arrival time. Persist `source` + `event_ts` on the row.
- **Dual sink:** **do not** XA dual-write. SQL Server is source of operational truth; enqueue `InventoryChanged` for Data Cloud. Analytics can lag.
- **Idempotency:** file registry `(name, size, sha256)` unique; row upsert on `(sku, storeId)` with `event_ts >= existing`. Replay is safe.
- **Alerts:** one email in **on-complete** (counts, reject sample, duration). Never per-row.

#### Twists

| Twist | Answer |
|-------|--------|
| Truncated SFTP | Require `.done` sentinel or two identical size samples N seconds apart. Never `delete` until job `SUCCEEDED`. Quarantine incomplete files. |
| Overlapping files 15 min apart | LWW on `Timestamp`; if timestamps equal, deterministic tie-break (source rank: POS > nightly file). Do not “sum quantities” unless business says so. |
| No PII in logs/OS | Inventory usually has little PII; still: structured logs with `batchId` only; never `#[payload]`; OS only stores checksums/job ids; mask store-manager emails in notification templates. |

**Weak:** one flow for all three sources; dual-write in one DB transaction to Data Cloud JDBC; email on every `on-error`.

---

### Scenario B — Customer 360 Experience API

**Prompt.** Mobile and web need a single `GET /customers/{id}` that composes Salesforce CRM, SAP billing, and a loyalty microservice. p95 &lt; 400 ms. Loyalty is optional. SAP is slow (p95 1.2 s). 5k RPS peak.

#### Model architecture

You **cannot** hit SAP on the hot path and keep p95 400 ms. Design for **read-optimized Process data**.

**Target state**

- System APIs: Salesforce, SAP, Loyalty (never called in parallel from Experience at 5k RPS).
- **Async projection:** CDC/Platform Events + SAP IDoc/CDC → Process “Customer 360 store” (Redis or SQL + cache). Experience `GET` reads the store only (p95 in-process / Redis).
- **MVP compromise:** Experience scatter-gather: Salesforce + Loyalty (timeout 80 ms, loyalty `null` on failure) + **cached SAP billing** (TTL 5–15 min). Never wait 1.2 s for SAP on every GET.

**Caching**

- Key: `cust:{id}:v1` plus field-set hash if IVR needs a subset.
- TTL + **explicit invalidate** on GDPR erase and on CDC.
- Stampede: single-flight (lock in OS/Redis) or serve stale.
- **No** CDN cache for PII responses; private cache only.

**5k RPS**

- API Manager: SLA + spike arrest per client (mobile vs web).
- Horizontal CH2 workers on the Experience app (stateless).
- Salesforce **100k/day twist:** Experience must **not** call Salesforce per GET. Cache or replicated store. Bulk/CDC fills the store; remaining Salesforce quota is for writes and cache miss repair with heavy coalescing.

**Twists**

| Twist | Answer |
|-------|--------|
| 100k SF calls/day | Projection store; cache miss budget; Composite only for admin tools. |
| GDPR erase &lt; 60 s | Erase API: delete projection row, `DEL` cache key, publish `CustomerErased`; do not wait for TTL. |
| IVR subset | New Experience API or `?fields=` on the same Process read model; do not add a third System fan-out. |

**Weak:** scatter-gather to SAP on every request; “until-successful 3 times” on the GET path (amplifies latency).

---

### Scenario C — Order orchestration (saga)

**Prompt.** Place order: reserve inventory (WMS), authorize payment (PSP), create Salesforce order, notify warehouse. Any step can fail. Design Process API + async workers.

#### Model architecture

- **Experience:** `POST /orders` with `Idempotency-Key`. Persist **order intent** (`PENDING`) in DB **before** side effects (outbox). Return `202` + `orderId` (or `201` only if all steps are short and you accept holding the HTTP).
- **Process orchestrator** (Mule, **orchestration not choreography** for this because compensations are linear and finance needs one audit trail):
  1. Reserve WMS  
  2. Auth PSP (token only)  
  3. Create Salesforce order  
  4. Notify warehouse  
  On failure: compensating actions in reverse (void auth, release stock). Persist saga state: `RESERVING` → `AUTHORIZING` → `RECORDING` → `NOTIFYING` → `COMPLETED` / `COMPENSATING` / `NEEDS_MANUAL`.
- **Why Mule as orchestrator:** one place for timeouts, retries, and compensating APIs; WMS/PSP/SF do not know each other.
- **Queue:** Anypoint MQ standard for steps; **FIFO per `orderId`** if you must avoid dual reserve. DLQ after N retries. Poison: `NEEDS_MANUAL` + ops API.
- **Salesforce down 2 h:** **transactional outbox** — write `sf_create` message in the same DB commit as order `AUTHORIZING_OK`; worker publishes to MQ; SF System API retries independently. Order is not `COMPLETED` until SF ack, but payment is already authorized (document this; optional delayed capture).

**Twists**

| Twist | Answer |
|-------|--------|
| No PAN | Experience talks to PSP.js / hosted fields; Mule stores `paymentMethodToken` only. PCI scope stays at PSP. |
| WMS not idempotent | **Reservation key** you generate (`reservationId = orderId`). If WMS ignores it, **reservation ledger in your DB**: before call, insert `reservations(order_id)` unique; on retry skip WMS if row exists. If crash after WMS success before ledger, **reconcile job** (list open reservations). |
| Human approval &gt; $50k | Saga wait state `PENDING_APPROVAL`; do not authorize until approved (or auth+capture split). Resume via `POST /orders/{id}/approve` (secured). Timeout SLA → auto-cancel + compensate. |

**Weak:** one HTTP Experience flow calling four systems; no compensations; retry WMS blindly.

---

### Scenario D — Partner B2B / EDI + REST hybrid

**Prompt.** 200 retail partners. Some send AS2/EDI 850, some REST JSON, some SFTP CSV. All must become internal canonical orders. SLAs: REST 2 s, files “same business day.”

#### Model architecture

- **Per-channel Experience (adapter), one Process canonical `Order`.**
  - REST: partner-specific RAML/OAS in Experience, map to canonical, `202` or `201` if tiny.
  - SFTP: same job pattern as Scenario A, SLA hours.
  - AS2/EDI: B2B/EDI module or specialist translator → canonical XML/JSON → same Process API.
- **Isolation:** API Manager **per partner client-id**, SLA tiers, IP allowlist. Separate MQ **queues or destinations per partner** (or partition key) so Partner 199 cannot fill a shared prefetch and starve others. Rate limit REST independently of file workers.
- **Versioning:** canonical Process `v1` additive; Experience versions per partner. Breaking canonical change = `v2` Process with translator.
- **Malformed EDI:** **quarantine** raw payload to blob + reject row; do not “guess” PO lines. Optional human mapping UI. Auto-repair only for known, tested partner quirks (config, not code if possible).

**Twists**

| Twist | Answer |
|-------|--------|
| Replay yesterday + today | Idempotency key = partner `PO number` + `partnerId` unique in DB. Duplicate REST → `200` with original `orderId`. Duplicate file lines upsert. |
| Non-repudiation 7 years | Store raw signed AS2 + metadata (hash, cert serial, timestamp) in WORM/object storage; DB holds pointer. REST: optional HMAC + request archive. Mule Object Store is **not** a 7-year archive. |

**Weak:** 200 Mule apps (one per partner) with copied Process logic; shared unbounded HTTP thread pool.

---

### Scenario E — Event backbone for domain events

**Prompt.** Salesforce Platform Events, SAP IDocs, and a custom Kafka cluster must drive a “customer changed” process that updates three systems. Some consumers need ordered events per customer; others want at-least-once fan-out.

#### Model architecture

- **Ingress System APIs / listeners** normalize to canonical `CustomerChanged` (AsyncAPI).
- **Bus:** Kafka (already present) as the backbone; Anypoint MQ for Mule-native consumers that cannot speak Kafka. Do not dual-master SF + Kafka.
- **Ordering:** `partition key = customerId` (Kafka) or **FIFO group id = customerId** (AMQ FIFO). Unordered consumers use a standard queue / separate topic.
- **Dedup:** producer includes `eventId`. Consumer DB **unique(`eventId`)** or `(customerId, sourceSeq)`. Object Store TTL is a **cache**, not the ledger.
- **Replay:** Salesforce replay id persisted in **DB control table** (not only OS). Kafka consumer group offsets. SAP IDoc numbers as watermark.
- **Poison:** if ordered topic, **skip + quarantine** after N failures **or** head-of-line blocking is unacceptable — use a **per-customer error flag** and park that key; do not stall all customers. Unordered consumers: DLQ freely.
- **Schema:** AsyncAPI + schema registry (JSON Schema/Avro). Additive fields; consumers ignore unknown.

**Twists**

| Twist | Answer |
|-------|--------|
| Consumer down 12 h | Kafka retention &gt; 12 h; scale consumers; **priority catch-up** (skip derived events if a newer event for same customer exists — snapshot + latest wins). Monitor lag SLI. |
| Exactly-once into at-least-once API | Idempotent **upsert** with `eventId` / `updatedAt` at the target; or outbox in your DB then “at least once” call with the same business key. You cannot get exactly-once from the API; you get **exactly-once effects**. |

**Weak:** one FIFO queue for all customers (global ordering kills throughput); infinite retries on poison.

---

### Scenario F — Hybrid integration with locked-down SAP

**Prompt.** SAP lives in a corporate DC. MuleSoft is mostly CloudHub 2.0. No inbound from internet to SAP. Design connectivity, HA, and a nightly 2M-row extract.

#### Model architecture

- **Connectivity (preferred order):** (1) CloudHub 2.0 **Private Space** + VPN/Direct Connect to DC; (2) **RTF in DC** for SAP System API only, Process/Experience on CH2; (3) **on-prem Mule** as outbound-only bridge (SAP → MQ in cloud). SAP still has **no inbound from internet**.
- **HA:** two VPN tunnels; System API replicas; SAP message server / load-balanced PI. Mule **cluster** only if you need shared VM/Object Store; CH2 workers are competing consumers on MQ, not a classic HA cluster.
- **2M-row extract:** SAP CDC or delta by **document number**, paginated. Stream to file or bulk JDBC; do not load 2M into payload. Checkpoint every N pages in DB. If VPN drops: resume from last checkpoint, **not** from zero.
- **Secrets:** Anypoint Secrets Manager or HashiCorp; encrypted YAML is OK for non-prod. Rotation: dual-valid cert/password window.

**Twists**

| Twist | Answer |
|-------|--------|
| Active-active two SAP DCs | Sticky to the DC that owns the record, or read from replica with lag SLA; extract job pinned to primary; conflict policy documented. |
| Change freeze: no Mule next to SAP | Must use network path (Private Space/VPN) and SAP-supported interfaces (IDoc/OData) only. Batch windows aligned with SAP load. |

**Weak:** CloudHub HTTP listener calling public SAP; storing SAP password in `dev-config.yaml`.

---

### Scenario G — Multi-tenant SaaS integration layer

**Prompt.** Your product embeds MuleSoft to sync each tenant’s Salesforce org. 2,000 tenants, noisy neighbor problem, per-tenant credentials, per-tenant rate limits.

#### Model architecture

- **Tenancy:** **one Mule app, many tenants** with a control plane DB (`tenant_id`, credentials ref, cursor, quota). Not 2,000 deployments (ops death). Not one huge shared Salesforce connection.
- **Credentials:** Secrets Manager path `tenants/{id}/sf`; never in logs. Memory cache with short TTL.
- **Fairness:** per-tenant **token bucket** (SF API limits). Scheduler: work-stealing queue of tenant jobs; **max N concurrent per tenant**, global cap on SF connections. Noisy tenant hits 429 → backoff that tenant only.
- **Isolation of data:** `tenant_id` on every log line; logging filter strips payloads; support tooling requires tenant-scoped queries. Separate OS partitions per tenant if used.
- **Deploy:** CH2 horizontal scale for the shared app; RTF if you need VPC-per-cell for enterprise customers; **customer-hosted** only for those who cannot send data to your CH2.

**Weak:** app-per-tenant on CH2 (2,000 apps); shared Object Store keys without tenant prefix.

---

## 3. Deep-dive probes (with answers)

### Reliability and failure

**1. On-error-continue vs propagate**

- **Propagate:** fails the current event/step so batch marks the record failed, HTTP returns 5xx, or the flow stops. Use for **DB, SFTP, HTTP business failures** you cannot ignore.
- **Continue:** swallows the error, flow proceeds as success. Use for **best-effort side effects** (email, metrics). If you `continue` on DB insert, the batch **looks successful** and you will **not** write rejects — that hides a failed batch.
- **Taxonomy:** `DB:*` propagate + alert; `FTP:*` propagate (cannot process); `HTTP:*` propagate or map to 4xx; `EMAIL:*` continue + log + secondary alert; custom `BATCH_FAILED` propagate after on-complete detects fatal condition.

**2. Until-successful vs reconnection**

- Connector **reconnection** is for dropped TCP/idle; not for HTTP 429/500 semantics.
- **Until-successful** is application retry with delay. For Salesforce: honor `Retry-After`, exponential backoff, **jitter**, max attempts, then DLQ. Circuit breaker to fail fast when SF is down. Do not retry 400/401 (except token refresh once).
- Avoid storms: cap concurrency; jittered scheduler; one refresh-token path globally.

**3. Redelivery (HTTP vs MQ)**

- HTTP: client retries; you **must** be idempotent. No ack.
- MQ: ack after **durable side effect**. If you commit DB then crash before ack → redelivery → duplicate unless unique key / idempotency store.
- “Processed” = **audit row committed**. Ack MQ only after that. If you ack before DB, you can lose the message.

**4. Poison records**

- `maxFailedRecords=-1`: finish the job, collect failures. `0` = fail fast.
- `acceptPolicy=ONLY_FAILURES` step writes reject table with `error.description`.
- **Redrive:** `POST /ingestion/jobs/{id}/redrive-rejects` reads reject table, clears resolved rows, does **not** re-read the original file (file may be gone). Fix data or mapping first.

**5. Timeouts on a 20M-row file**

- HTTP listener timeout applies only to the **kickoff** request — return `202` immediately; **never** hold the listener for the batch.
- Batch timeout / max aggregation: bound a **step**, not the whole night job, or set high with checkpoints.
- First to fire if someone foolishly runs batch synchronously on HTTP: **listener timeout**, leaving an orphan job. That is why kickoff is async.

---

### Data and batch

**6. Batch job internals**

- **Input:** load/split records into batch store. **Process:** steps (parallel). **On-complete:** summary (loaded/failed), notifications.
- Default store persists records for restart; CloudHub worker crash can **resume** if the store is persistent. In-memory store = restart from scratch (duplicates unless upsert).
- Implications: persistent store + upsert; don’t assume two CH2 workers share one in-flight batch job unless designed as competing **jobs**, not two processors of one job.

**7. Aggregator size vs `blockSize`**

- `blockSize`: work unit per thread (latency vs overhead). `1` + aggregator is valid when you want **validate one-by-one** then **bulk write N**.
- Aggregator / JDBC batch: typically **100–1000** rows depending on row width and SQL Server packet/timeout. Too small = round-trips; too large = timeouts, locks, heap.
- Measure: rows/sec, DB CPU, Mule heap, batch step duration.

**8. Watermarks**

- Prefer **source sequence** (IDoc number, SF replay id, file mtime+checksum) in a **DB control table**.
- Object Store last-run `now()` breaks on DST, clock skew, overlapping windows, multi-worker races, TTL.
- Duplicate window: store `last_successful_seq` and re-extract overlap of 1 page; upsert.

**9. Canonical SKU identity**

- **MDM / PIM owns SKU.** POS/SAP/e-comm ids are aliases in a cross-ref table (`source`, `source_sku`, `canonical_sku`).
- Mule System APIs translate to canonical at the edge of Process. Conflicts: workflow to PIM, not “whichever file arrived last” for **identity** (quantity LWW is separate).

**10. DataWeave memory**

- `deferred=true` + streaming MIME keeps a cursor.
- `output application/java` of a mapped array **materializes** the graph → O(n) heap.
- JSON array output of 20M objects explodes. Map **per record** inside batch, not `payload map` on the whole file after converting to JSON.

---

### APIs and contracts

**11. API Manager**

- Policies (SLA, spike arrest, OAuth, JWT, IP allowlist) run at the **gateway** (autodiscovery / proxy), **before** the Mule app.
- App still must authorize **business** rules (tenant, resource).
- Client credentials for M2M; auth code / OIDC for users; JWT if enterprise IdP already issued.
- If autodiscovery fails: app may boot **unprotected** if you misconfigure — treat as incident; fail closed in prod.

**12. Versioning**

- Public Experience: URL `/api/v1` (clear for partners). Headers for minor additive.
- Two Experience versions can `flow-ref` or HTTP-call the **same Process v1** until a breaking Process change.
- RAML overlays for env-specific examples, not for incompatible contracts.

**13. Idempotency-Key**

- Header required on `POST /orders`. Store key → `orderId` in **DB unique index** (business duplicate window = 24 h to 7 days).
- Object Store TTL is OK as a **fast path** but DB is source of truth (OS eviction ≠ “not a duplicate”).
- Same key + same body → return original. Same key + different body → `409`.

**14. Pagination / SOQL**

- System API **forces** `limit`/`cursor`; default page size; max page size. Experience cannot pass raw SOQL.
- Server-side filters only on indexed fields. Timeouts mapped to `504` with retry guidance.

**15. BFF vs generic Process**

- BFF Experience when: mobile payload shape, chattiness, auth, or latency differ (IVR vs app).
- Generic Process when: multiple channels share orchestration. Don’t let every BFF call three System APIs itself.

---

### Scale and performance

**16. When more workers worsen SFTP**

- Two workers **read/delete the same file** (no file lock / claim table) → duplicates or missing files.
- SFTP server connection limits; both workers open huge streams.
- Fix: **claim** row `UPDATE files SET locked_by=worker WHERE locked_by IS NULL`; single scheduler; or one consumer group.

**17. Backpressure**

- Edge: API Manager **spike arrest / SLA** → `429`.
- Interior: bounded MQ; if queue depth &gt; N, Experience `503`/`429` with `Retry-After`.
- Do not unbounded-buffer in VM memory. Slow consumers: scale workers or shed lowest-priority partners.

**18. Connection pools**

- Symptom: threads blocked on pool checkout, not CPU; DB `wait` vs Mule `idle`.
- Salesforce: concurrent request limits (not just JDBC pool).
- Tune pool to **downstream limit**, not to worker thread count. Metric: pool active = max **and** request queue growing.

**19. Deploy vs in-flight batch**

- **Drain:** stop listener/scheduler; let batch finish; then deploy. Or **abort** and rely on upsert + checkpoint (faster, risk more rejects).
- CH2 rolling deploy can kill a worker mid-job → persistent batch store + idempotent writes required.
- Do not “zero-downtime” Experience and Batch on the **same** app if you cannot drain.

**20. Multi-region**

- Experience: any region + global LB; **sticky** only if in-memory session (avoid).
- Object Store is **region-local** — don’t use it for cross-region locks.
- MQ: regional vs replicated; file claim table in a **global DB** so two regions don’t ingest twice.
- Prefer **active-passive batch** (one region runs jobs).

---

### Security and compliance

**21. Secrets**

- Prod: Secrets Manager / secure properties with env-specific keys. Encrypted YAML in git is last resort.
- Rotation without restart: fetch at runtime (Secrets Manager API / injector) or dual secrets + rolling restart.
- Never default passwords in `src/main/resources`.

**22. mTLS to SAP**

- Client cert in secret store; trust SAP CA. Alert on cert expiry **30/14/7** days. Dual cert window. Runbook to rotate without changing SAP inbound allowlists (same DN if possible).

**23. PII**

- Log `correlationId`/`batchId`, not email/PAN/payload. Log4j pattern deny-lists. Debug logging off in prod.
- Field-level encryption only if you must store PII in Mule-accessible DB; prefer not to store.

**24. Least privilege**

- SFTP: `read` user for ingest; separate `move` user for archive; no delete on prod until job success.
- DB: writer role on success table; writer on reject; no DDL. Read-only for support.

**25. Threat model**

- API Manager body size; HTTP listener max; reject zip bombs; stream-scan CSV (max rows, max line length); virus scan if files are executable. Timeout slowloris. Quarantine, don’t parse 50 GB.

---

### Observability and operations

**26. Correlation**

- One `correlationId` (HTTP header in / out, MQ property, SF `externalId` or custom field). `batchId` is the **business** job id (many events share it).
- Splunk: index both. Anypoint Monitoring: flow metrics by app. Never require humans to grep timestamps only.

**27. SLIs**

- **Freshness:** `now - max(event_ts)` per store. **Error rate:** rejects / loaded. **Lag:** MQ depth, SF replay delay.
- Alert on freshness/lag, not CPU. CPU is a diagnostic.

**28. Replay runbook**

- **Allowed:** `POST /jobs` with `force=true` after checksum override; redrive rejects; replay from watermark.
- **Forbidden:** manual delete of success rows “to try again”; re-running while job `RUNNING`; using prod files in dev.
- Record who/when in an audit table.

**29. Config per env**

- Separate YAML + secrets; CI injects; runtime `mule.env`. Block deploy if `prod` hostnames appear in non-prod artifact (policy check). Different SFTP accounts and directories.

**30. Notifications**

- On-complete digest; PagerDuty for **job failed** or freshness SLI. Deduplicate by `batchId`. Email connector failure must **not** fail the job (`on-error-continue`) but must hit a second channel.

---

### Platform and SDLC

**31. CICD**

- PR → MUnit + static checks → publish Exchange (RAML, fragments) → deploy to CH2 Design/Dev with **non-prod** secrets → promote API Manager instance (dev → test → prod autodiscovery ids) → prod deploy with change ticket. Never promote encrypted prod secrets via the same file as dev.

**32. Exchange reuse**

- **DataWeave module:** pure mapping.
- **System API:** reusable access + policies + throttling.
- **Connector:** when you need operations/UX in many apps and a supported protocol. Don’t wrap one HTTP GET as a connector.

**33. Test layers**

- **MUnit:** error handlers, DataWeave, batch step mocks, idempotency.
- **Contract:** RAML/OAS vs Experience.
- **CDC (consumer-driven):** Process vs Experience expectations. Don’t MUnit-mock the universe instead of contract tests.

**34. Autodiscovery failure**

- App may start without applying policies. **Fail closed** in prod (health check verifies policy / expected header). Alert. Do not silently serve public.

**35. 4 vCore budget**

- Example split: Experience 1, Process 1, System 1, Batch 1. Burst: queue, not more always-on vCores. MQ instead of holding HTTP. Cache to cut System calls. Batch off-peak on the Process worker only if you accept blast radius — better keep batch isolated even if smaller.

---

## 4. Architecture comparison — recommended answers

| # | Question | Recommendation | Reject (and why) |
|---|----------|----------------|------------------|
| 1 | CH2 Private Space vs RTF for SAP RFC | **Private Space + VPN** if cloud-first ops; **RTF in DC** if RFC is chatty/latency-sensitive or K8s already exists | Public CH2 + internet SAP (forbidden); RTF “because Kubernetes” with no platform team |
| 2 | AMQ vs Kafka vs IBM MQ | **AMQ** for Mule-native, modest volume; **Kafka** if replay, partitions, existing backbone; **IBM MQ** if enterprise already standardized and SAP/WMS speak JMS | AMQ FIFO for huge unordered telemetry (cost/throughput); Kafka for 10 messages/day |
| 3 | Batch vs foreach+VM vs scheduler+pagination | **Batch job** for huge files + reject steps; **scheduler+pagination** for API extracts; **foreach+VM** for medium async with simple flow | foreach 20M in one event; batch for 5-record interactive API |
| 4 | SF Composite vs Bulk 2.0 vs CDC | **CDC/events** for sync-out; **Bulk 2.0** for nightly &gt;10k; **Composite** for interactive &lt;25 records | Composite in a 20M loop; Bulk for a single-record Experience GET |
| 5 | Experience cache vs CDN vs SF Platform Cache | **Redis/OS near Experience** for private PII; **SF Platform Cache** only inside SF; **CDN** only for non-PII public | CDN caching `Authorization` responses; OS as the only GDPR erase mechanism |
| 6 | Orchestration vs choreography | **Orchestration (Process API)** for sagas with compensation and audit; **choreography** for loosely coupled notifications | Choreography for payments without a ledger |
| 7 | Canonical IDs in OS vs MDM | **MDM/DB**; OS as cache of lookups | OS as system of record (TTL, no query, no audit) |
| 8 | File vs API for legacy WMS | **File/SFTP** if WMS cannot SLA 2 s and already drops CSVs; **API** if they can add idempotent reserve | File for a mobile checkout reserve |

---

## 5. “Design this API” — model answers

### 1. `POST /ingestion/jobs`

```
POST /ingestion/jobs
Authorization: Bearer (M2M)
Body: { "path": "/inbox/inv.csv", "source": "STORE_NIGHTLY" }
→ 202 { "batchId": "b-...", "status": "ACCEPTED", "links": { "self": "/ingestion/jobs/b-..." } }

GET /ingestion/jobs/{batchId}
→ { status: ACCEPTED|RUNNING|SUCCEEDED|FAILED, loaded, failed, checksum }

Error model: 401, 403, 409 (already running same checksum), 422 (path invalid), 429
Idempotency-Key optional: same key returns same batchId
Rate limit: ops users low RPS; not a public API
```

Kickoff flow: auth → claim file → insert job row → `202` → async batch.

### 2. `GET /inventory/{sku}?storeId=`

- Read **SQL operational store** (from Scenario A), not SFTP.
- Cache `inv:{store}:{sku}` TTL 30–60 s; `Cache-Control: private, max-age=30`.
- Stale-while-revalidate: serve cache, async refresh.
- `404` unknown SKU; `409` if multiple lots and client didn’t pass `lotId` (if that’s a thing).
- Real-time POS: only if storeId is on the hot path and volume is low; else eventual consistent.

### 3. Salesforce Outbound Message webhook

- `POST /webhooks/salesforce/obm` — allowlist IPs, validate SOAP, **respond 200 within 20 s** after persisting to MQ/DB (do not call SAP inline).
- Duplicates: SF retries → unique `notificationId` / `sObjectId+lastModified`.
- If processing fails after 200, **your** retry from MQ, not SF’s 20 s window.

### 4. Partner bulk upload

- `POST /bulk/orders` `Content-Length` ≤ 10 MB → store blob, `202` + `resultUrl` (pre-signed, TTL 24 h).
- Async validate; result is success/reject files. HMAC + client credentials. Virus/size limits at gateway.

### 5. `POST /compensations/release-stock`

- **Internal only** (mTLS or mesh, not API Manager public). Body `{ orderId, reservationId, reason }`.
- Idempotent on `reservationId`. Authz: saga worker identity only. Audit every call. No Experience portal.

### 6. `/live` vs `/ready`

- **`/live`:** process up (no downstream). Used by orchestrator to kill zombies.
- **`/ready`:** can accept work — DB connection, MQ publish, **not** SFTP (SFTP down shouldn’t take Experience out of LB if this app also serves GET). Split apps: batch worker `/ready` includes SFTP+DB; Experience `/ready` includes DB+cache.

---

## 6. Failure-injection table (expanded answers)

| Failure | Detect | Recover | Extra |
|---------|--------|---------|--------|
| SFTP file still being written | Size stability / done file / lock | Wait + retry; do not delete | Quarantine if size never stabilizes |
| Worker killed mid-batch | Incomplete job in control table | Resume vs restart from watermark | Upsert so either is safe |
| DB unique-key on replay | Constraint vs app upsert | Idempotent upsert; no alert storm | Log at INFO, not PagerDuty |
| SF 401 after rotation | Auth error class | Refresh once; pause workers | Don’t tight-loop refresh |
| MQ poison JSON | Retry count / DLQ | Quarantine API + replay tool | Preserve raw bytes |
| UTF-16 labeled UTF-8 | Parse error spike | Reject file; encoding hint | Don’t “fix” silently |
| DST watermark | Duplicate or gap | Source sequence not wall clock | Overlap page + upsert |
| Email down | Alert channel failed | Slack/PagerDuty; don’t fail batch | `on-error-continue` on EMAIL |

---

## 7. Sample 60-minute interview script

| Time | Activity |
|------|----------|
| 0–5 | Warm-up: API-led + runtime placement |
| 5–25 | Scenario A (inventory ingestion) — candidate drives the board |
| 25–35 | Twist: truncated SFTP files + conflict policy |
| 35–45 | Deep dives: batch store, idempotency, error taxonomy |
| 45–55 | Scale: 20M rows, two workers, DB pool, notifications |
| 55–60 | Recap: top 3 risks and an MVP vs 12-month platform |

**Bar**

- **Hire:** clear job/batch model, reject path, replay story, security of files/secrets, and honest runtime choice.
- **Lean-no:** only happy-path connectors; no idempotency; email as the error bus; “just add vCores.”
- **Strong hire:** control plane (job IDs, watermarks), backpressure, multi-sink consistency, and operability (runbooks, SLIs).

**Expected recap (Scenario A):** (1) dual-write consistency, (2) file claim + truncated SFTP, (3) 20M-row memory. MVP = SQL + rejects + job API; 12-month = CDC projection, MQ to Data Cloud, partner isolation.

---

## 8. Candidate take-home — reference solution

**Brief (repeat).** HTTP start, streamed SFTP CSV, validate, bulk good/bad DB, summary email, safe retry.

**Reference solution**

1. `POST /ingestion/jobs` → job row `ACCEPTED` → `202`. Scheduler/worker picks `ACCEPTED`.
2. Claim file (lock), checksum, skip if `SUCCEEDED` same checksum unless `force`.
3. Stream CSV → batch job: validate sub-flow; aggregator insert success; `ONLY_FAILURES` insert reject.
4. On-complete: counts, email digest, archive SFTP, job `SUCCEEDED`/`FAILED` (FAILED if fatal I/O, not if some rejects).
5. Retry: upsert on business key; reject redrive endpoint.

**Capacity (order of magnitude):** 20M rows × ~200 B ≈ 4 GB file. Stream; aggregator 500; ~10–50k rows/s depending on DB; ~7–30 min. Heap sized for aggregator × threads, not 4 GB. 1–2 vCores dedicated batch.

**Platform add-ons:** API Manager on kickoff, Secrets Manager, Anypoint MQ if fan-out to Data Cloud, Anypoint Monitoring + Splunk `batchId`.

---

## 9. Scoring rubric (interviewer)

Score 1–5 on each axis. A passing senior candidate averages ≥ 3.5.

| Axis | 1 | 3 | 5 |
|------|---|---|---|
| Decomposition | One mega-flow | API-led or justified flatten | Bounded contexts, clear ownership |
| Reliability | Happy path only | Retries + DLQ | Idempotency, poison, replay, timeouts |
| Data | No canonical story | Basic mapping | Identity, conflict, volume, streaming |
| Security | Afterthought | TLS + OAuth named | Secrets, PII, threat limits, least privilege |
| Scale | “More workers” | Pools and async | Backpressure, isolation, cost/vCore |
| Operability | Logs maybe | Alerts | SLIs, correlation, runbooks, config/env |

---

## 10. Quick reference — MuleSoft design vocabulary

Interviewers can listen for these terms used **correctly**:

API-led connectivity · Experience / Process / System APIs · API Manager policies · Autodiscovery · Anypoint MQ (standard vs FIFO) · Object Store v2 · Cluster vs HA · Persistent VM queues · Batch job / step / aggregator · Watermark · Idempotent-redelivery · Until-successful · Circuit breaker · Scatter-gather · Bitronix / XA (and why often to avoid) · CloudHub 2.0 Private Space · Runtime Fabric · Secrets Manager · Correlation ID · MUnit · Exchange assets · Contract-first RAML/OAS · Backpressure / spike arrest · Bulk vs SOAP vs REST System APIs · CDC / Platform Events · Dead-letter / reject store · Compensating transaction

---

## Appendix — File-based batch ingest follow-ups (answers)

Maps to a typical **CSV → validate → SQL Server / Data Cloud → notify** Mule 4 pipeline.

**1. Why HTTP kickoff instead of only SFTP listener?**  
Ops can auth, pass path, avoid firing on partial uploads, return `batchId`, and run replays without a new file event. SFTP listener alone races with writers.

**2. Why `blockSize=1` with aggregators?**  
Validate/fail per record (clean `ONLY_FAILURES`), then **bulk I/O** in the aggregator. Larger `blockSize` processes a chunk as a unit — a failure can be coarser. Use larger blocks when validation is cheap and you want throughput.

**3. Bound aggregator size**  
Cap by: SQL parameter limits, packet size, lock duration, heap (`rows × rowBytes × threads`). Start ~200–1000; tune with metrics. Streaming aggregator still materializes the aggregated list.

**4. `batchId`**  
Generate in initialize sub-flow (UUID). Thread through vars → mapped payload `BatchId` → success/reject tables → logs (`timestamp | batchId | flow`) → email template. Same id for the whole file.

**5. Propagate DB/SFTP, continue EMAIL**  
If insert fails, the record/job must fail. If SFTP read fails, there is nothing to load. If email fails, **data is already loaded** — don’t roll back the batch; log and page on a second channel.

**6. Validation sub-flow throws**  
The record fails the **current batch step**. With a later `ONLY_FAILURES` step, it is routed there. `on-error-continue` inside validation would **incorrectly mark success**.

**7. Archive/delete SFTP only after both sinks**  
If Data Cloud is async MQ, “both sinks” means SQL committed **and** message persisted (outbox). Archive in on-complete only when job status is terminal success. If Data Cloud is sync JDBC in the same aggregator, a failure should not archive; use outbox instead of one XA transaction.

**8. Second region**  
Active-passive scheduler; **claim** in a global DB (`INSERT file_claims`). Object Store will not coordinate regions. Same checksum cannot run twice.

**9. MUnit for 20M rows**  
Don’t check in the file. Unit-test DataWeave and validators on **fixtures of N rows**; test aggregator with 2–3 records; optional performance test in CI with generated temp file. Contract-test the job API.

**10. Slow Data Cloud JDBC vs SQL Server**  
**Do not** dual-write one transaction. SQL first (operational SLA) + **MQ/outbox** to Data Cloud; or CDC from SQL to analytics. Forking two JDBC calls in one aggregator couples SLAs and timeouts.

---

## Appendix — One-page “strong vs weak” cheat sheet

| Topic | Strong | Weak |
|-------|--------|------|
| HTTP + 50k records | 202 + job + queue | Sync foreach |
| Two databases | Outbox / one source of truth | XA / dual JDBC in one step |
| Object Store | TTL cache, watermarks maybe | Queue or money ledger |
| Retries | Backoff, 429, no retry on 400 | Until-successful forever |
| Errors | Reject table + digest | Email per record |
| Scale | Claim files, backpressure | More workers on same SFTP path |
| SAP | Private network, delta extract | Public HTTP to ECC |
| Exactly-once | DB unique + upsert | “MQ is exactly once” |
