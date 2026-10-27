import AbacusDomain
import Foundation
import GRDB
import SQLiteData

/// Turns accounts of kind `debt` into debts with records (R-DEBT-8; docs/status/C14.md):
/// run once by migration "v10: debts" and after every import commit (an import that maps a
/// Saldo LIABILITIES account still lands on a debt-kind account), inside the caller's database
/// transaction.
///
/// Raw SQL on purpose: a migration must not depend on entity structs that later migrations
/// extend. Every own-account balance stays exactly the same (a transfer's own side becomes the
/// record's leg in place: same id, day, amount, description, attached records, fingerprints);
/// each debt's balance equals the account's; the account is archived with opening balance 0 and
/// rules that use it are disabled.
public enum DebtConversion {
  public struct Result: Hashable, Sendable {
    public var accounts = 0
    public var debtsCreated = 0
    public var records = 0
    /// Transactions kept as legs (transfers between an own account and the debt account).
    public var legs = 0
    /// Transactions booked on the debt account itself (expense/income, debt↔debt transfers):
    /// replaced by records without account.
    public var replacedTxns = 0
    /// Income reversals booked on a debt account: their (negative) income is not carried over.
    public var droppedReports = 0
    public var disabledRules = 0

    public init() {}
  }

  struct DebtAccount {
    let id: String
    let name: String
    let currency: String
    let opening: Int64
    let openingDate: Date
    let isArchived: Bool
    let importBatchID: String?
  }

  /// Converts every debt-kind account that still has an opening balance or transactions, plus
  /// any not converted yet. Safe to run again: converted accounts have nothing left to move.
  @discardableResult
  public static func convertDebtAccounts(_ db: Database, calendar: Calendar = .current, now: Date = Date()) throws -> Result {
    var result = Result()
    let accounts = try Row.fetchAll(
      db,
      sql: """
        SELECT "id", "name", "currency", "openingBalanceMinor", "openingDate", "isArchived", "importBatchID"
        FROM "accounts" WHERE "kind" = 'debt' ORDER BY "position", "name", "id"
        """
    ).map { row in
      DebtAccount(
        id: row["id"], name: row["name"], currency: row["currency"], opening: row["openingBalanceMinor"],
        openingDate: row["openingDate"], isArchived: row["isArchived"], importBatchID: row["importBatchID"])
    }
    guard !accounts.isEmpty else { return result }
    let accountIDs = accounts.map(\.id)
    let placeholders = Array(repeating: "?", count: accountIDs.count).joined(separator: ", ")
    let idArguments = StatementArguments(accountIDs)

    // Anything left to convert? (After the first run only new imports add work.)
    let pendingTxns = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM "txns"
        WHERE ("accountID" IN (\(placeholders)) OR "toAccountID" IN (\(placeholders))) AND "debtRecordID" IS NULL
        """, arguments: idArguments + idArguments) ?? 0
    let pendingAccounts = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM "accounts" AS "a"
        WHERE "a"."id" IN (\(placeholders))
          AND ("a"."openingBalanceMinor" <> 0 OR "a"."isArchived" = 0
            OR NOT EXISTS (SELECT 1 FROM "debts" AS "d" WHERE "d"."sourceAccountID" = "a"."id"))
        """, arguments: idArguments) ?? 0
    guard pendingTxns > 0 || pendingAccounts > 0 else { return result }
    result.accounts = accounts.count

    var clock = now
    func nextCreatedAt() -> Date {
      clock = clock.addingTimeInterval(1)
      return clock
    }

    // 1. One debt per account (found by its source account, else created).
    var debtByAccount: [String: String] = [:]
    var currencyByDebt: [String: String] = [:]
    var running: [String: Int64] = [:]
    for account in accounts {
      if let existing = try String.fetchOne(
        db, sql: #"SELECT "id" FROM "debts" WHERE "sourceAccountID" = ? ORDER BY "createdAt", "id" LIMIT 1"#,
        arguments: [account.id])
      {
        debtByAccount[account.id] = existing
        var balance: Int64 = 0
        for row in try Row.fetchAll(
          db, sql: #"SELECT "kind", "amountMinor" FROM "debtRecords" WHERE "debtID" = ?"#, arguments: [existing])
        {
          let kind = DebtRecordKind(rawValue: row["kind"]) ?? .lent
          balance += kind.balanceSign * (row["amountMinor"] as Int64)
        }
        running[existing] = balance
      } else {
        let id = UUID().uuidString.lowercased()
        try db.execute(
          sql: """
            INSERT INTO "debts" ("id", "personName", "currency", "dueDay", "note", "countsInNetWorth", "isSettled",
              "sourceAccountID", "importBatchID", "createdAt")
            VALUES (?, ?, ?, NULL, '', ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, account.name, account.currency, !account.isArchived, account.isArchived, account.id,
            account.importBatchID, nextCreatedAt(),
          ])
        debtByAccount[account.id] = id
        running[id] = 0
        result.debtsCreated += 1
      }
      currencyByDebt[debtByAccount[account.id]!] = account.currency
    }

    func insertRecord(
      debt: String, delta: Int64, day: Day, note: String, reportKind: CategoryKind? = nil, categoryID: String? = nil,
      fingerprint: String? = nil, importBatchID: String?
    ) throws -> String {
      let before = running[debt] ?? 0
      let kind: DebtRecordKind =
        delta >= 0 ? (before < 0 ? .iRepaid : .lent) : (before > 0 ? .theyRepaid : .borrowed)
      running[debt] = before + delta
      let id = UUID().uuidString.lowercased()
      try db.execute(
        sql: """
          INSERT INTO "debtRecords" ("id", "debtID", "kind", "day", "amountMinor", "note", "reportKind", "categoryID",
            "fingerprint", "importBatchID", "createdAt")
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, debt, kind.rawValue, day.string, abs(delta), note, reportKind?.rawValue, categoryID, fingerprint,
          importBatchID, nextCreatedAt(),
        ])
      result.records += 1
      return id
    }

    // 2. Opening balances → a record without account on the opening day.
    for account in accounts where account.opening != 0 {
      let debt = debtByAccount[account.id]!
      _ = try insertRecord(
        debt: debt, delta: account.opening, day: Day(account.openingDate, calendar: calendar), note: "Opening balance",
        importBatchID: account.importBatchID)
      try db.execute(sql: #"UPDATE "accounts" SET "openingBalanceMinor" = 0 WHERE "id" = ?"#, arguments: [account.id])
    }

    // 3. Transactions touching a debt account, oldest first (the running balance picks kinds).
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT "id", "type", "occurredAt", "accountID", "amountMinor", "categoryID", "toAccountID", "toAmountMinor",
          "isRefund", "payee", "note", "importBatchID"
        FROM "txns"
        WHERE ("accountID" IN (\(placeholders)) OR "toAccountID" IN (\(placeholders))) AND "debtRecordID" IS NULL
        ORDER BY "occurredAt", "createdAt", "id"
        """, arguments: idArguments + idArguments)
    for row in rows {
      let id: String = row["id"]
      let type = TxnType(rawValue: row["type"]) ?? .expense
      let occurredAt: Date = row["occurredAt"]
      let day = Day(occurredAt, calendar: calendar)
      let accountID: String = row["accountID"]
      let amount: Int64 = row["amountMinor"]
      let categoryID: String? = row["categoryID"]
      let toAccountID: String? = row["toAccountID"]
      let toAmount: Int64? = row["toAmountMinor"]
      let isRefund: Bool = row["isRefund"]
      let payee: String = row["payee"]
      let txnNote: String = row["note"]
      let batch: String? = row["importBatchID"]
      let note = [payee, txnNote].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        .joined(separator: " · ")
      let source = debtByAccount[accountID]
      let destination = toAccountID.flatMap { debtByAccount[$0] }

      // Attached records on the debt account (the transaction's source) become records too.
      func convertLines(of debt: String) throws {
        let lines = try Row.fetchAll(
          db,
          sql: #"SELECT "kind", "categoryID", "amountMinor", "note" FROM "attachedRecords" WHERE "txnID" = ? ORDER BY "position", "id""#,
          arguments: [id])
        for line in lines {
          let kind = CategoryKind(rawValue: line["kind"]) ?? .expense
          let lineAmount: Int64 = line["amountMinor"]
          _ = try insertRecord(
            debt: debt, delta: kind == .expense ? -lineAmount : lineAmount, day: day, note: line["note"],
            reportKind: kind, categoryID: line["categoryID"], importBatchID: batch)
        }
        try db.execute(sql: #"DELETE FROM "attachedRecords" WHERE "txnID" = ?"#, arguments: [id])
      }

      if type == .transfer, source == nil, let destination {
        // Own → debt: the leg stays on the own account, money out.
        let record = try insertRecord(
          debt: destination, delta: toAmount ?? amount, day: day, note: txnNote, importBatchID: batch)
        try db.execute(
          sql: """
            UPDATE "txns" SET "toAccountID" = NULL, "toAmountMinor" = NULL, "isRefund" = 0, "debtRecordID" = ?
            WHERE "id" = ?
            """, arguments: [record, id])
        result.legs += 1
      } else if type == .transfer, let source, let toAccountID, destination == nil {
        // Debt → own: the leg moves to the own account, money in.
        let record = try insertRecord(debt: source, delta: -amount, day: day, note: txnNote, importBatchID: batch)
        try convertLines(of: source)
        try db.execute(
          sql: """
            UPDATE "txns" SET "accountID" = ?, "amountMinor" = ?, "toAccountID" = NULL, "toAmountMinor" = NULL,
              "isRefund" = 1, "debtRecordID" = ?
            WHERE "id" = ?
            """, arguments: [toAccountID, toAmount ?? amount, record, id])
        result.legs += 1
      } else {
        // Booked on the debt account itself: records without account, then the transaction goes.
        let fingerprint = try String.fetchOne(
          db, sql: #"SELECT "id" FROM "importFingerprints" WHERE "txnID" = ? ORDER BY "id" LIMIT 1"#, arguments: [id])
        var fingerprintUsed = false
        if let source {
          var delta: Int64
          var reportKind: CategoryKind?
          switch type {
          case .expense:
            delta = isRefund ? amount : -amount
            // An expense refund reports like a refund line: income in its expense category (D22).
            reportKind = isRefund ? .income : .expense
          case .income:
            delta = isRefund ? -amount : amount
            reportKind = isRefund ? nil : .income
            if isRefund { result.droppedReports += 1 }
          case .transfer:
            delta = toAccountID == nil && isRefund ? amount : -amount
            reportKind = nil
          }
          _ = try insertRecord(
            debt: source, delta: delta, day: day, note: note, reportKind: reportKind,
            categoryID: reportKind == nil ? nil : categoryID, fingerprint: fingerprint, importBatchID: batch)
          fingerprintUsed = true
          try convertLines(of: source)
        }
        if let destination {
          _ = try insertRecord(
            debt: destination, delta: toAmount ?? amount, day: day, note: note,
            fingerprint: fingerprintUsed ? nil : fingerprint, importBatchID: batch)
        }
        // Explicit deletes: a migration runs with foreign keys off, so nothing cascades there.
        for table in ["importFingerprints", "attachedRecords", "ruleApplications"] {
          try db.execute(sql: #"DELETE FROM "\#(table)" WHERE "txnID" = ?"#, arguments: [id])
        }
        try db.execute(sql: #"DELETE FROM "txns" WHERE "id" = ?"#, arguments: [id])
        result.replacedTxns += 1
      }
    }

    // 4. Archive the accounts (ids stay valid for mappings, batches and rules) and disable the
    // rules that still use them.
    try db.execute(
      sql: #"UPDATE "accounts" SET "isArchived" = 1, "openingBalanceMinor" = 0 WHERE "id" IN (\#(placeholders))"#,
      arguments: idArguments)
    try db.execute(
      sql: """
        UPDATE "categoryRules" SET "isEnabled" = 0
        WHERE "isEnabled" = 1 AND ("accountID" IN (\(placeholders)) OR "transferAccountID" IN (\(placeholders)))
        """, arguments: idArguments + idArguments)
    result.disabledRules = db.changesCount
    return result
  }
}
