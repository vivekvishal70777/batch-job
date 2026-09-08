%dw 2.0

fun acceptedResponse(jobId, fileName, dryRun) = {
    jobId: jobId,
    status: "ACCEPTED",
    entity: p('app.entity'),
    sourceFile: fileName,
    dryRun: dryRun,
    message: "Migration job accepted and is running asynchronously",
    statusUrl: "/api/v1/migration/jobs/" ++ (jobId as String),
    timestamp: now() as String
}

fun healthResponse(status, checks) = {
    status: status,
    application: p('app.name'),
    entity: p('app.entity'),
    checks: checks,
    timestamp: now() as String
}

fun jobApiRecord(row) = {
    jobId: row.JobId,
    entity: row.Entity,
    status: row.Status,
    sourceFile: row.SourceFile,
    startedAt: row.StartedAt,
    completedAt: row.CompletedAt,
    totalRecords: row.TotalRecords,
    successCount: row.SuccessCount,
    failureCount: row.FailureCount,
    mergedCount: row.MergedCount,
    correlationId: row.CorrelationId,
    dryRun: row.DryRun,
    errorMessage: row.ErrorMessage default null
}

fun notificationPayload(headerLine, jobId, message, filePath, extra) =
    extra ++ {
        headerLine: headerLine,
        batch: jobId,
        jobId: jobId,
        message: message,
        filePath: filePath default "NA",
        timestamp: now() as String
    }
