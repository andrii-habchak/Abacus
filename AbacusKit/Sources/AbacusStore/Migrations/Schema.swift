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
    migrator.registerMigration("v3: importBatchID on accounts, categories, events") { db in
      for table in ["accounts", "categories", "events"] {
        try db.execute(
          sql: #"ALTER TABLE "\#(table)" ADD COLUMN "importBatchID" TEXT REFERENCES "importBatches"("id") ON DELETE SET NULL"#
        )
      }
    }
    // R-MGMT-7, D45: events get a colour; every category, account and event without a colour,
    // or with a grey one, gets a palette colour once (siblings kept apart). Safe on a database
    // that already has the column (checked), and the fill only touches uncoloured/grey rows.
    migrator.registerMigration("v4: colours") { db in
      if try !db.columns(in: "events").contains(where: { $0.name == "colorHex" }) {
        try db.execute(sql: #"ALTER TABLE "events" ADD COLUMN "colorHex" TEXT"#)
      }
      try ColorFill.fillAll(db, replacingGrey: true)
    }
    // D43: each budget limit has its own currency; existing limits take their plan's. The
    // plan's totalMinor / currency columns stay (append-only) but are no longer read. The
    // default only applies to rows written without the column (an older schema's records).
    migrator.registerMigration("v5: budget allocation currency") { db in
      try db.execute(
        sql: #"ALTER TABLE "budgetAllocations" ADD COLUMN "currency" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'PLN'"#
      )
      try db.execute(
        sql: #"""
          UPDATE "budgetAllocations"
          SET "currency" = (SELECT "currency" FROM "budgetPlans" WHERE "budgetPlans"."id" = "budgetAllocations"."planID")
          WHERE EXISTS (SELECT 1 FROM "budgetPlans" WHERE "budgetPlans"."id" = "budgetAllocations"."planID")
          """#
      )
    }
    migrator.registerMigration("v6: rules") { db in
      for statement in rulesV6 {
        try db.execute(sql: statement)
      }
    }
    // C9 (TA v1.6): what each "Update existing transactions" changed, so a rule can be rolled
    // back after a restart. Registered last; "v7" is left to another lane.
    migrator.registerMigration("v8: rule applications") { db in
      for statement in ruleApplicationsV8 {
        try db.execute(sql: statement)
      }
    }
    // R-MGMT-8: categories sort by creation ("Newest first" / "Oldest first"). Existing rows
    // get stable values one second apart from 2000-01-01 in their current order (kind,
    // position, name), so "Oldest first" starts out as that order and every category created
    // later is newer. The default only applies to rows written without the column.
    migrator.registerMigration("v9: category createdAt") { db in
      if try !db.columns(in: "categories").contains(where: { $0.name == "createdAt" }) {
        try db.execute(
          sql: #"ALTER TABLE "categories" ADD COLUMN "createdAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '2000-01-01 00:00:00.000'"#
        )
      }
      try db.execute(sql: categoryCreatedAtV9)
    }
    // R-DEBT (TA v1.7, C14): debts and their records, the leg link on transactions, then every
    // account of kind `debt` converted into a debt (R-DEBT-8, docs/status/C14.md). Raw SQL only:
    // later migrations may add columns to the entity structs. Registered before "v11: account
    // groups" (C12); the two are independent.
    migrator.registerMigration("v10: debts") { db in
      for statement in debtsV10 {
        try db.execute(sql: statement)
      }
      _ = try DebtConversionV10.convertDebtAccounts(db)
    }
    // R-MGMT-9, D48: account groups as folders. Every distinct (trimmed) `groupName` becomes a
    // group; accounts point at it through `groupID` (ON DELETE SET NULL: deleting a group moves
    // its accounts to the top level). The `groupName` column stays, unused (append-only).
    // Registered last; "v10" is left to the debts lane.
    migrator.registerMigration("v11: account groups") { db in
      try accountGroupsV11(db)
    }
    // R-DEBT-12 (TA v1.8, C17): the person a "Record as debt" rule records for. Nullable,
    // append-only; the action itself is the new raw value `debt` in "action".
    migrator.registerMigration("v12: rule debt person") { db in
      if try !db.columns(in: "categoryRules").contains(where: { $0.name == "debtPersonName" }) {
        try db.execute(sql: #"ALTER TABLE "categoryRules" ADD COLUMN "debtPersonName" TEXT"#)
      }
    }
    // R-DEBT-16…19 (TA v1.9, C19, D59): debts without currency, linked accounts (`debtAccounts`),
    // manual records with their own currency, payments as transfers to a virtual account. Drops
    // `debts.currency` (the only dropped column; CloudKit sync is not enabled yet, so no deployed
    // schema depends on it). See DebtMigrationV13.
    migrator.registerMigration("v13: accounts drive debts") { db in
      _ = try DebtMigrationV13.run(db)
    }
    // R-ACC-4 (C29): `txns.isBalanceCorrection` marks the correction booked when an account with a
    // balance is archived; reports skip it. Append-only and CloudKit-safe: one nullable-free column
    // with a default (`ON CONFLICT REPLACE DEFAULT 0` as in v5), no constraint, no index.
    // Safe on a database that already has the column (checked, like v4).
    migrator.registerMigration("v14: txns.isBalanceCorrection") { db in
      if try !db.columns(in: "txns").contains(where: { $0.name == "isBalanceCorrection" }) {
        try db.execute(
          sql: #"ALTER TABLE "txns" ADD COLUMN "isBalanceCorrection" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0"#)
      }
    }
    return migrator
  }

  /// Debts and records (R-DEBT-1, R-DEBT-3). Single primary keys, no UNIQUE, only CASCADE /
  /// SET NULL (CloudKit rules). A record's leg points at the record (`txns.debtRecordID`), so
  /// deleting a record or a debt deletes its legs.
  static let debtsV10: [String] = [
    """
    CREATE TABLE "debts" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "personName" TEXT NOT NULL,
      "currency" TEXT NOT NULL,
      "dueDay" TEXT,
      "note" TEXT NOT NULL DEFAULT '',
      "countsInNetWorth" INTEGER NOT NULL DEFAULT 1,
      "isSettled" INTEGER NOT NULL DEFAULT 0,
      "sourceAccountID" TEXT REFERENCES "accounts"("id") ON DELETE SET NULL,
      "importBatchID" TEXT REFERENCES "importBatches"("id") ON DELETE SET NULL,
      "createdAt" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "debtRecords" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "debtID" TEXT NOT NULL REFERENCES "debts"("id") ON DELETE CASCADE,
      "kind" TEXT NOT NULL,
      "day" TEXT NOT NULL,
      "amountMinor" INTEGER NOT NULL,
      "note" TEXT NOT NULL DEFAULT '',
      "reportKind" TEXT,
      "categoryID" TEXT REFERENCES "categories"("id") ON DELETE SET NULL,
      "fingerprint" TEXT,
      "importBatchID" TEXT REFERENCES "importBatches"("id") ON DELETE SET NULL,
      "createdAt" TEXT NOT NULL
    ) STRICT
    """,
    #"ALTER TABLE "txns" ADD COLUMN "debtRecordID" TEXT REFERENCES "debtRecords"("id") ON DELETE CASCADE"#,
    #"CREATE INDEX "idx_txns_debtRecordID" ON "txns"("debtRecordID")"#,
    #"CREATE INDEX "idx_debts_sourceAccountID" ON "debts"("sourceAccountID")"#,
    #"CREATE INDEX "idx_debts_importBatchID" ON "debts"("importBatchID")"#,
    #"CREATE INDEX "idx_debtRecords_debtID" ON "debtRecords"("debtID")"#,
    #"CREATE INDEX "idx_debtRecords_categoryID" ON "debtRecords"("categoryID")"#,
    #"CREATE INDEX "idx_debtRecords_importBatchID" ON "debtRecords"("importBatchID")"#,
    #"CREATE INDEX "idx_debtRecords_fingerprint" ON "debtRecords"("fingerprint")"#,
  ]

  /// Creates `accountGroups` and `accounts.groupID` (both only if missing), then turns the group
  /// names into groups. The custom order keeps what the Accounts page showed before: groups in
  /// the order of their first account (position, name), each followed by its accounts, then the
  /// accounts without a group — numbered 0, 1, 2… across that sequence (a group and the
  /// top-level accounts share one position space; accounts in a group sort among themselves).
  /// Balances and transactions are untouched. Ids are lowercase UUID text, as SQLiteData binds.
  static func accountGroupsV11(_ db: Database) throws {
    if try !db.tableExists("accountGroups") {
      try db.execute(
        sql: """
          CREATE TABLE "accountGroups" (
            "id" TEXT PRIMARY KEY NOT NULL,
            "name" TEXT NOT NULL,
            "position" INTEGER NOT NULL DEFAULT 0,
            "colorHex" TEXT
          ) STRICT
          """)
    }
    if try !db.columns(in: "accounts").contains(where: { $0.name == "groupID" }) {
      try db.execute(
        sql: #"ALTER TABLE "accounts" ADD COLUMN "groupID" TEXT REFERENCES "accountGroups"("id") ON DELETE SET NULL"#)
      try db.execute(sql: #"CREATE INDEX IF NOT EXISTS "idx_accounts_groupID" ON "accounts"("groupID")"#)
    }
    // "id<TAB>trimmed group name" in the old display order (ids never contain a tab).
    let lines = try String.fetchAll(
      db,
      sql: #"SELECT "id" || char(9) || TRIM(COALESCE("groupName", '')) FROM "accounts" ORDER BY "position", "name", "id""#
    )
    var groupOrder: [String] = []
    var members: [String: [String]] = [:]
    var ungrouped: [String] = []
    for line in lines {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      let id = String(parts[0])
      let group = parts.count > 1 ? String(parts[1]) : ""
      if group.isEmpty {
        ungrouped.append(id)
      } else {
        if members[group] == nil { groupOrder.append(group) }
        members[group, default: []].append(id)
      }
    }
    guard !groupOrder.isEmpty else { return }
    var position = 0
    for name in groupOrder {
      let groupID = UUID().uuidString.lowercased()
      try db.execute(
        sql: #"INSERT INTO "accountGroups" ("id", "name", "position") VALUES (?, ?, ?)"#,
        arguments: [groupID, name, position])
      position += 1
      for accountID in members[name] ?? [] {
        try db.execute(
          sql: #"UPDATE "accounts" SET "groupID" = ?, "position" = ? WHERE "id" = ?"#,
          arguments: [groupID, position, accountID])
        position += 1
      }
    }
    for accountID in ungrouped {
      try db.execute(sql: #"UPDATE "accounts" SET "position" = ? WHERE "id" = ?"#, arguments: [position, accountID])
      position += 1
    }
  }

  /// Numbers the existing categories in their current order (see "v9: category createdAt");
  /// the text format is the one dates are stored in (`yyyy-MM-dd HH:mm:ss.SSS`, UTC).
  static let categoryCreatedAtV9 = #"""
    UPDATE "categories"
    SET "createdAt" = (
      SELECT strftime('%Y-%m-%d %H:%M:%f', '2000-01-01 00:00:00', '+' || "ranked"."rank" || ' seconds')
      FROM (
        SELECT "id", ROW_NUMBER() OVER (ORDER BY "kind", "position", "name", "id") - 1 AS "rank"
        FROM "categories"
      ) AS "ranked"
      WHERE "ranked"."id" = "categories"."id"
    )
    """#

  /// Saldo-like rules (R-IMP-8, D44): match kind, amount condition, action and transfer account;
  /// `categoryID` becomes nullable (transfer rules), which SQLite only allows by rebuilding the
  /// table. Every existing rule is a category rule matching by "contains". GRDB runs migrations
  /// with foreign keys deferred and checks them before committing.
  static let rulesV6: [String] = [
    """
    CREATE TABLE "categoryRules_v6" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "pattern" TEXT NOT NULL,
      "accountID" TEXT REFERENCES "accounts"("id") ON DELETE CASCADE,
      "categoryID" TEXT REFERENCES "categories"("id") ON DELETE CASCADE,
      "origin" TEXT NOT NULL,
      "hitCount" INTEGER NOT NULL DEFAULT 0,
      "position" INTEGER NOT NULL DEFAULT 0,
      "isEnabled" INTEGER NOT NULL DEFAULT 1,
      "matchKind" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'contains',
      "amountComparison" TEXT,
      "amountMinor" INTEGER,
      "action" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'category',
      "transferAccountID" TEXT REFERENCES "accounts"("id") ON DELETE CASCADE
    ) STRICT
    """,
    """
    INSERT INTO "categoryRules_v6" \
    ("id", "pattern", "accountID", "categoryID", "origin", "hitCount", "position", "isEnabled", "matchKind", "action") \
    SELECT "id", "pattern", "accountID", "categoryID", "origin", "hitCount", "position", "isEnabled", 'contains', 'category' \
    FROM "categoryRules"
    """,
    #"DROP TABLE "categoryRules""#,
    #"ALTER TABLE "categoryRules_v6" RENAME TO "categoryRules""#,
    #"CREATE INDEX "idx_categoryRules_accountID" ON "categoryRules"("accountID")"#,
    #"CREATE INDEX "idx_categoryRules_categoryID" ON "categoryRules"("categoryID")"#,
    #"CREATE INDEX "idx_categoryRules_transferAccountID" ON "categoryRules"("transferAccountID")"#,
  ]

  /// One row per transaction changed by applying a rule to existing transactions: the
  /// rule-changed fields before and after, as JSON (`RuleTxnState`), so old category/account ids
  /// carry no foreign keys (rollback checks they still exist). Deleting the rule or the
  /// transaction deletes its rows. No UNIQUE, single primary key, only CASCADE (CloudKit rules).
  static let ruleApplicationsV8: [String] = [
    """
    CREATE TABLE "ruleApplications" (
      "id" TEXT PRIMARY KEY NOT NULL,
      "ruleID" TEXT NOT NULL REFERENCES "categoryRules"("id") ON DELETE CASCADE,
      "batchID" TEXT NOT NULL,
      "txnID" TEXT NOT NULL REFERENCES "txns"("id") ON DELETE CASCADE,
      "appliedAt" TEXT NOT NULL,
      "before" TEXT NOT NULL,
      "after" TEXT NOT NULL
    ) STRICT
    """,
    #"CREATE INDEX "idx_ruleApplications_ruleID" ON "ruleApplications"("ruleID")"#,
    #"CREATE INDEX "idx_ruleApplications_txnID" ON "ruleApplications"("txnID")"#,
  ]

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
