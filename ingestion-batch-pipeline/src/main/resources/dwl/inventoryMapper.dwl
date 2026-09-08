%dw 2.0

fun toInventoryRecord(data, jobId) = {
    SKU: data.SKU as String default "",
    StoreId: data.StoreId as String default "",
    Type: data."Type" as String default "",
    Quantity: data.Quantity,
    SourceTimestamp: (data.Timestamp default data.SourceTimestamp) as String default "",
    JobId: jobId as String
}

fun toCsvSuccess(data) = {
    SKU: data.SKU,
    StoreId: data.StoreId,
    Type: data."Type",
    Quantity: data.Quantity,
    Timestamp: data.SourceTimestamp default data.Timestamp
}

fun toCsvError(data) = {
    SKU: data.SKU,
    StoreId: data.StoreId,
    Type: data."Type",
    Quantity: data.Quantity,
    Timestamp: data.SourceTimestamp default data.Timestamp,
    ErrorDescription: data.ErrorDescription
}
