# MuleSoft System Design Interview Questions

A question bank for **senior / staff integration engineers** and **MuleSoft architects**. Questions emphasize architecture trade-offs, not connector trivia.

**How to use this**

- **45–60 min design round:** pick **one** scenario from Section 2, then 2–3 probes from Section 3.
- **30 min deep dive:** one topic from Section 3 plus a short sketch of a related scenario.
- Score **trade-offs, failure modes, and operability** more than RAML syntax.

Expected signals of a strong answer: API-led (or a justified alternative), idempotency, backpressure, error taxonomy (retry vs DLQ vs poison), observability, security (OAuth, secrets, network), and a clear runtime choice (CloudHub 2.0, Runtime Fabric, hybrid).

---

## 1. Warm-up (5–8 minutes)

Use 2–3 of these to calibrate seniority before a full design.

1. **API-led connectivity.** Draw Experience, Process, and System APIs for an order-to-cash flow that touches Salesforce, SAP, and a warehouse WMS. When would you **collapse** layers (and why)?
2. **Sync vs async.** A B2B partner posts 50k invoices at 9:00 AM. Design the MuleSoft surface they call. What is synchronous, what is queued, and how do you return a correlation ID?
3. **Runtime placement.** Compare CloudHub 2.0, Runtime Fabric (RTF), and on-prem Mule for: VPC/private SAP, PCI card data, bursty public APIs, and a 2-hour nightly batch. Pick one stack per case.
4. **Object Store vs Anypoint MQ vs DB.** You need exactly-once-ish processing of payment events. Which store for watermarks, which for queues, which for audit? What breaks if Object Store is used as a queue?
5. **Streaming vs materialize.** A 4 GB CSV lands on SFTP. How do DataWeave streaming, batch job `blockSize`, and DB bulk insert interact? Where does heap blow up?

---

## 2. Full system design scenarios (45–60 minutes)

Ask the candidate to **whiteboard** components, APIs, queues, stores, and failure paths. After 20 minutes, inject a constraint from the “twists” list.

### Scenario A — Multi-source inventory ingestion (retail)

**Prompt.** Design a MuleSoft platform that ingests nightly store inventory files (CSV on SFTP), near-real-time POS deltas (HTTPS), and a weekly master-data dump from SAP. Downstream: SQL Server (operational) and Salesforce Data Cloud (analytics). Files range from 10k to 20M rows. Duplicate SKUs across files are common. Ops needs email alerts and a success/failure record store.

**Must cover**

- Ingestion APIs vs file listeners vs scheduler vs HTTP kickoff
- Validation vs persistence split (batch steps, `ONLY_FAILURES`)
- Idempotency keys (`SKU + StoreId + Timestamp` vs file checksum + row number)
- Partial failure: 99% good rows, 1% poison
- Replay: reprocess a file without double-counting
- Fan-out to two databases with different SLAs

**Twists (pick one)**

- SFTP is flaky; files can be truncated mid-write.
- Two stores send overlapping files 15 minutes apart with conflicting quantities.
- Legal requires PII fields never to land in logs or Object Store.

**Strong answer sketch**

- Treat file arrival as a **job**: HTTP/scheduler starts a flow, reads with **streaming**, assigns `batchId`.
- Batch job: validate → aggregate → bulk insert success path; failure step writes reject table.
- Watermark / processed-file registry (checksum + name + size + mtime) before delete/archive.
- Last-write-wins or event-time vs processing-time policy for conflicts.
- Notifications on job terminal state, not per-record email.

---

### Scenario B — Customer 360 Experience API

**Prompt.** Mobile and web need a single `GET /customers/{id}` that composes Salesforce CRM, SAP billing, and a loyalty microservice. p95 &lt; 400 ms. Loyalty is optional. SAP is slow (p95 1.2 s). 5k RPS peak.

**Must cover**

- Experience vs Process vs System APIs and caching layers
- Parallel scatter-gather vs sequential; timeout and partial response
- Circuit breaker / until-successful vs fail-fast
- Cache keys, TTL, stampede, PII in HTTP caching
- Autoscale vs reserved vCores; rate limiting at API Manager

**Twists**

- Salesforce API limit is 100k calls/day.
- GDPR: right-to-erasure must invalidate cache in &lt; 60 s.
- A new channel (IVR) needs a **subset** of the same graph.

---

### Scenario C — Order orchestration (saga)

**Prompt.** Place order: reserve inventory (WMS), authorize payment (PSP), create Salesforce order, notify warehouse. Any step can fail. Design Process API + async workers.

**Must cover**

- Orchestration vs choreography; why Mule as orchestrator
- Compensating transactions (release stock, void auth)
- Idempotent consumers; `Idempotency-Key` on Experience API
- Anypoint MQ vs JMS vs Kafka; poison messages and DLQ
- Outbox pattern if Salesforce is down for 2 hours

**Twists**

- Payments team forbids storing PAN; only tokens.
- Warehouse API is not idempotent (double reserve on retry).
- Need human approval for orders &gt; $50k (wait state).

---

### Scenario D — Partner B2B / EDI + REST hybrid

**Prompt.** 200 retail partners. Some send AS2/EDI 850, some REST JSON, some SFTP CSV. All must become internal canonical orders. SLAs: REST 2 s, files “same business day.”

**Must cover**

- Partner isolation (API Manager contracts, client IDs, IP allowlists)
- Canonical data model vs per-partner Experience APIs
- Schema versioning and additive vs breaking changes
- Malformed EDI: quarantine vs auto-repair
- Throughput isolation so one partner cannot starve others

**Twists**

- A partner replays yesterday’s file plus today’s.
- Need non-repudiation (signed payloads, audit trail 7 years).

---

### Scenario E — Event backbone for domain events

**Prompt.** Salesforce Platform Events, SAP IDocs, and a custom Kafka cluster must drive a “customer changed” process that updates three systems. Some consumers need ordered events per customer; others want at-least-once fan-out.

**Must cover**

- Ordering keys vs partition / queue grouping
- Dedup store (Object Store partition vs Redis vs DB unique constraint)
- Replay from Salesforce vs Mule persistence
- Poison event handling without blocking the partition
- Schema registry / RAML vs AsyncAPI

**Twists**

- A consumer is down for 12 hours; lag and catch-up strategy.
- Exactly-once into a system that only offers at-least-once APIs.

---

### Scenario F — Hybrid integration with locked-down SAP

**Prompt.** SAP lives in a corporate DC. MuleSoft is mostly CloudHub 2.0. No inbound from internet to SAP. Design connectivity, HA, and a nightly 2M-row extract.

**Must cover**

- VPN / TGW / Private Space / RTF vs Mule as a local bridge
- HAPROXY / load balancer and clustering semantics
- Large extract: pagination, CDC vs full dump, disk vs streaming
- Secrets: Anypoint Secrets Manager vs encrypted YAML vs HashiCorp
- Blast radius if the VPN drops mid-batch

**Twists**

- Active-active two DCs for SAP.
- Change freeze: you cannot install a Mule runtime next to SAP.

---

### Scenario G — Multi-tenant SaaS integration layer

**Prompt.** Your product embeds MuleSoft to sync each tenant’s Salesforce org. 2,000 tenants, noisy neighbor problem, per-tenant credentials, per-tenant rate limits.

**Must cover**

- One app many tenants vs app per tenant vs domain-based tenancy
- Secure config and credential isolation
- Fair scheduling of batch jobs
- Observability: logs must not leak tenant A data to tenant B support
- Deploy strategy: CH2 replicas vs RTF vs customer-hosted

---

## 3. Deep-dive probes (use after the sketch)

### Reliability and failure

1. **On-error-continue vs propagate.** When does continue hide a failed batch? Design a global error handler taxonomy (HTTP, DB, FTP, EMAIL).
2. **Until-successful vs reconnection.** Connector reconnection vs application-level retry. How do you avoid retry storms against Salesforce?
3. **Redelivery.** HTTP listener vs MQ ack. What is “processed” if the worker dies after DB commit but before ack?
4. **Poison records.** `maxFailedRecords`, `acceptPolicy`, and a reject table. How do you redrive only rejects?
5. **Timeouts.** HTTP listener timeout vs max aggregation time vs batch timeout. Which one fires first on a 20M-row file?

### Data and batch

6. **Batch job internals.** Input phase, process, on-complete. What is persisted to the default batch store? Implications for CloudHub workers and restart.
7. **Aggregator size.** Trade-off between JDBC round-trips and memory. How do you choose block size vs aggregator size for SQL Server bulk insert?
8. **Watermarks.** Object Store last-run timestamp vs DB control table. Clock skew, DST, and duplicate windows.
9. **Canonical model.** Who owns SKU identity if POS, SAP, and e-comm disagree?
10. **DataWeave.** Streaming `deferred=true` vs `output application/java`. When does mapping to JSON explode memory?

### APIs and contracts

11. **API Manager.** SLA tiers, spike arrest, OAuth 2.0 vs client credentials vs JWT. Where does policy run vs where does Mule app run?
12. **Versioning.** URL vs header vs RAML overlay. How do two Experience versions share one Process API?
13. **Idempotency.** `POST /orders` with `Idempotency-Key`. Store: Object Store TTL vs DB unique index. What is the TTL vs business “duplicate window”?
14. **Pagination and filtering.** System API wraps Salesforce SOQL. How do you prevent Experience APIs from issuing unbounded queries?
15. **Graph vs coarse resources.** When is a BFF Experience API better than a generic Process API?

### Scale and performance

16. **Worker sizing.** vCore, clustering, and persistent queues. When does adding workers **worsen** SFTP file processing?
17. **Backpressure.** Slow DB, fast HTTP. HTTP 429 vs internal queue. How do you shed load at the edge?
18. **Connection pools.** DB pool vs HTTP max connections vs Salesforce connector. What metric tells you the pool is the bottleneck?
19. **Cold start / deploy.** Zero-downtime deploy with in-flight batch jobs. Drain vs abort.
20. **Multi-region.** Active-active CloudHub regions. Sticky sessions, Object Store locality, and MQ.

### Security and compliance

21. **Secrets.** Encrypted `secure-config.yaml` vs properties vs Secrets Manager. Rotation without restart.
22. **TLS.** Mutual TLS to SAP PI. Cert expiry operational design.
23. **PII.** Masking in logs (`log4j` patterns), correlation IDs vs customer IDs, field-level encryption.
24. **Least privilege.** Separate SFTP users for read vs archive vs delete. Separate DB roles for success vs reject tables.
25. **Threat model.** Partner uploads a 50 GB “CSV” or a zip bomb. Limits at API Manager, HTTP listener, and file connector.

### Observability and operations

26. **Correlation.** `correlationId` vs custom `batchId`. How do you stitch Anypoint Monitoring, Splunk, and Salesforce debug logs?
27. **SLIs.** Ingestion freshness, error rate, lag. Alert on symptoms (lag) not causes (CPU).
28. **Replay runbook.** Operator reprocesses file `inventory_2026-09-08.csv`. What buttons exist? What is forbidden?
29. **Config per env.** `dev` / `test` / `prod` YAML. How do you prevent prod SFTP creds in a non-prod worker?
30. **Notification design.** Email on every error vs digest vs PagerDuty. How do you avoid 10k emails from one bad file?

### Platform and SDLC

31. **CICD.** Design a pipeline: MUnit, Exchange, API Manager promotion, CH2 deploy, secret injection.
32. **Exchange.** When is a connector vs a REST System API vs a shared DataWeave module the right reuse unit?
33. **MUnit vs contract tests vs consumer-driven contracts.** What belongs in each layer for a Process API?
34. **Autodiscovery.** Binding an API Manager instance to a Mule app. What happens if autodiscovery fails at boot?
35. **License and limits.** Throughput, vCore, MQ message size, Object Store TTL. Design within a **fixed** 4 vCore budget.

---

## 4. Architecture comparison questions

Ask for a **recommendation and a rejected alternative**.

| # | Question | What “good” sounds like |
|---|----------|-------------------------|
| 1 | CloudHub 2.0 Private Space vs RTF for SAP RFC | Network path, ops ownership, patching, burst scale |
| 2 | Anypoint MQ vs Kafka vs JMS (IBM MQ) | Ordering, retention, ops, Mule connector semantics |
| 3 | Batch job vs foreach + VM queue vs scheduler + pagination | Memory, restart, parallelism, observability |
| 4 | Salesforce Composite API vs Bulk API 2.0 vs CDC | Limits, latency, volume, reconnection |
| 5 | Experience API cache vs CDN vs Salesforce Platform Cache | Consistency, PII, invalidation |
| 6 | Process API orchestration vs event choreography | Debuggability vs coupling |
| 7 | Store canonical IDs in Mule Object Store vs MDM | Durability, query, multi-worker |
| 8 | File-based integration vs API-first for a legacy WMS | Partner capability, SLAs, error handling |

---

## 5. “Design this API” micro-prompts (10–15 minutes)

Good as a second round or take-home sketch.

1. `POST /ingestion/jobs` — kick off CSV ingest; return job status resource.
2. `GET /inventory/{sku}?storeId=` — real-time vs cached; stale-while-revalidate.
3. Webhook receiver for Salesforce Outbound Messages (retries, duplicates, 20s timeout).
4. Partner bulk API: upload 10 MB JSON, async result location, signed download URLs.
5. Internal `POST /compensations/release-stock` used only by the saga worker.
6. Health and readiness: what should `/ready` check (DB, MQ, SFTP) vs `/live`?

Require: RAML/OAS sketch, error model, idempotency, authn/z, and rate limits.

---

## 6. Failure-injection table (use live in the interview)

After they draw the diagram, walk down the table: “What happens? How do we detect? How do we recover?”

| Failure | Detect | Recover |
|---------|--------|---------|
| SFTP file still being written | Size stability / done file / lock | Wait + retry; do not delete |
| Worker killed mid-batch | Incomplete job in control table | Resume vs restart from watermark |
| DB unique-key violation on replay | Constraint vs app-level upsert | Idempotent upsert; no alert storm |
| Salesforce 401 after secret rotation | Auth error class | Refresh token path; pause workers |
| MQ poison JSON | Retry count / DLQ | Quarantine API + replay tool |
| Partner sends UTF-16 CSV labeled UTF-8 | Parse errors spike | Reject file; notify with encoding hint |
| Clock jump (DST) on watermark | Duplicate or gap in extracts | Store watermark in source sequence, not wall clock |
| Email connector down | Alert channel itself failed | Secondary Slack/PagerDuty; do not fail the batch |

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

---

## 8. Candidate take-home (optional)

**Brief.** Design (doc + diagram, no code required) a Mule 4 service that:

1. Accepts an HTTP start signal.
2. Reads a streamed CSV from SFTP.
3. Validates rows; writes good rows and bad rows to different DB tables in bulk.
4. Emails a summary (not per row).
5. Is safe to retry.

**Deliverables.** Context diagram, sequence for one file, data model for job + reject, failure table, capacity estimate for 20M rows, and a list of Anypoint components (MQ, API Manager, secrets) you would add if this became a platform.

This maps to a typical **ingestion batch pipeline** (HTTP kickoff, streamed CSV, batch steps with success/failure aggregators, DB bulk write, global error handler, email notification).

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

## Appendix — Follow-ups keyed to a file-based batch ingest

If the discussion is a **CSV → validate → SQL Server / Data Cloud → notify** pipeline, these follow-ups are high-yield:

1. Why HTTP listener to start a batch instead of only an SFTP listener? (ops control, auth, avoid partial-file reads)
2. Why `blockSize=1` with aggregators vs larger batch blocks?
3. How do you bound aggregator size so JDBC batches stay under packet/timeout limits?
4. Where is `batchId` generated and how does it appear in success, reject, logs, and email?
5. `on-error-propagate` for DB/SFTP vs `on-error-continue` for email — why?
6. What happens if validation uses a sub-flow that throws — which batch step sees the record?
7. How do you archive or delete the SFTP file only after **both** sinks acknowledge?
8. How would you add a second region without processing the same file twice?
9. How do you test a 20M-row file in MUnit without checking it in?
10. If Data Cloud JDBC is slower than SQL Server, do you dual-write in one transaction, fork with MQ, or ingest SQL first and CDC to analytics?
