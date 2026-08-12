# CloudHub 2.0 deployment and CI/CD

## Why CloudHub 2.0 (not 1.0, not RTF) for this hub

| Option | When we would choose it |
|---|---|
| **CloudHub 2.0** (this design) | Salesforce is SaaS; ERP is reachable over VPN/Private Space; we want managed runtime, replicas, and ingress without Kubernetes ops. |
| Runtime Fabric | Data residency, existing AKS/EKS, or ERP must stay on-prem with no CH networking. |
| Hybrid standalone | Legacy only; avoid for new work. |

CH 1.0 worker sizing (`0.1 vCore` VPC) is not the model here. CH 2.0 uses **replicas + Private Spaces**.

## Environments

`dev` → `test` → `prod`. Same JAR; properties from `${env}-config.yaml` plus secure properties.

Promotion: Git tag → pipeline deploys to test → CAB → prod. No Studio click-deploy to prod.

## Pipeline (GitHub Actions / Jenkins equivalent)

1. `mvn test` (MUnit) on PR.
2. `mvn package` produces four JARs.
3. Deploy with Connected App (Design Center / Maven plugin `deploy` to CH 2.0).
4. Smoke: Experience health + Postman collection against test.
5. On failure: do not promote; keep previous replica set.

Secrets: `CONNECTED_APP_CLIENT_ID`, `CONNECTED_APP_CLIENT_SECRET`, `SFDC_JWT_KEY` in GitHub Environment **prod** only.

## Salesforce limits in ops

- Alert if `Sforce-Limit-Info` DailyApiRequests > 70%.
- Bulk jobs only in the nightly window (01:00 org TZ).
- Process API circuit: after 5 consecutive Salesforce 503/429, fail fast 10 minutes (until-successful exhausted → `PRC-SFDC-OPEN-CIRCUIT`).

## Local vs prod connectors

| Concern | This repo | Production hardening |
|---|---|---|
| Salesforce access | HTTP REST + mock | Anypoint Salesforce Connector (CDC replay, Bulk job wait) |
| ERP | In-memory Object Store | SAP S/4 / JDBC / JMS |
| Idempotency store | Persistent OS | Redis / Object Store v2 with HA |
| Scheduler | HTTP-triggered bulk | Anypoint Scheduler + Runtime Manager |
