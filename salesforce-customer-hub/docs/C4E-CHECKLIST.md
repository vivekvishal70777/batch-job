# C4E review checklist

Use this in code review for the Customer 360 hub.

- [ ] Experience RAML has no Salesforce `__c` or sObject names
- [ ] Process is the only app that calls more than one System API
- [ ] `X-Correlation-Id` is accepted or generated and forwarded
- [ ] `Idempotency-Key` is honored on create (same hash replay, different hash 409)
- [ ] Salesforce writes use until-successful; Bulk used above ~200 records
- [ ] CDC ignores `origin=MULE` and dedupes `replayId`
- [ ] Partial commit (SFDC ok / ERP fail) does not delete the Account
- [ ] Secrets only in secure properties / CH 2.0 secrets
- [ ] MUnit covers Composite mapping and 360 merge
- [ ] API Manager policies listed in SECURITY-AND-GOVERNANCE.md match Exchange product
