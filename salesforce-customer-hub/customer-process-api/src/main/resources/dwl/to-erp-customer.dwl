%dw 2.0
output application/json
---
{
  name: payload.account.name,
  email: payload.primaryContact.email,
  creditStatus: "GOOD",
  salesforceAccountId: vars.salesforceAccountId
}
