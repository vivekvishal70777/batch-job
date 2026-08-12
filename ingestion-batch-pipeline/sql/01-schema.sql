/*
  Inventory data migration schema for SQL Server.
  Apply in order. Safe to re-run: objects are created only if missing.
*/

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dbo')
BEGIN
    EXEC('CREATE SCHEMA dbo');
END
GO

IF OBJECT_ID('dbo.MigrationJob', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationJob (
        JobId           UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_MigrationJob PRIMARY KEY,
        Entity          NVARCHAR(50)     NOT NULL,
        Status          NVARCHAR(20)     NOT NULL,
        SourceFile      NVARCHAR(500)    NULL,
        StartedAt       DATETIME2        NOT NULL CONSTRAINT DF_MigrationJob_StartedAt DEFAULT SYSUTCDATETIME(),
        CompletedAt     DATETIME2        NULL,
        TotalRecords    INT              NULL,
        SuccessCount    INT              NULL,
        FailureCount    INT              NULL,
        MergedCount     INT              NULL,
        CorrelationId   NVARCHAR(100)    NULL,
        DryRun          BIT              NOT NULL CONSTRAINT DF_MigrationJob_DryRun DEFAULT 0,
        ErrorMessage    NVARCHAR(MAX)    NULL,
        CONSTRAINT CK_MigrationJob_Status CHECK (Status IN ('ACCEPTED', 'RUNNING', 'COMPLETED', 'PARTIAL', 'FAILED', 'NO_SOURCE'))
    );
END
GO

IF OBJECT_ID('dbo.InventoryStaging', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventoryStaging (
        StagingId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryStaging PRIMARY KEY,
        SKU               NVARCHAR(64)  NOT NULL,
        StoreId           NVARCHAR(32)  NOT NULL,
        Type              NVARCHAR(32)  NOT NULL,
        Quantity          INT           NOT NULL,
        SourceTimestamp   NVARCHAR(64)  NULL,
        JobId             UNIQUEIDENTIFIER NOT NULL,
        LoadedAt          DATETIME2     NOT NULL CONSTRAINT DF_InventoryStaging_LoadedAt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('dbo.InventoryTarget', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventoryTarget (
        SKU               NVARCHAR(64)  NOT NULL,
        StoreId           NVARCHAR(32)  NOT NULL,
        Type              NVARCHAR(32)  NOT NULL,
        Quantity          INT           NOT NULL,
        SourceTimestamp   NVARCHAR(64)  NULL,
        LastJobId         UNIQUEIDENTIFIER NOT NULL,
        CreatedAt         DATETIME2     NOT NULL CONSTRAINT DF_InventoryTarget_CreatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedAt         DATETIME2     NOT NULL CONSTRAINT DF_InventoryTarget_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_InventoryTarget PRIMARY KEY (SKU, StoreId)
    );
END
GO

IF OBJECT_ID('dbo.InventoryMigrationError', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventoryMigrationError (
        ErrorId           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InventoryMigrationError PRIMARY KEY,
        SKU               NVARCHAR(64)  NULL,
        StoreId           NVARCHAR(32)  NULL,
        Type              NVARCHAR(32)  NULL,
        Quantity          NVARCHAR(64)  NULL,
        SourceTimestamp   NVARCHAR(64)  NULL,
        JobId             UNIQUEIDENTIFIER NOT NULL,
        ErrorDescription  NVARCHAR(1000) NOT NULL,
        CreatedAt         DATETIME2     NOT NULL CONSTRAINT DF_InventoryMigrationError_CreatedAt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('dbo.MigrationFileAudit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationFileAudit (
        AuditId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MigrationFileAudit PRIMARY KEY,
        FileName    NVARCHAR(255) NOT NULL,
        FilePath    NVARCHAR(500) NOT NULL,
        JobId       UNIQUEIDENTIFIER NOT NULL,
        Status      NVARCHAR(20)  NOT NULL,
        ProcessedAt DATETIME2     NOT NULL CONSTRAINT DF_MigrationFileAudit_ProcessedAt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('dbo.MigrationWatermark', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationWatermark (
        Entity            NVARCHAR(50)  NOT NULL CONSTRAINT PK_MigrationWatermark PRIMARY KEY,
        LastJobId         UNIQUEIDENTIFIER NOT NULL,
        LastSuccessfulAt  DATETIME2     NOT NULL,
        UpdatedAt         DATETIME2     NOT NULL CONSTRAINT DF_MigrationWatermark_UpdatedAt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MigrationJob_StartedAt' AND object_id = OBJECT_ID('dbo.MigrationJob'))
    CREATE INDEX IX_MigrationJob_StartedAt ON dbo.MigrationJob (StartedAt DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InventoryStaging_JobId' AND object_id = OBJECT_ID('dbo.InventoryStaging'))
    CREATE INDEX IX_InventoryStaging_JobId ON dbo.InventoryStaging (JobId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InventoryTarget_LastJobId' AND object_id = OBJECT_ID('dbo.InventoryTarget'))
    CREATE INDEX IX_InventoryTarget_LastJobId ON dbo.InventoryTarget (LastJobId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InventoryMigrationError_JobId' AND object_id = OBJECT_ID('dbo.InventoryMigrationError'))
    CREATE INDEX IX_InventoryMigrationError_JobId ON dbo.InventoryMigrationError (JobId);
GO

IF OBJECT_ID('dbo.usp_MergeInventoryFromStaging', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_MergeInventoryFromStaging;
GO

CREATE PROCEDURE dbo.usp_MergeInventoryFromStaging
    @JobId UNIQUEIDENTIFIER,
    @MergedCount INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    MERGE dbo.InventoryTarget AS target
    USING (
        SELECT SKU, StoreId, Type, Quantity, SourceTimestamp, JobId
        FROM (
            SELECT SKU, StoreId, Type, Quantity, SourceTimestamp, JobId,
                   ROW_NUMBER() OVER (PARTITION BY SKU, StoreId ORDER BY LoadedAt DESC) AS rn
            FROM dbo.InventoryStaging
            WHERE JobId = @JobId
        ) ranked
        WHERE rn = 1
    ) AS source
    ON (target.SKU = source.SKU AND target.StoreId = source.StoreId)
    WHEN MATCHED THEN
        UPDATE SET
            Type = source.Type,
            Quantity = source.Quantity,
            SourceTimestamp = source.SourceTimestamp,
            LastJobId = source.JobId,
            UpdatedAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (SKU, StoreId, Type, Quantity, SourceTimestamp, LastJobId, CreatedAt, UpdatedAt)
        VALUES (source.SKU, source.StoreId, source.Type, source.Quantity, source.SourceTimestamp, source.JobId, SYSUTCDATETIME(), SYSUTCDATETIME());

    SET @MergedCount = @@ROWCOUNT;

    DELETE FROM dbo.InventoryStaging WHERE JobId = @JobId;

    COMMIT;
END
GO
