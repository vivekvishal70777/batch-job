%dw 2.0
output application/json
var sfdc = vars.sfdcAccount default {}
var erp = vars.erpCustomer default {}
var mapping = vars.customerMapping default {}
---
{
  customerId: mapping.customerId default vars.customerId,
  externalIds: {
    salesforceAccountId: sfdc.Id default mapping.salesforceAccountId,
    salesforceContactId: mapping.salesforceContactId,
    erpCustomerId: erp.erpCustomerId default mapping.erpCustomerId
  },
  account: {
    name: sfdc.Name default erp.name,
    type: sfdc.Type,
    industry: sfdc.Industry,
    billing: {
      city: sfdc.BillingCity,
      state: sfdc.BillingState,
      country: sfdc.BillingCountry,
      postalCode: sfdc.BillingPostalCode
    }
  },
  primaryContact: mapping.primaryContact default {},
  erp: {
    creditStatus: erp.creditStatus
  },
  status: "ACTIVE",
  warnings: vars.warnings default []
}
