import AbacusDomain
import Foundation
import GRDB
import SQLiteData

/// Migration "v13: accounts drive debts" (R-DEBT-16…19, D59, docs/status/C19.md).
///
/// From the C14/C17 shape (a debt = person + currency, records with legs) to the v1.9 shape (one
/// debt per person without currency, linked accounts, manual records with their own currency,
/// payments as transfers):
///
/// 1. `debtRecords.currency` (from the debt), table `debtAccounts`;
/// 2. debts merged per person (`Debt.personKey`), records re-pointed to the survivor (the oldest);
/// 3. every debt's `sourceAccountID` account is linked to its debt as a `virtual` account;
/// 4. every record with a leg: the leg transaction becomes, in place (same id, fingerprints,
///    import batch, description, event), a transfer between the own account and the debt's virtual
///    account of the record's currency; the record is deleted. Records without a leg stay
///    manual records;
/// 5. `debts.currency` dropped.
///
/// Raw SQL on purpose (a migration must not depend on entity structs later migrations extend).
/// Own-account balances, each debt's balance per currency and net worth stay exactly equal; the
/// only intended change is that a debt's net-worth flag is the OR of the merged debts' flags.
public enum DebtMigrationV13 {
  public struct Result: Hashable, Sendable {
    public var debtsBefore = 0
    public var debtsAfter = 0
    /// Debts folded into another debt of the same person.
    public var mergedDebts = 0
    /// Merged groups whose debts disagreed on "Count in net worth" (the merged one counts when
    /// any of them did).
    public var flagConflicts = 0
    public var linkedSourceAccounts = 0
    /// Legs turned into transfers.
    public var transfers = 0
    public var virtualAccountsCreated = 0
    /// Legs that were expenses/incomes (a "Count as expense/income" flag) and are plain transfers
    /// now: the flag no longer reports them.
    public var droppedReportFlags = 0
    /// Attached records of inflow legs, turned into separate transactions on the own account.
    public var splitLines = 0
    /// Records without a leg, kept as manual records.
    public var manualRecords = 0

    public init() {}
  }

  private struct OldDebt {
    let id: String
    let name: String
    let dueDay: String?
    let note: String
    let counts: Bool
    let settled: Bool
    let source: String?
  }

  @discardableResult
  public static func run(_ db: Database, now: Date = Date()) throws -> Result {
    var result = Result()
    // Already reshaped (or run by hand before): nothing to do.
    guard try db.columns(in: "debts").contains(where: { $0.name == "currency" }) else { return result }

    // 1. Record currency, link table.
    if try !db.columns(in: "debtRecords").contains(where: { $0.name == "currency" }) {
      try db.execute(
        sql: #"ALTER TABLE "debtRecords" ADD COLUMN "currency" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'PLN'"#)
    }
    try db.execute(
      sql: """
        UPDATE "debtRecords"
        SET "currency" = (SELECT "d"."currency" FROM "debts" AS "d" WHERE "d"."id" = "debtRecords"."debtID")
        WHERE EXISTS (SELECT 1 FROM "debts" AS "d" WHERE "d"."id" = "debtRecords"."debtID")
        """)
    if try !db.tableExists("debtAccounts") {
      try db.execute(
        sql: """
          CREATE TABLE "debtAccounts" (
            "accountID" TEXT PRIMARY KEY NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE,
            "debtID" TEXT NOT NULL REFERENCES "debts"("id") ON DELETE CASCADE,
            "role" TEXT NOT NULL,
            "createdAt" TEXT NOT NULL
          ) STRICT
          """)
      try db.execute(sql: #"CREATE INDEX "idx_debtAccounts_debtID" ON "debtAccounts"("debtID")"#)
    }

    // 2. Merge debts per person.
    let debts = try Row.fetchAll(
      db,
      sql: """
        SELECT "id", "personName", "dueDay", "note", "countsInNetWorth", "isSettled", "sourceAccountID"
        FROM "debts" ORDER BY "createdAt", "id"
        """
    ).map { row in
      OldDebt(
        id: row["id"], name: row["personName"], dueDay: row["dueDay"], note: row["note"],
        counts: row["countsInNetWorth"], settled: row["isSettled"], source: row["sourceAccountID"])
    }
    result.debtsBefore = debts.count
    var groups: [String: [OldDebt]] = [:]
    var order: [String] = []
    for debt in debts {
      let key = Debt.personKey(debt.name)
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(debt)
    }
    var survivorOf: [String: String] = [:]
    var personName: [String: String] = [:]
    for key in order {
      let group = groups[key]!
      let survivor = group[0]
      for debt in group { survivorOf[debt.id] = survivor.id }
      personName[survivor.id] = survivor.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard group.count > 1 else { continue }
      result.mergedDebts += group.count - 1
      if Set(group.map(\.counts)).count > 1 { result.flagConflicts += 1 }
      let counts = group.contains { $0.counts }
      let settled = group.allSatisfy(\.settled)
      let due = group.compactMap(\.dueDay).min()
      var notes: [String] = []
      for note in group.map({ $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }) where !note.isEmpty {
        if !notes.contains(note) { notes.append(note) }
      }
      let source = group.compactMap(\.source).first
      try db.execute(
        sql: """
          UPDATE "debts" SET "dueDay" = ?, "note" = ?, "countsInNetWorth" = ?, "isSettled" = ?, "sourceAccountID" = ?
          WHERE "id" = ?
          """, arguments: [due, notes.joined(separator: "\n"), counts, settled, source, survivor.id])
      for other in group.dropFirst() {
        try db.execute(
          sql: #"UPDATE "debtRecords" SET "debtID" = ? WHERE "debtID" = ?"#, arguments: [survivor.id, other.id])
        try db.execute(sql: #"DELETE FROM "debts" WHERE "id" = ?"#, arguments: [other.id])
      }
    }
    result.debtsAfter = order.count

    // 3. Source accounts become linked virtual accounts.
    var clock = now
    func nextCreatedAt() -> Date {
      clock = clock.addingTimeInterval(1)
      return clock
    }
    for debt in debts {
      guard let source = debt.source, let survivor = survivorOf[debt.id] else { continue }
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO "debtAccounts" ("accountID", "debtID", "role", "createdAt")
          SELECT "id", ?, 'virtual', ? FROM "accounts" WHERE "id" = ?
          """, arguments: [survivor, nextCreatedAt(), source])
      result.linkedSourceAccounts += db.changesCount
    }

    // 4. Records with a leg → transfers to the debt's virtual account of the record's currency.
    var virtualCache: [String: String] = [:]
    func virtualAccount(debt: String, currency: String) throws -> String {
      let key = debt + "|" + currency
      if let cached = virtualCache[key] { return cached }
      if let found = try String.fetchOne(
        db,
        sql: """
          SELECT "a"."id" FROM "debtAccounts" AS "l" JOIN "accounts" AS "a" ON "a"."id" = "l"."accountID"
          WHERE "l"."debtID" = ? AND "l"."role" = 'virtual' AND "a"."currency" = ?
          ORDER BY "l"."createdAt", "a"."id" LIMIT 1
          """, arguments: [debt, currency])
      {
        // A converted debt account was archived by v10; it carries payments again.
        try db.execute(sql: #"UPDATE "accounts" SET "isArchived" = 0 WHERE "id" = ?"#, arguments: [found])
        virtualCache[key] = found
        return found
      }
      let id = UUID().uuidString.lowercased()
      let position = (try Int.fetchOne(db, sql: #"SELECT COALESCE(MAX("position"), 0) + 1 FROM "accounts""#)) ?? 0
      try db.execute(
        sql: """
          INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate", "position", "isArchived")
          VALUES (?, ?, ?, 'debt', 0, ?, ?, 0)
          """,
        arguments: [id, "\(personName[debt] ?? "Debt") (\(currency))", currency, now, position])
      try db.execute(
        sql: #"INSERT INTO "debtAccounts" ("accountID", "debtID", "role", "createdAt") VALUES (?, ?, 'virtual', ?)"#,
        arguments: [id, debt, nextCreatedAt()])
      result.virtualAccountsCreated += 1
      virtualCache[key] = id
      return id
    }

    let legs = try Row.fetchAll(
      db,
      sql: """
        SELECT "t"."id" AS "txnID", "t"."type" AS "type", "t"."accountID" AS "accountID", "t"."amountMinor" AS "legAmount",
          "t"."occurredAt" AS "occurredAt", "t"."createdAt" AS "txnCreatedAt", "t"."payee" AS "payee",
          "t"."eventID" AS "eventID", "t"."source" AS "source", "t"."importBatchID" AS "txnBatch",
          "r"."id" AS "recordID", "r"."debtID" AS "debtID", "r"."kind" AS "kind",
          "r"."amountMinor" AS "recordAmount", "r"."currency" AS "recordCurrency"
        FROM "txns" AS "t" JOIN "debtRecords" AS "r" ON "r"."id" = "t"."debtRecordID"
        ORDER BY "t"."occurredAt", "t"."createdAt", "t"."id"
        """)
    for leg in legs {
      let txnID: String = leg["txnID"]
      let type: String = leg["type"]
      let own: String = leg["accountID"]
      let legAmount: Int64 = leg["legAmount"]
      let debt: String = leg["debtID"]
      let kind = DebtRecordKind(rawValue: leg["kind"]) ?? .lent
      let recordAmount: Int64 = leg["recordAmount"]
      let currency: String = leg["recordCurrency"]
      let ownCurrency = try String.fetchOne(db, sql: #"SELECT "currency" FROM "accounts" WHERE "id" = ?"#, arguments: [own])
      let virtual = try virtualAccount(debt: debt, currency: currency)
      // Exact amounts on both sides; left empty only when they are the same number.
      let differs = ownCurrency != currency || legAmount != recordAmount
      if type != "transfer" { result.droppedReportFlags += 1 }

      if kind.isInflow {
        // Money into my account: from the virtual account to mine. Fees attached to the leg
        // hit the source account, so they become their own transactions on my account.
        let lines = try Row.fetchAll(
          db,
          sql: #"SELECT "kind", "categoryID", "amountMinor", "note" FROM "attachedRecords" WHERE "txnID" = ? ORDER BY "position", "id""#,
          arguments: [txnID])
        for line in lines {
          let lineKind: String = line["kind"]
          try db.execute(
            sql: """
              INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "categoryID", "isRefund", "payee",
                "note", "eventID", "source", "importBatchID", "isPendingAtBank", "createdAt")
              VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 0, ?)
              """,
            arguments: [
              UUID().uuidString.lowercased(), lineKind, leg["occurredAt"] as DatabaseValue, own,
              line["amountMinor"] as Int64, line["categoryID"] as String?, leg["payee"] as String,
              line["note"] as String, leg["eventID"] as String?, leg["source"] as String,
              leg["txnBatch"] as String?, nextCreatedAt(),
            ])
          result.splitLines += 1
        }
        if !lines.isEmpty { try db.execute(sql: #"DELETE FROM "attachedRecords" WHERE "txnID" = ?"#, arguments: [txnID]) }
        try db.execute(
          sql: """
            UPDATE "txns" SET "type" = 'transfer', "accountID" = ?, "amountMinor" = ?, "toAccountID" = ?,
              "toAmountMinor" = ?, "categoryID" = NULL, "isRefund" = 0, "debtRecordID" = NULL
            WHERE "id" = ?
            """, arguments: [virtual, recordAmount, own, differs ? legAmount : nil, txnID])
      } else {
        try db.execute(
          sql: """
            UPDATE "txns" SET "type" = 'transfer', "accountID" = ?, "amountMinor" = ?, "toAccountID" = ?,
              "toAmountMinor" = ?, "categoryID" = NULL, "isRefund" = 0, "debtRecordID" = NULL
            WHERE "id" = ?
            """, arguments: [own, legAmount, virtual, differs ? recordAmount : nil, txnID])
      }
      try db.execute(sql: #"DELETE FROM "debtRecords" WHERE "id" = ?"#, arguments: [leg["recordID"] as String])
      result.transfers += 1
    }
    result.manualRecords = try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "debtRecords""#) ?? 0

    // 5. A debt has no currency any more.
    try db.execute(sql: #"ALTER TABLE "debts" DROP COLUMN "currency""#)
    return result
  }
}
