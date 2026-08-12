%dw 2.0

fun isBlank(value) =
    value == null or (value is String and isEmpty(trim(value as String)))

fun allowedTypes() =
    (p('migration.allowed-types') default "Standard,Backorder") splitBy "," map trim($)

fun maxQuantity() =
    (p('migration.max-quantity') default "999999999") as Number

fun parseQuantity(value) =
    value as Number default null

fun isNonNegativeInteger(value) =
    do {
        var n = parseQuantity(value)
        ---
        n != null and n >= 0 and n <= maxQuantity() and n == floor(n)
    }

fun parseSourceTimestamp(value) =
    value as DateTime {format: "yyyy-MM-dd'T'HH:mm:ss"} default
    value as DateTime {format: "yyyy-MM-dd HH:mm:ss"} default
    value as DateTime {format: "dd-MM-yyyy HH:mm:ss"} default
    value as DateTime {format: "MM/dd/yyyy HH:mm:ss"} default
    value as DateTime {format: "yyyy-MM-dd"} default
    null

fun validationErrors(record) = flatten([
    if (isBlank(record.SKU)) ["SKU is mandatory"] else [],
    if (isBlank(record.StoreId)) ["StoreId is mandatory"] else [],
    if (isBlank(record.Type)) ["Type is mandatory"] else [],
    if (isBlank(record.Quantity)) ["Quantity is mandatory"] else [],
    if (isBlank(record.Timestamp) and isBlank(record.SourceTimestamp)) ["Timestamp is mandatory"] else [],
    if (!isBlank(record.Type) and !(allowedTypes() contains record.Type)) ["Type must be one of: " ++ (allowedTypes() joinBy ", ")] else [],
    if (!isBlank(record.Quantity) and !isNonNegativeInteger(record.Quantity)) ["Quantity must be a whole number between 0 and " ++ (maxQuantity() as String)] else [],
    if (!isBlank(record.Timestamp default record.SourceTimestamp) and parseSourceTimestamp(record.Timestamp default record.SourceTimestamp) == null) ["Timestamp is not a recognized date/time"] else []
])

fun isValid(record) = isEmpty(validationErrors(record))

fun errorDescription(record) =
    "Validation failed: " ++ (validationErrors(record) joinBy "; ")
