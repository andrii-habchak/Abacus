import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Migration "v13: accounts drive debts" (R-DEBT-16…19, C19) from a database in the C14/C17 shape
/// (a debt per person and currency, records with legs), written with raw SQL. Synthetic data only.
@Suite("Debt migration v13 (C19)")
struct DebtMigrationV13Tests {
  typealias F = StoreFixture

  static let converter = FixedConverter(rates: ["EURPLN": Decimal(string: "4.3")!])
  static let v12 = "v12: rule debt person"

  static func uid(_ n: Int) -> String { F.id(n).uuidString.lowercased() }

  /// IDs: accounts 1 Bank PLN, 2 Card EUR, 3 Mono UAH, 10 "Ann zl" (debt kind PLN, archived),
  /// 11 "ann EUR" (debt kind EUR, archived); debts 101 Ann PLN, 102 ann EUR, 103 Bob, 104 Cleo.
  /// `conflict`: the EUR debt does not count in net worth while the PLN one does.
  static func v12Database(conflict: Bool = true) throws -> any DatabaseWriter {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(database, upTo: v12)
    try database.write { db in
      // The test reads this database with the current model before v13: v14's column is added early.
      try db.execute(
        sql: #"ALTER TABLE "txns" ADD COLUMN "isBalanceCorrection" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0"#)
      try db.execute(sql: #"ALTER TABLE "txns" ADD COLUMN "refundOfID" TEXT"#)
      func account(_ id: Int, _ name: String, _ currency: String, _ kind: String, opening: Int64 = 0, archived: Bool = false) throws {
        try db.execute(
          sql: """
            INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate", "position", "isArchived")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [uid(id), name, currency, kind, opening, F.at("2026-01-01", "00:00"), id, archived])
      }
      try account(1, "Bank", "PLN", "bank", opening: 1_000_00)
      try account(2, "Card", "EUR", "card", opening: 100_00)
      try account(3, "Mono", "UAH", "card", opening: 5_000_00)
      try account(10, "Ann zl", "PLN", "debt", archived: true)
      try account(11, "ann EUR", "EUR", "debt", archived: true)
      try db.execute(
        sql: #"INSERT INTO "categories" ("id", "name", "kind", "position") VALUES (?, 'Debts', 'expense', 0)"#, arguments: [uid(50)])
      try db.execute(
        sql: #"INSERT INTO "categories" ("id", "name", "kind", "position") VALUES (?, 'Fees', 'expense', 1)"#, arguments: [uid(51)])
      try db.execute(
        sql: #"INSERT INTO "importBatches" ("id", "source", "fileName", "importedAt") VALUES (?, 'pko', 'a.csv', ?)"#,
        arguments: [uid(60), F.at("2026-03-01")])

      func debt(_ id: Int, _ name: String, _ currency: String, counts: Bool, settled: Bool = false, source: Int? = nil, due: String? = nil, note: String = "", created: Int) throws {
        try db.execute(
          sql: """
            INSERT INTO "debts" ("id", "personName", "currency", "dueDay", "note", "countsInNetWorth", "isSettled", "sourceAccountID", "createdAt")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [uid(id), name, currency, due, note, counts, settled, source.map(uid), F.at("2026-02-0\(created)")])
      }
      try debt(101, "Ann Žuk", "PLN", counts: true, source: 10, due: "2026-12-01", note: "flat", created: 1)
      try debt(102, "ann zuk ", "EUR", counts: !conflict, source: 11, due: "2026-11-01", note: "trip", created: 2)
      try debt(103, "Bob", "PLN", counts: true, settled: true, created: 3)
      try debt(104, "Cleo", "UAH", counts: true, created: 4)

      func record(
        _ id: Int, _ debt: Int, _ kind: String, _ day: String, _ amount: Int64, report: String? = nil, category: Int? = nil,
        fingerprint: String? = nil
      ) throws {
        try db.execute(
          sql: """
            INSERT INTO "debtRecords" ("id", "debtID", "kind", "day", "amountMinor", "note", "reportKind", "categoryID", "fingerprint", "createdAt")
            VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, ?)
            """, arguments: [uid(id), uid(debt), kind, day, amount, report, category.map(uid), fingerprint, F.at(day)])
      }
      func leg(
        _ id: Int, _ type: String, _ day: String, on account: Int, _ amount: Int64, record: Int, refund: Bool = false,
        category: Int? = nil, fingerprint: String? = nil, batch: Int? = nil, payee: String = "Row"
      ) throws {
        try db.execute(
          sql: """
            INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "categoryID", "isRefund", "payee", "note",
              "source", "importBatchID", "createdAt", "debtRecordID")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'memo', 'pko', ?, ?, ?)
            """,
          arguments: [uid(id), type, F.at(day), uid(account), amount, category.map(uid), refund, payee, batch.map(uid), F.at(day), uid(record)])
        if let fingerprint {
          try db.execute(
            sql: #"INSERT INTO "importFingerprints" ("id", "txnID") VALUES (?, ?)"#, arguments: [fingerprint, uid(id)])
        }
      }
      // Ann PLN: lent 100 (leg out), they repaid 30 (leg in, with a fee line on it).
      try record(201, 101, "lent", "2026-02-10", 100_00)
      try leg(301, "transfer", "2026-02-10", on: 1, 100_00, record: 201, fingerprint: "pko:t1", batch: 60, payee: "ANN")
      try record(202, 101, "theyRepaid", "2026-02-20", 30_00)
      try leg(302, "transfer", "2026-02-20", on: 1, 30_00, record: 202, refund: true, fingerprint: "pko:t2", payee: "ANN BACK")
      try db.execute(
        sql: #"INSERT INTO "attachedRecords" ("id", "txnID", "kind", "categoryID", "amountMinor", "note") VALUES (?, ?, 'expense', ?, 100, 'fee')"#,
        arguments: [uid(401), uid(302), uid(51)])
      // Ann EUR: lent €20 from the PLN bank (86 zl), a flagged lent €5 from the EUR card, a forgiven €2 (no leg).
      try record(203, 102, "lent", "2026-03-01", 20_00)
      try leg(303, "transfer", "2026-03-01", on: 1, 86_00, record: 203, fingerprint: "pko:t3")
      try record(204, 102, "lent", "2026-03-02", 5_00, report: "expense", category: 50)
      try leg(304, "expense", "2026-03-02", on: 2, 5_00, record: 204, category: 50)
      try record(205, 102, "forgaveThem", "2026-03-05", 2_00, report: "expense", category: 50)
      // Bob (settled): they repaid 30, flagged as income, to the bank.
      try record(206, 103, "theyRepaid", "2026-03-03", 30_00, report: "income", category: 50)
      try leg(305, "income", "2026-03-03", on: 1, 30_00, record: 206, category: 50)
      // Cleo (no account): an opening record, and 10 UAH lent from the Mono card.
      try record(207, 104, "lent", "2026-01-05", 40_00, fingerprint: "pko:manual")
      try record(208, 104, "lent", "2026-03-06", 10_00)
      try leg(306, "transfer", "2026-03-06", on: 3, 10_00, record: 208)
      // An ordinary expense, untouched.
      try db.execute(
        sql: """
          INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "payee", "createdAt")
          VALUES (?, 'expense', ?, ?, 700, 'Shop', ?)
          """, arguments: [uid(307), F.at("2026-03-08"), uid(1), F.at("2026-03-08")])
    }
    return database
  }

  /// SQL balances of the own (non-debt) accounts.
  static func ownBalances(_ database: any DatabaseWriter) async throws -> [Account.ID: Int64] {
    let accounts = try await SQLiteAccountRepository(database: database, calendar: F.calendar).accounts(includeArchived: true)
    let own = Set(accounts.filter { $0.kind != .debt }.map(\.id))
    return try await SQLiteAccountRepository(database: database, calendar: F.calendar).balances(asOf: Day("2100-01-01")!)
      .filter { own.contains($0.key) }
  }

  @Test("R-DEBT-16…19: v12 → v13 merges per person, links source accounts, turns legs into transfers; balances stay equal")
  func migration() async throws {
    let database = try Self.v12Database()
    let before = try await Self.ownBalances(database)
    let expectedBank: Int64 = 1_000_00 - 100_00 + 30_00 - 1_00 - 86_00 + 30_00 - 7_00
    #expect(before[F.id(1)] == expectedBank)

    let result = try await database.write { db in try DebtMigrationV13.run(db) }
    #expect(result.debtsBefore == 4 && result.debtsAfter == 3 && result.mergedDebts == 1 && result.flagConflicts == 1)
    #expect(result.linkedSourceAccounts == 2)
    #expect(result.transfers == 6 && result.droppedReportFlags == 2 && result.splitLines == 1)
    #expect(result.manualRecords == 2)  // forgave €2 and Cleo's opening
    #expect(result.virtualAccountsCreated == 2)  // Bob's PLN and Cleo's UAH account; Ann's two are the source accounts
    try AbacusDatabase.migrator().migrate(database)  // registers v13; the run above made it a no-op

    let book = try await SQLiteDebtRepository(database: database, calendar: F.calendar).book()
    let txns = try await SQLiteTxnRepository(database: database, calendar: F.calendar).transactions(matching: TxnQuery())

    // One debt per person; the oldest survives; flag = any, due = earliest, notes joined, settled only if all.
    #expect(book.debts.map(\.personName).sorted() == ["Ann Žuk", "Bob", "Cleo"])
    let ann = try #require(book.debt(person: "ann zuk"))
    #expect(ann.id == F.id(101) && ann.countsInNetWorth && !ann.isSettled)
    #expect(ann.dueDay == "2026-11-01" && ann.note == "flat\ntrip")
    #expect(try #require(book.debt(person: "Bob")).isSettled)

    // Own balances: exactly as before.
    let after = try await Self.ownBalances(database)
    #expect(after == before)

    // Per person and currency, as the records said (EUR 20 + 5 − 2; PLN 100 − 30; Bob −30; Cleo 40 + 10).
    let balances = Calc.debtBalances(book, calendar: F.calendar)
    #expect(balances[ann.id] == [Money(minorUnits: 23_00, currency: .EUR), Money(minorUnits: 70_00, currency: .PLN)])
    #expect(balances[F.id(103)] == [Money(minorUnits: -30_00, currency: .PLN)])
    #expect(balances[F.id(104)] == [Money(minorUnits: 50_00, currency: .UAH)])

    // Links: both source accounts (unarchived, reused) and Cleo's new UAH account.
    #expect(Set(book.links.map(\.accountID)).count == 4 && book.links.allSatisfy { $0.role == .virtual })
    #expect(Set(book.links(of: ann.id).map(\.accountID)) == [F.id(10), F.id(11)])
    let ann10 = try #require(book.accounts.first { $0.id == F.id(10) })
    #expect(!ann10.isArchived && ann10.currency == .PLN && ann10.kind == .debt)
    let cleo = try #require(book.accounts(of: F.id(104)).first)
    #expect(cleo.currency == .UAH && cleo.name == "Cleo (UAH)" && cleo.kind == .debt)

    // Legs are transfers in place: ids, descriptions, batches and fingerprints stay.
    func txn(_ n: Int) throws -> Txn { try #require(txns.first { $0.txn.id == F.id(n) }).txn }
    let out = try txn(301)
    #expect(out.type == .transfer && out.accountID == F.id(1) && out.toAccountID == F.id(10) && out.amountMinor == 100_00)
    #expect(out.toAmountMinor == nil && out.payee == "ANN" && out.note == "memo" && out.importBatchID == F.id(60))
    #expect(out.categoryID == nil && !out.isRefund && out.debtRecordID == nil)
    let back = try txn(302)
    #expect(back.accountID == F.id(10) && back.toAccountID == F.id(1) && back.amountMinor == 30_00 && back.toAmountMinor == nil)
    // The fee line of the inflow leg is its own transaction on my account now.
    #expect(txns.first { $0.txn.id == F.id(302) }?.lines.isEmpty == true)
    let fee = try #require(txns.first { $0.txn.type == .expense && $0.txn.amountMinor == 1_00 && $0.txn.accountID == F.id(1) })
    #expect(fee.txn.note == "fee" && fee.txn.categoryID == F.id(51) && fee.txn.payee == "ANN BACK")
    // Cross-currency: 86 zl out, €20 on the person's EUR account.
    let cross = try txn(303)
    #expect(cross.accountID == F.id(1) && cross.toAccountID == F.id(11) && cross.amountMinor == 86_00 && cross.toAmountMinor == 20_00)
    // A flagged expense leg is a plain transfer now (the flag no longer reports it).
    let flagged = try txn(304)
    #expect(flagged.type == .transfer && flagged.categoryID == nil && flagged.accountID == F.id(2) && flagged.toAccountID == F.id(11))
    let income = try txn(305)
    let bobAccount = try #require(book.accounts(of: F.id(103)).first)
    #expect(bobAccount.currency == .PLN && bobAccount.name == "Bob (PLN)")
    #expect(income.type == .transfer && income.accountID == bobAccount.id && income.toAccountID == F.id(1) && income.categoryID == nil)
    // The Mono leg goes to Cleo's new account.
    #expect(try txn(306).toAccountID == cleo.id)
    // The untouched expense is untouched.
    #expect(try txn(307).type == .expense)
    // Nothing is left of the leg link.
    let legsLeft = try await database.read { db in try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "txns" WHERE "debtRecordID" IS NOT NULL"#) }
    #expect(legsLeft == 0)

    // Manual records stay, each with the currency of its old debt; fingerprints stay on them.
    #expect(book.records.count == 2)
    let forgave = try #require(book.records.first { $0.kind == .forgaveThem })
    #expect(forgave.currency == .EUR && forgave.debtID == ann.id && forgave.reportKind == .expense && forgave.amountMinor == 2_00)
    let opening = try #require(book.records.first { $0.fingerprint == "pko:manual" })
    #expect(opening.currency == .UAH && opening.debtID == F.id(104))

    // Fingerprints: a repeated import finds the very same transactions.
    let found = try await SQLiteImportStore(database: database, calendar: F.calendar)
      .existingFingerprints(["pko:t1", "pko:t2", "pko:t3"])
    #expect(found == ["pko:t1": F.id(301), "pko:t2": F.id(302), "pko:t3": F.id(303)])

    // The currency column is gone, the record's is there.
    let debtColumns = try await database.read { db in try db.columns(in: "debts").map(\.name) }
    #expect(!debtColumns.contains("currency"))
    let recordColumns = try await database.read { db in try db.columns(in: "debtRecords").map(\.name) }
    #expect(recordColumns.contains("currency"))

    // Running the migration again changes nothing.
    let again = try await database.write { db in try DebtMigrationV13.run(db) }
    #expect(again == DebtMigrationV13.Result())
  }

  @Test("R-DEBT-18: net worth after v13 equals the one before, except for the union of net-worth flags of merged debts")
  func netWorthEquality() async throws {
    // Without a flag conflict: equal to the minor unit.
    let calm = try Self.v12Database(conflict: false)
    let accountsBefore = try await SQLiteAccountRepository(database: calm, calendar: F.calendar).accounts(includeArchived: false)
    let txnsBefore = try await SQLiteTxnRepository(database: calm, calendar: F.calendar).transactions(matching: TxnQuery())
    let ownBefore = Calc.netWorth(
      accounts: accountsBefore, txns: txnsBefore, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    try AbacusDatabase.migrator().migrate(calm)
    let accounts = try await SQLiteAccountRepository(database: calm, calendar: F.calendar).accounts(includeArchived: true)
    let txns = try await SQLiteTxnRepository(database: calm, calendar: F.calendar).transactions(matching: TxnQuery())
    let book = try await SQLiteDebtRepository(database: calm, calendar: F.calendar).book()
    let netWorth = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    // Own side after = own side before (linked accounts are not in the account part).
    let shown = Set(netWorth.accounts.map(\.accountID))
    let ownIDs: Set<Account.ID> = [F.id(1), F.id(2), F.id(3)]
    #expect(shown == ownIDs)
    let debtsTerm = netWorth.debtsTotal.minorUnits
    // Ann: €23 → 98.90 zl at 4.3 plus 70 zl; Bob −30 zl; Cleo 50 UAH has no rate here (left out).
    let expectedTerm: Int64 = 70_00 + 23_00 * 43 / 10 - 30_00
    #expect(debtsTerm == expectedTerm)
    #expect(netWorth.total.minorUnits - ownBefore.total.minorUnits == debtsTerm)

    // With a conflict (EUR debt off, PLN on): the merged debt counts on, EUR 23 joins.
    let conflicted = try Self.v12Database(conflict: true)
    try AbacusDatabase.migrator().migrate(conflicted)
    let book2 = try await SQLiteDebtRepository(database: conflicted, calendar: F.calendar).book()
    let nw2 = Calc.netWorth(
      accounts: try await SQLiteAccountRepository(database: conflicted, calendar: F.calendar).accounts(includeArchived: true),
      txns: try await SQLiteTxnRepository(database: conflicted, calendar: F.calendar).transactions(matching: TxnQuery()),
      currency: .PLN, converter: Self.converter, debts: book2, calendar: F.calendar)
    #expect(nw2.total == netWorth.total)
  }

  @Test("R-DEBT-19: the migration also runs through the migrator on an empty v12 database and on a fresh one")
  func emptyAndFresh() async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let empty = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(empty, upTo: Self.v12)
    try AbacusDatabase.migrator().migrate(empty)
    let columns = try await empty.read { db in try db.columns(in: "debtAccounts").map(\.name) }
    #expect(columns == ["accountID", "debtID", "role", "createdAt"])
    let fresh = try AbacusDatabase.open(at: nil)
    #expect(try await SQLiteDebtRepository(database: fresh).book().isEmpty)
    // The account is the primary key: a second link for the same account is impossible even in SQL.
    let accountID = UUID()
    try await fresh.write { db in
      try Account.insert { Account(id: accountID, name: "A", currency: .PLN, kind: .debt, openingDate: Date()) }.execute(db)
      let d1 = Debt(personName: "A")
      let d2 = Debt(personName: "B")
      try Debt.insert { d1 }.execute(db)
      try Debt.insert { d2 }.execute(db)
      try DebtAccountLink.insert { DebtAccountLink(accountID: accountID, debtID: d1.id, role: .virtual) }.execute(db)
      #expect(throws: (any Error).self) {
        try DebtAccountLink.insert { DebtAccountLink(accountID: accountID, debtID: d2.id, role: .virtual) }.execute(db)
      }
    }
  }
}
