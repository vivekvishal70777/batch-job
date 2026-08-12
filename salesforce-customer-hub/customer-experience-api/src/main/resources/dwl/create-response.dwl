%dw 2.0
output application/json
---
{
  customerId: payload.customerId,
  status: payload.status default "ACTIVE",
  links: {
    self: "/api/v1/customers/" ++ payload.customerId
  }
}
