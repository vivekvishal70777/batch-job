%dw 2.0
output application/json
---
{
  customerId: payload.customerId,
  companyName: payload.account.name,
  industry: payload.account.industry,
  billingCity: payload.account.billing.city,
  contact: {
    name: (payload.primaryContact.firstName default "") ++ " " ++ (payload.primaryContact.lastName default ""),
    email: payload.primaryContact.email
  },
  creditStatus: payload.erp.creditStatus,
  warnings: payload.warnings default []
}
