# MuleSoft System Design Q&A (plain English)

This is a **question-and-answer guide** for MuleSoft architect / senior integration interviews.

It is written in everyday language first. Technical names are added only after the idea is clear.

**How this was built**

- **Job openings** (typical 2025–2026 architect/engineer JDs): Accenture MuleSoft Architect, Application Integration Architect (Anypoint), MuleSoft Integration Architect (India and US), Integration Engineer roles. They keep asking for: API-led design, Salesforce/SAP/database/file connections, CloudHub or hybrid, OAuth and API Manager, batch and messaging, CI/CD, monitoring, and explaining design to business people.
- **Past interview questions** reported by candidates and trainers: “design customer sync,” “50k SFTP files,” “order flow,” “notification hub,” “wrap a mainframe,” “make it fault-tolerant,” “design the whole platform,” plus TCS/consulting screens on CloudHub vs Runtime Fabric, Object Store, async processing, and API-led layers.
- **This repo’s real work:** a nightly-style **file ingest** (HTTP start → SFTP CSV → validate → database → email summary). Several answers use that as the example so the guide matches real Mule 4 batch work.

Use **one design story** in a 45–60 minute round. Use the short Q&A for screens.

---

## 1. What these jobs actually want

Hiring managers are not asking you to recite RAML. They want someone who can:

| Job-ad phrase | What they mean in plain words |
|---------------|-------------------------------|
| API-led connectivity | Do not wire Salesforce straight to the mobile app. Put reusable “doors” in between. |
| Experience / Process / System APIs | Front door for each channel; kitchen that cooks the business process; back door to each old system. |
| HLD / LLD | Big picture for leaders, then a detailed flow for builders. |
| CloudHub / Runtime Fabric / hybrid | Where the app runs: MuleSoft’s cloud, your Kubernetes, or next to SAP in the data center. |
| OAuth 2.0, JWT, API policies | Who is allowed in, and how you stop one partner from flooding you. |
| Batch, SFTP, Salesforce, SAP, DB | The actual systems you will touch every week. |
| Anypoint MQ / JMS / Kafka | A waiting line so you do not do heavy work while the user is still on the phone. |
| CI/CD, MUnit, Exchange | Ship safely, test, and reuse instead of copying flows. |
| Monitoring, HA, performance | When it breaks at 2 a.m., can ops see it and can it survive one machine dying? |

If you only talk connectors, you sound like a developer. If you only talk layers and never mention retries, files, or Salesforce limits, you sound like a slide deck. **Jobs want both.**

---

## 2. Simple words for MuleSoft ideas

| Fancy word | Layman meaning |
|------------|----------------|
| **API** | A documented way for one program to ask another for data or to do a job. |
| **System API** | A polite wrapper around one system (Salesforce, SAP, SQL). Others should not speak SAP dialect. |
| **Process API** | The business recipe: “place an order,” “sync a customer.” |
| **Experience API** | The shape mobile / web / partner needs. Same process, different packaging. |
| **Synchronous** | Wait on the line until the answer comes back. |
| **Asynchronous** | Take a ticket, hang up, we text you when done. |
| **Queue (Anypoint MQ)** | A numbered waiting line. Workers pick items when they are free. |
| **Idempotent** | Doing the same request twice does not charge the card twice. |
| **Watermark** | A bookmark: “we already processed up to this invoice number.” |
| **Dead letter / reject table** | The junk drawer for records that keep failing, so they do not block everyone else. |
| **Object Store** | A small sticky-note pad. Fine for a bookmark or a short-lived “already seen” flag. **Not** a bank ledger or a queue. |
| **vCore / worker** | How much computer MuleSoft rents for your app. |
| **CloudHub** | MuleSoft hosts the computers. |
| **Runtime Fabric (RTF)** | You host the computers (often in your data center). |
| **API Manager policy** | A bouncer at the door: login check, speed limit, block bad IPs. |
| **Batch job** | Chop a huge file into rows, process in chunks, keep good and bad rows apart. |
| **Streaming** | Read the file like a tap, not like dumping a swimming pool into memory. |

---

## 3. Short Q&A from job screens and past interviews

These show up in **TCS / Accenture / product** screens and in “my 12 MuleSoft interviews” write-ups. Answer in two layers: **simple**, then **if they go deeper**.

---

### Q1. What is API-led connectivity, and when would you skip a layer?

**Simple answer.**  
Think of a restaurant. **System APIs** are the suppliers (farm, bakery). **Process APIs** are the kitchen (the recipe). **Experience APIs** are the waiters (mobile app, partner portal, call center each get a different plate). If every waiter walks into the farm, you cannot change the farm without breaking the app.

**Skip a layer when** there is only one consumer and one system for the next year, or it is a one-off nightly file with no other callers. Do not skip layers just to save a little hosting cost if three channels will share “create order.”

**Jobs ask this because** every architect JD lists Experience / Process / System.

---

### Q2. Sync vs async: a partner dumps 50,000 invoices at 9 a.m.

**Simple answer.**  
Do not cook 50,000 invoices while they wait on the phone. The public API should only say: “We got your bundle. Here is ticket **#B-123**. Check status here.” Heavy work happens in a waiting line.

**Deeper.** Return HTTP **202**. Save a job record. Put work on a queue. Status API: `GET /jobs/B-123`. Same ticket id in logs.

**Past question source.** High-volume ingest and “how would you implement asynchronous processing” (common consulting screen).

---

### Q3. CloudHub vs Runtime Fabric vs on-prem. Where do you put what?

**Simple answer.**

- **Public bursty APIs** → CloudHub (easy to add machines).
- **SAP locked in the office, no inbound internet** → private network to CloudHub, **or** a small Mule next to SAP that only talks **out** to a queue.
- **Card numbers (PCI)** → keep that data in a locked room (RTF/on-prem) and send only tokens to the cloud.
- **Nightly 2-hour file job** → a dedicated worker so it does not slow the mobile API.

**Jobs ask this because** JDs list CloudHub, RTF, and hybrid in the same bullet.

---

### Q4. Object Store vs queue vs database?

**Simple answer.**

- **Queue:** “please process this event.”
- **Database:** “this payment id is the truth; do not insert twice.”
- **Object Store:** “we last ran at bookmark X” or “we saw this key in the last day.”

If you use Object Store as a queue, notes expire, you cannot inspect a backlog easily, and two workers will fight. Money and audit never live only on sticky notes.

**Past question:** “Explain the use of Object Store” (Hirist / product screens).

---

### Q5. How do you handle a huge CSV (gigabytes) without crashing?

**Simple answer.**  
Read it like a **stream** (row by row). Validate each row. Write **good rows** to one table in small groups. Write **bad rows** to a reject table. Email **one summary**, not 20,000 emails.

Memory explodes if you turn the whole file into one giant JSON list in RAM.

**Past question:** “Bank receives tens of thousands of files / high-volume file processing.” Also matches this repo’s ingest pipeline.

---

### Q6. On Error Continue vs Propagate?

**Simple answer.**

- **Propagate** = the dish is ruined; send it back to the kitchen (the record fails). Use for database and file failures.
- **Continue** = the side salad failed; the main meal is still served. Use for “we could not send the email” **after** data is already saved.

If you Continue on a failed database insert, the batch **looks successful**. That is a lie.

---

### Q7. How do you secure APIs? (every JD)

**Simple answer.**  
Bouncer at the gate (**API Manager**): client id, OAuth, speed limit, IP allow list. Inside the restaurant: still check “this user may see **this** customer.” Passwords live in a secret vault, not in the project file. Logs show a **tracking id**, not the customer’s email or card.

---

### Q8. How do you keep the system up? (HA / scale)

**Simple answer.**  
Run **two copies** of each important API so one can die. Do not store “who is logged in” only in one machine’s memory. For files, **do not** let two copies grab the same file — first **claim** it in a table (like taking a number).

Adding machines **hurts** SFTP if both delete the same file.

---

### Q9. Salesforce has a daily API limit. Mobile needs fast customer view.

**Simple answer.**  
Do not call Salesforce on every screen refresh. Keep a **local copy** (cache or small database) filled by Salesforce events. Mobile reads the copy. Save Salesforce calls for writes and rare repairs.

**Past question:** real-time customer sync + “design for scale.”

---

### Q10. CI/CD — what does “good” look like on a JD?

**Simple answer.**  
Build → automated tests (MUnit) → deploy to dev with **dev** secrets → promote the API contract → prod with **prod** secrets. Never copy production SFTP passwords into a developer laptop config.

---

## 4. The seven system design stories interviewers keep using

These seven match a widely circulated **MuleSoft system design** set (customer sync, big files, orders, notifications, legacy wrap, fault tolerance, enterprise platform). Answers are in layman language. Each one maps to bullets on architect JDs.

How to answer any of them in 10 minutes:

1. Restate the goal and who waits (human vs overnight job).  
2. Draw boxes: channel → process → each system.  
3. Say what is **wait-on-the-phone** vs **ticket**.  
4. Say what happens when a step fails.  
5. Say how ops **replays** without doubling money or stock.

---

### Design 1 — Real-time customer sync (Salesforce → SAP, warehouse, analytics)

**The story.** A customer is created or updated in Salesforce. SAP, a warehouse app, and a reporting system must catch up.

**Layman design.**

- Salesforce shouts “customer changed” (platform event or similar).
- Mule **System API** for Salesforce only knows Salesforce.
- A **Process** “customer sync” turns that into a common “customer” shape.
- Three **System APIs** update SAP, warehouse, analytics. Do **not** put SAP field names in the Salesforce listener.

**If Salesforce is down or slow.** Put events on a **queue**. Bookmark Salesforce’s last event so you can replay. If analytics can wait an hour, do not block SAP on analytics.

**Duplicates.** Same customer update may arrive twice. Upsert by customer number. Database unique key beats “hope the queue is exactly once.”

**Job link.** Salesforce integration is on almost every senior JD.

---

### Design 2 — High-volume files (SFTP, tens of thousands of rows or files)

**The story.** A bank or retailer drops CSV files. Validate, keep failures aside, load the rest.

**Layman design.** (Same idea as this repo.)

1. Do not start while the file is still uploading. Wait for a “done” file, or start from a **button/API** that ops controls.  
2. Give the run a **job id** (a ticket).  
3. Read as a stream.  
4. Good rows → database in bunches. Bad rows → reject table with the reason.  
5. One email: “12,000 loaded, 80 rejected, job B-123.”  
6. Move the file to an archive **only after** the database write is done.  
7. Replay is safe because you **update if the row already exists**, or you skip a file with the same fingerprint (checksum).

**If two stores send conflicting stock.** Believe the **newer timestamp inside the file**, not “whoever arrived last in the inbox.”

**Job link.** Batch, SFTP, database connectors, error handling, notifications.

---

### Design 3 — Order from website: stock, pay, ERP, notify

**The story.** Website places an order. Check stock, take payment, create order in ERP/Salesforce, email the customer.

**Layman design.**

- Website talks to an **Experience** API: “place order,” with a **repeat-safe key** (if they double-click, one order).
- Save “we intend to place this order” in **your** database first (the notebook).
- Then, in order: reserve stock → pay (token, never raw card) → create in ERP → notify.
- If pay works and ERP is down, **do not forget** the order. Put “create in ERP” on a queue and retry. That notebook pattern is an **outbox**.

**If stock API is not repeat-safe.** Keep your own “we already reserved for order 99” row. On retry, skip a second reserve.

**If the amount is huge.** Pause for a human “approve” instead of taking money immediately.

**Job link.** Process orchestration, Salesforce/ERP, async, security.

---

### Design 4 — One notification hub (email, SMS, Teams, Slack)

**The story.** Every app wants to send messages. You do not want 20 copies of the email connector.

**Layman design.**

- One Process API: `POST /notifications` with “who, what, which channel.”
- A small routing table: order-failed → email + PagerDuty; marketing → SMS.
- Each channel is a System API (email, SMS).
- If email is down, **do not fail the batch that already loaded data**. Log and use a backup channel for ops.

**Job link.** Reusable assets, Exchange, not point-to-point.

---

### Design 5 — Wrap a legacy mainframe / SOAP / files for mobile

**The story.** Mobile needs REST. The mainframe only speaks old SOAP or files.

**Layman design.**

- **System API** talks the old dialect. Mobile never sees SOAP.
- **Experience API** is REST/JSON, paginated, fast timeouts.
- If the mainframe is slow, **do not** wait on the mobile call. Offer a cached copy or “we will notify you.”
- Replace the mainframe later by swapping the System API guts; the mobile contract stays. That is the “strangler” idea: wrap first, replace slowly.

**Job link.** Legacy modernization on almost every architect JD.

---

### Design 6 — Fault-tolerant integration

**The story.** “What if Salesforce or the network dies?”

**Layman checklist** (say this out loud):

| Problem | What you do |
|---------|-------------|
| Blip (timeout) | Retry a few times, wait longer each time, do not retry “bad request.” |
| Salesforce melting | Stop calling for a while (**circuit breaker**), queue work. |
| Poison message | After N failures, park it in the junk drawer; do not block all customers. |
| Worker dies after save, before ack | Database unique key so retry does not double. |
| You deploy at noon | Finish or safely restart jobs; do not lose the file claim. |
| Ops needs to see it | One tracking id from the app to Splunk to Salesforce. |

**Past question.** “Design a fault-tolerant architecture” and error-handler drills (`HTTP:TIMEOUT` vs connectivity vs catch-all).

---

### Design 7 — Enterprise-wide MuleSoft platform (the “CoE” question)

**The story.** “We have 200 projects. Design the platform.”

**Layman design.**

- **Rules:** every new connection is an API in the catalog (Exchange), not a secret flow on someone’s laptop.
- **Three layers** as the default; exceptions need a one-pager.
- **One way to log, one way to name errors, one way to store secrets.**
- **Environments:** dev / test / prod with different passwords.
- **Bouncer policies** copied as a template (OAuth + rate limit).
- **Pipeline** so humans do not click deploy in production on Friday.
- **Center of excellence:** office hours, reusable DataWeave libraries, “you may not call SAP from an Experience API” as a reviewed rule.

**Job link.** Accenture/Matrix JDs: standards, reusable assets, stakeholder communication, governance.

---

## 5. Extra design Q&A taken from architect job ads

These are the remaining JD themes that the “famous seven” do not cover well.

---

### Q. SAP is in the data center. MuleSoft is in the cloud. No inbound internet to SAP.

**Answer.** SAP should never be a public website. Build a private road (VPN) into a private CloudHub space, **or** run a small Mule beside SAP that only **pushes** data out to a queue in the cloud. Nightly extract: page through records, save a **bookmark**, if the VPN drops resume from the bookmark — do not start the 2 million rows from zero.

---

### Q. Two databases: operations SQL Server and analytics (e.g. Data Cloud). Same file.

**Answer.** Pick **one** system as the live stock number (SQL). Send analytics a copy through a queue. Do not try to write both in one “all or nothing” database transaction. Analytics can be late; the store cannot.

---

### Q. 2,000 customers of your SaaS, each with their own Salesforce.

**Answer.** One Mule app, many tenants, credentials in a vault per tenant. A fair scheduler so one noisy customer cannot eat all Salesforce calls. Logs always include tenant id, never mix data in support tools.

---

### Q. How do you version APIs?

**Answer.** Partners like `/api/v1/` in the URL. You can add new fields without a new version. Removing a field means `v2` and a sunset date. Two mobile versions can share the same Process API underneath.

---

### Q. What do `/live` and `/ready` mean?

**Answer.** **Live:** the process is up. **Ready:** it can take work (database reachable). A batch worker that cannot see SFTP should not claim to be ready. A mobile API should stay ready even if SFTP is down.

---

## 6. Talk-track for a 60-minute round (file ingest)

Jobs that mention **batch + SFTP + database + alerts** love this story. Use it if they say “design a pipeline.”

| Time | What you say (plain) |
|------|----------------------|
| 0–5 | Three layers in one sentence. Cloud vs on-prem in one sentence. |
| 5–25 | Ticket (job id) → wait until file is complete → stream CSV → good table / reject table → one email. |
| 25–35 | Partial file: wait for “done.” Two files disagree: newer timestamp wins. |
| 35–45 | Repeat-safe writes. Email failure does not undo the load. |
| 45–55 | Two machines must not steal the same file. Do not hold the HTTP call for 20 million rows. |
| 55–60 | Top risks: duplicate load, memory, analytics vs operations SLA. MVP this quarter vs platform next year. |

**They should hire you if** you mention a job ticket, a reject pile, a safe replay, and secrets.  
**They should not** if you only draw connectors and say “we will add more workers.”

---

## 7. Mini API answers (they often ask you to sketch)

**Start a file job**  
`POST /ingestion/jobs` → “Accepted, job B-123.” Then `GET /ingestion/jobs/B-123` for counts. Login required. If the same file is already running, say “conflict.”

**Get stock for a SKU**  
Read the **database**, not SFTP. Cache for half a minute. Private cache (this is store data, not a public CDN).

**Salesforce outbound message**  
Salesforce only waits ~20 seconds. Save the message and return OK. Process SAP **after**. Salesforce will retry — use the notification id so you do not double-apply.

**Health**  
Live = process up. Ready = dependencies this app needs.

---

## 8. Strong vs weak (one page)

| Topic | Strong (say this) | Weak (avoid) |
|-------|-------------------|--------------|
| 50k invoices | Ticket + queue | One HTTP call does all 50k |
| Two sinks | SQL is truth; analytics gets a copy | One giant transaction to both |
| Object Store | Bookmark / short memory | Use it as a queue or as money records |
| Retries | A few times, then park | Retry forever |
| Errors | Reject table + one digest | Email per bad row |
| Scale | Claim each file | Two workers, same file |
| SAP | Private path | SAP on the public internet |
| “Exactly once” | Database unique + upsert | “The queue guarantees it” |
| Salesforce GET | Read a copy | Hit Salesforce 5,000 times a second |
| Secrets | Vault per environment | Password in the git repo |

---

## 9. Sources (for you, not to quote in the interview)

**Job openings (themes, not one company):** MuleSoft Architect / Integration Architect ads asking for Anypoint, API-led HLD/LLD, CloudHub or RTF, OAuth/JWT, Salesforce/SAP/DB/files, MQ/JMS, CI/CD, monitoring, client-facing design.

**Past question sets:** system-design lists used in MuleSoft interviews (customer sync, high-volume SFTP, order orchestration, notification framework, legacy wrap, fault tolerance, enterprise platform); consulting screens on API-led layers, Object Store, CloudHub vs RTF, async; candidate write-ups that stress “say why, not only what,” error types, and CloudHub 2.0 vs 1.0 honesty.

**Local project:** HTTP-started CSV ingest, streamed read, batch validate, success/fail aggregators, database, global error handler, email on complete.
