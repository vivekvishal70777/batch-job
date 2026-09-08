%dw 2.0
output application/json
---
{
  account: {
    name: payload.companyName,
    type: "Customer",
    industry: payload.industry,
    billing: {
      city: payload.city,
      state: payload.state,
      country: payload.country,
      postalCode: payload.postalCode
    }
  },
  primaryContact: {
    firstName: payload.contactFirstName,
    lastName: payload.contactLastName,
    email: payload.email,
    phone: payload.phone
  },
  status: "ACTIVE"
}
