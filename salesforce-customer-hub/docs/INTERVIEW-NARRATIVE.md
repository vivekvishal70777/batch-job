# Interview narrative (20 minutes)

Use this as the oral walkthrough. Do not open Studio unless asked.

## 1. Design (5 min)

“I treated Salesforce as system of record for relationship data and ERP for billing identity. Experience is a portal contract. Process owns the canonical customer and is the only layer that calls two systems. Salesforce System API hides Composite, SOQL, Bulk, and OAuth. That split is what I would put on an HLD for C4E.”

Be ready: *Why not one app?*  
“Independent scale and blast radius. Bulk reconcile should not starve portal GETs. Salesforce org migration should not version the portal RAML.”

## 2. Failure (5 min)

“Create is not XA. If Composite succeeds and ERP fails, I return 202/partial with `PARTIAL_COMMIT`, retry ERP, and never auto-delete the Salesforce Account. Idempotency-Key makes client retries safe. CDC uses replayId dedupe and an origin header so Process does not loop.”

Be ready: *Duplicate orders/customers?*  
“Object Store keyed by Idempotency-Key. Same key + same hash → cached 201. Same key + different body → 409.”

## 3. Performance (3 min)

“Chatty REST in a For-Each against Salesforce will burn daily limits. Nightly delta uses Bulk 2.0. Token is cached in Object Store. 360 GET is scatter-gather of two system calls, not N+1 SOQL.”

## 4. Security (3 min)

“Only Experience is public: OAuth 2.0 + Client ID + spike control because Salesforce rate limits are a shared org resource. System APIs stay in the Private Space. Prod Connected App is JWT bearer, API-only user.”

## 5. Leadership (4 min)

“I would reject a design that puts Salesforce field APIs on the Experience layer. I would require RAML in Exchange, MUnit on Process error paths, and a written compensation policy for partial commits. Code review checklist is in SECURITY-AND-GOVERNANCE.md.”

## Whiteboard sketch

```
[Portal] --OAuth--> [Exp] --> [Prc]
                              |     \
                              v      v
                           [SFDC]  [ERP]
                              v
                         [Salesforce org]
```
