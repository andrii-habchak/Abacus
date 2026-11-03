import AbacusDomain
import AbacusStore
import Foundation
import GRDB
import SQLiteData
import Testing

/// N6: schema v19 (cleared flags, `reconciliations`, snapshot kind), its backfill (R-CLR-1, R-CLR-2)
/// and the reconciliation store (R-CLR-5, R-CLR-6). Synthetic data only.
@Suite("Cleared flag and reconciliation (v19)")
struct ClearedV19Tests {
  typealias F = StoreFixture

  @Test("R-CLR-1/2: v19 adds the flags, the table and the snapshot kind, backfills by row class, runs again as a no-op")
  func migrationAndBackfill() throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: "v17: transaction moves")
    try queue.write { db in
      func account(_ id: String) throws {
        try db.execute(
          sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES (?, ?, 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#,
          arguments: [id, id])
      }
      try account("a1")
      try account("a2")
      for (id, source, account) in [("bp", "pko", "a1"), ("bs", "saldo", nil)] as [(String, String, String?)] {
        try db.execute(
          sql: #"INSERT INTO "importBatches" ("id", "source", "fileName", "importedAt", "accountID") VALUES (?, ?, 'f.csv', '2026-03-01 10:00:00.000', ?)"#,
          arguments: [id, source, account])
      }
      func txn(
        _ id: String, _ type: String = "expense", source: String = "manual", pending: Bool = false, to: String? = nil,
        correction: Bool = false, fingerprint: (String, String)? = nil, from: String = "a1"
      ) throws {
        try db.execute(
          sql: #"""
            INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "toAccountID", "amountMinor", "source", "isPendingAtBank", "isBalanceCorrection", "createdAt")
            VALUES (?, ?, '2026-03-01 12:00:00.000', ?, ?, 100, ?, ?, ?, '2026-03-01 12:00:00.000')
            """#, arguments: [id, type, from, to, source, pending, correction])
        if let (key, batch) = fingerprint {
          try db.execute(
            sql: #"INSERT INTO "importFingerprints" ("id", "txnID", "batchID") VALUES (?, ?, ?)"#, arguments: [key, id, batch])
        }
      }
      try txn("s1", source: "saldo", fingerprint: ("saldo:1", "bs"))
      try txn("s2", "transfer", source: "saldo", to: "a2", fingerprint: ("saldo:2", "bs"))
      try txn("p1", source: "pko", fingerprint: ("pko:1", "bp"))
      try txn("p2", "transfer", source: "pko", to: "a2", fingerprint: ("pko:2", "bp"))
      try txn("p3", "transfer", source: "pko", to: "a1", fingerprint: ("pko:3", "bp"), from: "a2")
      try txn("h1", source: "pko", pending: true, fingerprint: ("pko:4", "bp"))
      try txn("m1")
      try txn("m2", fingerprint: ("pko:5", "bp"))
      try txn("m3", "transfer", to: "a2")
      try txn("c1", correction: true)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    let observed: (tables: Bool, columns: [String], unique: Bool, actions: [String], kind: Bool, flags: [String: String]) = try queue.write { db in
      var flags: [String: String] = [:]
      for id in ["s1", "s2", "p1", "p2", "p3", "h1", "m1", "m2", "m3", "c1"] {
        let row = try Row.fetchOne(db, sql: #"SELECT "isCleared" AS a, "isToCleared" AS b FROM "txns" WHERE "id" = ?"#, arguments: [id])!
        let from: Int = row["a"]
        let to: Int = row["b"]
        flags[id] = "\(from)\(to)"
      }
      return (
        try db.tableExists("reconciliations"), try db.columns(in: "reconciliations").map(\.name),
        try db.indexes(on: "reconciliations").filter { $0.name.hasPrefix("idx_") }.contains { $0.isUnique },
        try String.fetchAll(db, sql: #"SELECT "on_delete" FROM pragma_foreign_key_list('reconciliations')"#),
        try db.columns(in: "importTxnSnapshots").contains { $0.name == "kind" }, flags)
    }
    #expect(observed.tables)
    #expect(observed.columns == ["id", "accountID", "statementDay", "closingMinor", "correctionMinor", "finishedAt"])
    #expect(!observed.unique)
    #expect(observed.actions == ["CASCADE"])
    #expect(observed.kind)
    #expect(observed.flags["s1"] == "10")  // Saldo row
    #expect(observed.flags["s2"] == "11")  // Saldo transfer: both sides
    #expect(observed.flags["p1"] == "10")  // PKO row
    #expect(observed.flags["p2"] == "10")  // PKO transfer: only the statement's own side (a1)
    #expect(observed.flags["p3"] == "01")  // PKO transfer received on a1: the to-side
    #expect(observed.flags["h1"] == "00")  // pending hold
    #expect(observed.flags["m1"] == "00")  // hand-typed
    #expect(observed.flags["m2"] == "10")  // hand-typed, linked to a bank row
    #expect(observed.flags["m3"] == "00")  // hand-typed transfer
    #expect(observed.flags["c1"] == "10")  // balance correction
  }

  @Test("R-CLR-1: a v19 database that already holds the flags does not fail the migration")
  func idempotent() throws {
    let queue = try DatabaseQueue()
    try AbacusDatabase.migrator().migrate(queue)
    try queue.write { db in
      try db.execute(sql: #"DELETE FROM "grdb_migrations" WHERE "identifier" LIKE 'v19%'"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
  }

  // MARK: Reconcile store

  static func fixture() async throws -> F {
    let f = try F()
    try await f.accounts.save(F.bank)
    return f
  }

  static func txn(_ n: Int, _ day: String, _ minor: Int64, cleared: Bool = false, source: TxnSource = .manual, pending: Bool = false, booked: String? = nil) -> Txn {
    Txn(
      id: F.id(100 + n), type: .expense, occurredAt: F.at(day), accountID: F.bank.id, amountMinor: minor, payee: "T\(n)",
      source: source, isPendingAtBank: pending, bookedDay: booked, isCleared: cleared)
  }

  @Test("R-CLR-5: figures use the booking day, skip pending holds, count ticks; finish writes ticks, additions, edits, deletions and the record")
  func finishAndFigures() async throws {
    let f = try await Self.fixture()
    let items = [
      Self.txn(1, "2026-10-02", 100_00, cleared: true, source: .pko),
      Self.txn(2, "2026-10-05", 50_00, cleared: true, source: .pko, booked: "2026-10-06"),
      Self.txn(3, "2026-10-12", 46_00),  // hand-typed, the bank booked it
      Self.txn(4, "2026-10-17", 23_00, source: .pko, pending: true),
      Self.txn(5, "2026-10-19", 64_00),  // hand-typed, not on the statement
    ]
    for item in items { try await f.txns.save(item, lines: []) }
    let rows = Reconcile.rows(account: F.bank, txns: try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id])), calendar: F.calendar)
    #expect(rows.count == 5)
    let day = Day("2026-10-05")!
    // The 05.10 purchase booked on 06.10 is outside a statement of 05.10.
    let early = Reconcile.figures(account: F.bank, rows: rows, statementMinor: 0, through: day)
    #expect(early.clearedMinor == 1_000_00 - 100_00)
    // Opening 1000.00 − 100 − 50 (cleared) − 46 (ticked) = 804.00; the hold and the 64.00 row do not count.
    let figures = Reconcile.figures(
      account: F.bank, rows: rows, statementMinor: 804_00, through: Day("2026-10-21")!, ticked: [F.id(103)])
    #expect(figures.clearedMinor == 804_00)
    #expect(figures.differenceMinor == 0)
    // Cash: the whole balance counts.
    let whole = Reconcile.figures(account: F.bank, rows: rows, statementMinor: 0, through: Day("2026-10-21")!, wholeBalance: true)
    #expect(whole.clearedMinor == 1_000_00 - 100_00 - 50_00 - 46_00 - 64_00)  // holds never count

    var edited = Self.txn(5, "2026-10-19", 60_00)
    edited.payee = "T5 edited"
    let added = Txn(
      type: .expense, occurredAt: F.at("2026-10-20"), accountID: F.bank.id, amountMinor: 10_00, payee: "Parking")
    let repository = SQLiteReconcileRepository(database: f.database, calendar: F.calendar)
    try await repository.finish(
      ReconcileFinish(
        accountID: F.bank.id, statementDay: Day("2026-10-21")!, closingMinor: 794_00, clearIDs: [F.id(103)],
        additions: [added], edits: [edited], deletions: [], settleIDs: [F.id(104)], correctionMinor: 0))
    let after = try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id]))
    func txn(_ id: UUID) -> Txn { after.first { $0.txn.id == id }!.txn }
    #expect(txn(F.id(103)).isCleared)
    #expect(!txn(F.id(104)).isPendingAtBank)  // settled by hand
    #expect(!txn(F.id(104)).isCleared)  // …but not cleared until a statement confirms it
    #expect(txn(F.id(105)).payee == "T5 edited")
    #expect(txn(added.id).isCleared)
    let last = try await repository.lastReconciliations()[F.bank.id]
    #expect(last?.closingMinor == 794_00 && last?.statementDay == "2026-10-21")
  }

  @Test("R-CLR-5: a correction books a cleared balance-correction row; deleting a bank-file row is refused; undo of nothing")
  func correctionAndRefusals() async throws {
    let f = try await Self.fixture()
    try await f.txns.save(Self.txn(1, "2026-10-02", 100_00, cleared: true, source: .pko), lines: [])
    let repository = SQLiteReconcileRepository(database: f.database, calendar: F.calendar)
    await #expect(throws: (any Error).self) {
      try await repository.finish(
        ReconcileFinish(accountID: F.bank.id, statementDay: Day("2026-10-21")!, closingMinor: 0, deletions: [F.id(101)]))
    }
    try await repository.finish(
      ReconcileFinish(accountID: F.bank.id, statementDay: Day("2026-10-21")!, closingMinor: 905_00, correctionMinor: 5_00))
    let rows = try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id]))
    let correction = rows.first { $0.txn.isBalanceCorrection }?.txn
    #expect(correction?.type == .income && correction?.amountMinor == 5_00 && correction?.isCleared == true)
    let reconcileRows = Reconcile.rows(account: F.bank, txns: rows, calendar: F.calendar)
    let figures = Reconcile.figures(account: F.bank, rows: reconcileRows, statementMinor: 905_00, through: Day("2026-10-21")!)
    #expect(figures.differenceMinor == 0)
  }

  @Test("R-CLR-5: drift shows when a cleared row changes after a reconciliation; the not-reconciled hint")
  func drift() async throws {
    let f = try await Self.fixture()
    try await f.txns.save(Self.txn(1, "2026-10-02", 100_00, cleared: true, source: .pko), lines: [])
    let repository = SQLiteReconcileRepository(database: f.database, calendar: F.calendar)
    var rows = Reconcile.rows(account: F.bank, txns: try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id])), calendar: F.calendar)
    #expect(Reconcile.isNotReconciled(rows: rows, last: nil))
    try await repository.finish(ReconcileFinish(accountID: F.bank.id, statementDay: Day("2026-10-21")!, closingMinor: 900_00))
    let last = try await repository.lastReconciliations()[F.bank.id]!
    #expect(!Reconcile.isNotReconciled(rows: rows, last: last))
    #expect(Reconcile.drift(last, account: F.bank, rows: rows) == nil)
    try await f.txns.save(Self.txn(1, "2026-10-02", 120_00, cleared: true, source: .pko), lines: [])
    rows = Reconcile.rows(account: F.bank, txns: try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id])), calendar: F.calendar)
    #expect(Reconcile.drift(last, account: F.bank, rows: rows) == -20_00)
    // A cleared row booked after the reconciliation brings the hint back.
    try await f.txns.save(Self.txn(2, "2026-10-25", 10_00, cleared: true, source: .pko), lines: [])
    rows = Reconcile.rows(account: F.bank, txns: try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.bank.id])), calendar: F.calendar)
    #expect(Reconcile.isNotReconciled(rows: rows, last: last))
  }

  @Test("R-CLR-4: setCleared skips pending holds, works per side; markSettled keeps the row uncleared")
  func marking() async throws {
    let f = try await Self.fixture()
    try await f.accounts.save(F.card)
    let transfer = Txn(
      id: F.id(150), type: .transfer, occurredAt: F.at("2026-10-02"), accountID: F.bank.id, amountMinor: 10_00,
      toAccountID: F.card.id, toAmountMinor: 2_00)
    try await f.txns.save(transfer, lines: [])
    try await f.txns.save(Self.txn(4, "2026-10-17", 23_00, source: .pko, pending: true), lines: [])
    let repository = SQLiteReconcileRepository(database: f.database, calendar: F.calendar)
    try await repository.setCleared([transfer.id, F.id(104)], true, on: F.card.id)
    try await repository.setCleared([F.id(104)], true, on: F.bank.id)
    let a = try await f.txns.transaction(transfer.id)!.txn
    #expect(!a.isCleared && a.isToCleared)
    #expect(try await f.txns.transaction(F.id(104))!.txn.hasNoClearedSide)
    try await repository.markSettled([F.id(104)])
    let held = try await f.txns.transaction(F.id(104))!.txn
    #expect(!held.isPendingAtBank && !held.isCleared)
  }
}
