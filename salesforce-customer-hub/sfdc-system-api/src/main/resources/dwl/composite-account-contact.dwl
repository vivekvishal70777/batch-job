%dw 2.0
output application/json
var accountRef = "refAccount"
var contactRef = "refContact"
var apiVersion = p('salesforce.apiVersion') default "v61.0"
---
{
  allOrNone: true,
  compositeRequest: [
    {
      method: "POST",
      url: "/services/data/" ++ apiVersion ++ "/sobjects/Account",
      referenceId: accountRef,
      body: {
        Name: payload.account.name,
        Type: payload.account.type default "Customer",
        Industry: payload.account.industry,
        BillingCity: payload.account.billing.city,
        BillingState: payload.account.billing.state,
        BillingCountry: payload.account.billing.country,
        BillingPostalCode: payload.account.billing.postalCode
      }
    },
    {
      method: "POST",
      url: "/services/data/" ++ apiVersion ++ "/sobjects/Contact",
      referenceId: contactRef,
      body: {
        FirstName: payload.contact.firstName,
        LastName: payload.contact.lastName,
        Email: payload.contact.email,
        Phone: payload.contact.phone,
        AccountId: "@{" ++ accountRef ++ ".id}"
      }
    }
  ]
}
