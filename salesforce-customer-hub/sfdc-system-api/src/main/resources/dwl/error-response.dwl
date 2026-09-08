%dw 2.0
output application/json
---
{
  correlationId: vars.correlationId default correlationId,
  apiName: p('api.name'),
  errorCode: vars.errorCode default "SFDC-SYS-500",
  httpStatus: vars.httpStatus default 500,
  message: vars.errorMessage default (error.description default "Unexpected error"),
  timestamp: now()
}
