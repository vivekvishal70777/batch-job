# Inventory Data Migration Pipeline

Production Mule 4 application that migrates inventory records from a legacy SFTP CSV extract into SQL Server.

The job is **idempotent** (SKU + StoreId upsert), **restart-safe** (exclusive lock with TTL), and **operable** (health/readiness APIs, job audit, error quarantine, email alerts).

## What it does

1. Picks up `inventory.csv` from SFTP `inbox/` (HTTP trigger or nightly scheduler).
2. Validates every row (mandatory fields, type, quantity, timestamp).
3. Bulk-loads valid rows into `InventoryStaging`.
4. Merges staging into `InventoryTarget` on `(SKU, StoreId)`.
5. Writes invalid rows to `InventoryMigrationError` and exports them as CSV.
6. Archives the source file, records a job row, updates a watermark, and emails operations.

```
SFTP inbox/*.csv
        │
        ▼
 HTTP POST /api/v1/migration/jobs   or   cron scheduler
        │
        ▼
 acquire Object Store lock ──► MigrationJob (ACCEPTED/RUNNING)
        │
        ▼
 streaming CSV read ──► DataWeave map ──► Mule Batch
        │                                      │
        │                         valid ───────┴────── invalid
        │                            │                    │
        ▼                            ▼                    ▼
 SQL Server              InventoryStaging      InventoryMigrationError
                                │
                                ▼
                     MERGE InventoryTarget
                                │
                                ▼
              archive file + outbound CSV + email
```

## Project layout

| Path | Purpose |
|------|---------|
| `src/main/mule/` | Flows: API, scheduler, orchestrator, DB, SFTP, notifications |
| `src/main/resources/dwl/` | Shared DataWeave modules (validation, mapping, logging) |
| `src/main/resources/*-config.yaml` | Per-environment settings |
| `src/main/resources/*-secure-config.yaml` | Encrypted secrets |
| `src/main/resources/api/data-migration-api.raml` | HTTP contract |
| `sql/01-schema.sql` | Target schema, indexes, merge procedure |
| `src/test/munit/` | MUnit tests |
| `src/test/resources/sample/` | Valid and invalid CSV fixtures |

## API

Base path: `/api/v1` (port `8081` by default).

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness. Does not call SQL Server. |
| `GET` | `/ready` | Readiness. Pings SQL Server. `503` if down. |
| `POST` | `/migration/jobs` | Start a job. Returns `202 Accepted`. `409` if another job holds the lock. |
| `GET` | `/migration/jobs` | Last 20 jobs. |
| `GET` | `/migration/jobs/{jobId}` | Single job status. |

Trigger body (all fields optional):

```json
{
  "fileName": "inventory.csv",
  "dryRun": false
}
```

`dryRun: true` validates the file and records job stats without writing staging/target or archiving the source.

## Record rules

A row is valid only when all of the following hold:

- `SKU`, `StoreId`, `Type`, `Quantity`, and `Timestamp` are present
- `Type` is `Standard` or `Backorder`
- `Quantity` is a whole number between `0` and `999999999`
- `Timestamp` parses as one of: `yyyy-MM-dd'T'HH:mm:ss`, `yyyy-MM-dd HH:mm:ss`, `dd-MM-yyyy HH:mm:ss`, `MM/dd/yyyy HH:mm:ss`, `yyyy-MM-dd`

Invalid rows never reach `InventoryTarget`. They are stored and exported under `outbound/error/`. Duplicate `SKU` + `StoreId` rows in the same file keep the **last** occurrence.

## Database

Apply `sql/01-schema.sql` to the target SQL Server database before the first run.

| Table | Role |
|-------|------|
| `MigrationJob` | Run audit (status, counts, correlation id) |
| `InventoryStaging` | Transient load area, keyed by `JobId` |
| `InventoryTarget` | System of record, unique on `(SKU, StoreId)` |
| `InventoryMigrationError` | Quarantine for invalid rows |
| `MigrationFileAudit` | Processed file history |
| `MigrationWatermark` | Last successful job per entity |

Re-running the same SKU/StoreId **updates** the target row. That is the migration idempotency guarantee.

## Configuration

Set the Mule property `env` to `dev`, `test`, or `prod` (`-M-Denv=prod` or a CloudHub property). The matching `*-config.yaml` and `*-secure-config.yaml` are loaded.

The encryption key is **never** stored in Git. Pass it at runtime:

```text
-M-Dsecure.key=<key-used-with-the-secure-properties-tool>
```

Encrypt secrets with the [Mule Secure Properties Tool](https://docs.mulesoft.com/mule-runtime/latest/secure-configuration-properties) using algorithm `Blowfish` (same as `global-config.xml`).

Production host names in `prod-config.yaml` are placeholders. Override them in Runtime Manager:

- `database.sqlserver.host` / `user` / `name`
- `sftp.host` / `username`
- `email.smtp.host` / `user`
- `email.notification.from-address` / `to-address`

## Local run (Anypoint Studio or Maven)

1. Apply `sql/01-schema.sql`.
2. Place `inventory.csv` in the SFTP inbox.
3. Provide `secure.key`.
4. Run the application with `env=dev`.
5. `POST http://localhost:8081/api/v1/migration/jobs`

```bash
mvn clean package -DskipTests
# Deploy the jar from target/ to a Mule 4.9 / Java 17 runtime
```

MUnit (requires the same `secure.key` so connectors can resolve encrypted passwords):

```bash
mvn clean test -Dsecure.key=<key>
```

## CloudHub

- Runtime: Mule `4.9.0`, Java `17`
- Object Store v2: enabled (used for the migration lock)
- Workers: 1 vCore is enough for typical nightly files; raise `batch.max-concurrency` and the DB pool if files are large
- Properties to set in Runtime Manager: `env`, `secure.key`, plus any prod overrides listed above
- Map CloudHub HTTP port with `http.listener.port=8081` or the platform `http.port` convention used by your target

The scheduler is controlled by `scheduler.enabled` and `scheduler.cron` (default `0 0 4 * * ?` Asia/Kolkata in dev).

## Operations

- **Overlap protection:** Object Store key `inventory-migration-lock` with TTL (`migration.lock-ttl-minutes`). A second trigger returns HTTP 409. A crashed worker releases the lock when the TTL expires.
- **Partial success:** Job status `PARTIAL` when some rows fail validation. Target still receives the valid subset. Error CSV is written for replay.
- **Replay:** Drop a corrected CSV into `inbox/` and trigger again. Upsert overwrites existing SKU/StoreId rows.
- **Dry run:** `POST` with `"dryRun": true` to measure valid/invalid counts without loading or archiving.
- **Alerts:** Start, completion, and failure emails. Email send failures are logged and do not fail the job (avoids retry loops).

## Logging

Every log line includes timezone, job id, flow name, and phase. CloudHub console and rolling file appenders both include the Mule `correlationId` MDC value (set to the job id).

## CI

GitHub Actions validates XML, YAML, required files, and the inventory validation contract (see `scripts/`). Full MUnit execution needs a Mule EE runtime and the secure properties key.
