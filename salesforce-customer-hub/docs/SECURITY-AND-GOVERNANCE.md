# Security and API governance

Intended for API Manager + C4E review. Policies are documented here because they are applied on the gateway, not in the Mule XML.

## Trust boundaries

| API | Exposure | Authn | Authz |
|---|---|---|---|
| Experience | Public / partner | OAuth 2.0 (Okta / Salesforce as IdP) | Client ID + SLA tier |
| Process | Private Space only | Client ID enforcement (machine) | IP allowlist from Experience + ops |
| SFDC System | Private Space only | Client ID | Process app only |
| ERP System | Private Space only | Client ID | Process app only |

Experience is the only API registered as a product in Exchange for external consumers.

## API Manager policies (Experience)

1. **OAuth 2.0 token enforcement** — JWT validation, audience = Experience API.
2. **Client ID enforcement** — Connected Apps per consumer (Portal, Mobile, Partner).
3. **SLA / rate limiting** — Portal 100 rps, Mobile 50 rps, Partner 10 rps.
4. **Spike control** — 20 rps burst to protect Salesforce daily API limits.
5. **CORS** — portal origins only.
6. **Header injection** — require `X-Correlation-Id` or generate at gateway.

## Salesforce Connected App

Production: **JWT bearer** (server-to-server). No stored user password.

- Certificate in CH 2.0 secret store.
- User is an integration user with **API Only**, minimum Account/Contact/Case CRUD, Bulk API, View All Fields as required.
- IP restrictions on the Connected App to the Private Space egress.

Local/dev: `salesforce.mode=mock` — no Connected App.

## Data

- Email and phone are PII. Logs mask `primaryContact.email` and `phone` (DataWeave `replace` in logger payloads).
- No full Account payloads in INFO logs; DEBUG only in non-prod.
- TLS 1.2+ to Salesforce and ERP.

## C4E standards this repo follows

- RAML 1.0 in `/src/main/resources/api` per app (publish to Exchange in real C4E).
- HTTP status from `vars.httpStatus`; never hard-code success in error handler.
- Custom error types `CUSTOM:*` mapped once in `error-handler.xml`.
- No Salesforce `__c` fields above System API.
- Shared libraries in production would be an Exchange fragment (`common-error-lib`). Duplicated here so each app is independently deployable.
