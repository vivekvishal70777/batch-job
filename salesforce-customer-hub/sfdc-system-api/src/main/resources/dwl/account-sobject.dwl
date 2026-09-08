%dw 2.0
output application/json
---
{
  Id: payload.Id,
  Name: payload.Name,
  Type: payload.Type,
  Industry: payload.Industry,
  BillingCity: payload.BillingCity,
  BillingState: payload.BillingState,
  BillingCountry: payload.BillingCountry,
  BillingPostalCode: payload.BillingPostalCode
}
