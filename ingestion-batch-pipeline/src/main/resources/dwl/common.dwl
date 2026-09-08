%dw 2.0

fun tzNow() = now() >> (p('app.timezone') default "UTC")

fun logLine(jobId, flowName, phase) =
    (tzNow() as String) ++ " | " ++ ((jobId default "-") as String) ++ " | " ++ ((flowName default "unknown") as String) ++ " | " ++ (phase as String)

fun sourcePath(fileName) =
    p('sftp.input-directory') ++ (fileName default p('sftp.input-filename'))

fun archiveName(jobId, fileName) =
    (jobId as String) ++ "_" ++ (tzNow() as String {format: "dd-MM-yyyy-HHmmss"}) ++ "_" ++ (fileName as String)

fun errorExportPath(jobId) =
    p('sftp.error-directory') ++ (tzNow() as String {format: "yyyy-MM-dd"}) ++ "/" ++ p('app.entity') ++ "-errors-" ++ (jobId as String) ++ ".csv"

fun successExportPath(jobId) =
    p('sftp.output-directory') ++ (tzNow() as String {format: "yyyy-MM-dd"}) ++ "/" ++ p('app.entity') ++ "-migrated-" ++ (jobId as String) ++ ".csv"
