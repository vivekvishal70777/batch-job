# Inventory Data Migration Pipeline

Mule 4 application that migrates inventory CSV extracts from SFTP into SQL Server.

- Idempotent upsert on SKU + StoreId
- Staging → MERGE → target with reconciliation
- HTTP operations API and nightly scheduler
- Validation quarantine, file archive, and email alerts

See the project README for APIs, schema, and deployment.
