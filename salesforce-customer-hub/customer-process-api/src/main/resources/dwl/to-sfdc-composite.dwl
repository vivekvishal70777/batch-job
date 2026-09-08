%dw 2.0
output application/json
---
{
  account: {
    name: payload.account.name,
    type: payload.account.type default "Customer",
    industry: payload.account.industry,
    billing: payload.account.billing
  },
  contact: {
    firstName: payload.primaryContact.firstName,
    lastName: payload.primaryContact.lastName,
    email: payload.primaryContact.email,
    phone: payload.primaryContact.phone
  }
}
