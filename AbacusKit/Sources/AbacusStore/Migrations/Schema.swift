import Foundation
import SQLiteData

// Shared contract file (PLAN.md §1): only the orchestrator changes migrations.
//
// CloudKit-safe rules (SQLiteData CloudKitSync, D6): every table has a single primary key,
// no UNIQUE constraints, ON DELETE only CASCADE / SET NULL. Business rules that a RESTRICT would
// give (R-ACC-5, R-CAT-3) are enforced by the repositories. `fxRates` is a local cache and is not
// meant to be synced, so it may carry a UNIQUE index.
// Migrations are append-only and backwards compatible: new columns are nullable or have a
// default with ON CONFLICT REPLACE.

extension AbacusDatabase {
  public static func migrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1: initial schema") { db in
      for statement in schemaV1 {
        try db.execute(sql: statement)
      }
    }
    migrator.registerMigration("v2: txns.bookedDay") { db in
      try db.execute(sql: #"ALTER TABLE "txns" ADD COLUMN "bookedDay" TEXT"#)
    }
    return migrator
  }

  static let schemaV1: [String] = [
    """
    CREATE TABLE "accounts" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "name" TEXT NOT NULL,
      "currency" TEXT NOT NULL,
      "kind" TEXT NOT NULL,
      "openingBalanceMinor" INTEGER NOT NULL DEFAULT 0,
      "openingDate" TEXT NOT NULL,
      "iban" TEXT,
      "groupName" TEXT,
      "colorHex" TEXT,
      "icon" TEXT,
      "position" INTEGER NOT NULL DEFAULT 0,
      "isArchived" INTEGER NOT NULL DEFAULT 0
    ) STRICT
    """,
    """
    CREATE TABLE "categories" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "name" TEXT NOT NULL,
      "kind" TEXT NOT NULL,
      "parentID" TEXT REFERENCES "categories"("id") ON DELETE SET NULL,
      "icon" TEXT,
      "colorHex" TEXT,
      "position" INTEGER NOT NULL DEFAULT 0,
      "isArchived" INTEGER NOT NULL DEFAULT 0
    ) STRICT
    """,
    """
    CREATE TABLE "events" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "name" TEXT NOT NULL,
      "startDay" TEXT,
      "endDay" TEXT,
      "budgetMinor" INTEGER,
      "budgetCurrency" TEXT,
      "isArchived" INTEGER NOT NULL DEFAULT 0
    ) STRICT
    """,
    """
    CREATE TABLE "importBatches" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "source" TEXT NOT NULL,
      "fileName" TEXT NOT NULL,
      "importedAt" TEXT NOT NULL,
      "accountID" TEXT REFERENCES "accounts"("id") ON DELETE SET NULL,
      "summary" TEXT NOT NULL DEFAULT '',
      "isUndone" INTEGER NOT NULL DEFAULT 0
    ) STRICT
    """,
    """
    CREATE TABLE "txns" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "type" TEXT NOT NULL,
      "occurredAt" TEXT NOT NULL,
      "accountID" TEXT NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
      "amountMinor" INTEGER NOT NULL,
      "categoryID" TEXT REFERENCES "categories"("id") ON DELETE SET NULL,
      "toAccountID" TEXT REFERENCES "accounts"("id") ON DELETE CASCADE,
      "toAmountMinor" INTEGER,
      "isRefund" INTEGER NOT NULL DEFAULT 0,
      "originalAmountMinor" INTEGER,
      "originalCurrencyCode" TEXT,
      "payee" TEXT NOT NULL DEFAULT '',
      "note" TEXT NOT NULL DEFAULT '',
      "eventID" TEXT REFERENCES "events"("id") ON DELETE SET NULL,
      "source" TEXT NOT NULL DEFAULT 'manual',
      "importBatchID" TEXT REFERENCES "importBatches"("id") ON DELETE SET NULL,
      "isPendingAtBank" INTEGER NOT NULL DEFAULT 0,
      "createdAt" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "attachedRecords" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "txnID" TEXT NOT NULL REFERENCES "txns"("id") ON DELETE CASCADE,
      "kind" TEXT NOT NULL,
      "categoryID" TEXT REFERENCES "categories"("id") ON DELETE SET NULL,
      "amountMinor" INTEGER NOT NULL,
      "originalAmountMinor" INTEGER,
      "originalCurrencyCode" TEXT,
      "note" TEXT NOT NULL DEFAULT '',
      "position" INTEGER NOT NULL DEFAULT 0
    ) STRICT
    """,
    """
    CREATE TABLE "budgetPlans" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "effectiveMonth" TEXT NOT NULL,
      "totalMinor" INTEGER NOT NULL,
      "currency" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "budgetAllocations" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "planID" TEXT NOT NULL REFERENCES "budgetPlans"("id") ON DELETE CASCADE,
      "categoryID" TEXT NOT NULL REFERENCES "categories"("id") ON DELETE CASCADE,
      "limitMinor" INTEGER NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "fxRates" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "day" TEXT NOT NULL,
      "base" TEXT NOT NULL,
      "quote" TEXT NOT NULL,
      "rateE8" INTEGER NOT NULL,
      "provider" TEXT NOT NULL,
      "fetchedAt" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "fxOverrides" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "base" TEXT NOT NULL,
      "quote" TEXT NOT NULL,
      "rateE8" INTEGER NOT NULL,
      "fromDay" TEXT NOT NULL,
      "untilDay" TEXT,
      "note" TEXT NOT NULL DEFAULT ''
    ) STRICT
    """,
    """
    CREATE TABLE "importFingerprints" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "txnID" TEXT NOT NULL REFERENCES "txns"("id") ON DELETE CASCADE,
      "batchID" TEXT REFERENCES "importBatches"("id") ON DELETE SET NULL
    ) STRICT
    """,
    """
    CREATE TABLE "importMappings" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "source" TEXT NOT NULL,
      "kind" TEXT NOT NULL,
      "externalKey" TEXT NOT NULL,
      "targetID" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "categoryRules" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "pattern" TEXT NOT NULL,
      "accountID" TEXT REFERENCES "accounts"("id") ON DELETE CASCADE,
      "categoryID" TEXT NOT NULL REFERENCES "categories"("id") ON DELETE CASCADE,
      "origin" TEXT NOT NULL,
      "hitCount" INTEGER NOT NULL DEFAULT 0,
      "position" INTEGER NOT NULL DEFAULT 0,
      "isEnabled" INTEGER NOT NULL DEFAULT 1
    ) STRICT
    """,
    """
    CREATE TABLE "appSettings" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "value" TEXT NOT NULL
    ) STRICT
    """,
    #"CREATE INDEX "idx_categories_parentID" ON "categories"("parentID")"#,
    #"CREATE INDEX "idx_txns_occurredAt" ON "txns"("occurredAt")"#,
    #"CREATE INDEX "idx_txns_accountID" ON "txns"("accountID")"#,
    #"CREATE INDEX "idx_txns_toAccountID" ON "txns"("toAccountID")"#,
    #"CREATE INDEX "idx_txns_categoryID" ON "txns"("categoryID")"#,
    #"CREATE INDEX "idx_txns_eventID" ON "txns"("eventID")"#,
    #"CREATE INDEX "idx_txns_importBatchID" ON "txns"("importBatchID")"#,
    #"CREATE INDEX "idx_attachedRecords_txnID" ON "attachedRecords"("txnID")"#,
    #"CREATE INDEX "idx_attachedRecords_categoryID" ON "attachedRecords"("categoryID")"#,
    #"CREATE INDEX "idx_budgetAllocations_planID" ON "budgetAllocations"("planID")"#,
    #"CREATE INDEX "idx_budgetAllocations_categoryID" ON "budgetAllocations"("categoryID")"#,
    #"CREATE UNIQUE INDEX "idx_fxRates_key" ON "fxRates"("day", "base", "quote", "provider")"#,
    #"CREATE INDEX "idx_importFingerprints_txnID" ON "importFingerprints"("txnID")"#,
    #"CREATE INDEX "idx_importFingerprints_batchID" ON "importFingerprints"("batchID")"#,
    #"CREATE INDEX "idx_importBatches_accountID" ON "importBatches"("accountID")"#,
    #"CREATE INDEX "idx_categoryRules_accountID" ON "categoryRules"("accountID")"#,
    #"CREATE INDEX "idx_categoryRules_categoryID" ON "categoryRules"("categoryID")"#,
  ]
}
