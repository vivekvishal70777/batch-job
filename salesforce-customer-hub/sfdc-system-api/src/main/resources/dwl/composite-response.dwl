%dw 2.0
output application/json
---
{
  accountId: payload.compositeResponse[0].body.id default payload.accountId,
  contactId: payload.compositeResponse[1].body.id default payload.contactId,
  success: true
}
