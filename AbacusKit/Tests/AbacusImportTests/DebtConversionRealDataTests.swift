import AbacusDomain
import AbacusStore
import AbacusTestSupport
import Foundation
import GRDB
import SQLiteData
import Testing

@testable import AbacusImport

/// R-DEBT-17/18/19 on the owner's real Saldo export, in memory. Prints counts only, never names,
/// amounts or descriptions (R-NF-6). Two checks: the runtime link of debt-kind accounts, and the
/// whole migration chain (v10 conversion, then v13) on a copy of the imported rows.
@Suite("Debts — real export", .tags(.realData), .enabled(if: RealSamples.has(prefix: "saldo")))
struct DebtConversionRealDataTests {
  /// Any fixed rate per pair: the invariants hold at every rate.
  struct AnyRates: CurrencyConverter {
    static let perUAH: [Currency: Decimal] = [.UAH: 1, .PLN: Decimal(string: "10.5")!, .EUR: 44, .USD: 41]
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { Self.perUAH[from]! / Self.perUAH[to]! }
    func latestRate(from: Currency, to: Currency) -> Decimal? { Self.perUAH[from]! / Self.perUAH[to]! }
    var latestDay: Day? { nil }
  }

  struct Snapshot {
    var own: [Account.ID: Int64]
    var sql: [Account.ID: Int64]
    var netWorth: [Int64]
    var expense: Int64
    var income: Int64
    var monthly: [Int64]
  }

  static func snapshot(_ database: any DatabaseWriter, book: DebtBook, calendar: Calendar) async throws -> Snapshot {
    let accountsRepo = SQLiteAccountRepository(database: database, calendar: calendar)
    let txnsRepo = SQLiteTxnRepository(database: database, calendar: calendar)
    let categories = try await SQLiteCategoryRepository(database: database).categories(kind: nil, includeArchived: true)
    let today = Day(Date(), calendar: calendar)
    let accounts = try await accountsRepo.accounts(includeArchived: true)
    let txns = try await txnsRepo.transactions(matching: TxnQuery(newestFirst: false))
    let ownIDs = Set(accounts.filter { $0.kind != .debt }.map(\.id))
    let balances = Calc.balances(accounts: accounts, txns: txns, calendar: calendar)
    let sql = try await accountsRepo.balances(asOf: Day("2100-01-01")!)
    let series = Calc.netWorthSeries(
      accounts: accounts, txns: txns, currency: .UAH, converter: AnyRates(), today: today, monthEnds: 120,
      debts: book, calendar: calendar)
    let ledger = book.reportLedger(calendar: calendar)
    func total(_ kind: CategoryKind, _ days: ClosedRange<Day>?) -> Int64 {
      Calc.categoryTotals(
        kind: kind, days: days, accounts: accounts + ledger.accounts, categories: categories,
        txns: txns + ledger.txns, currency: .UAH, converter: AnyRates(), refundsReduceSpending: false,
        calendar: calendar
      ).total.minorUnits
    }
    let months = (0..<120).map { today.yearMonth.adding(months: -$0) }
    return Snapshot(
      own: balances.filter { ownIDs.contains($0.key) }.mapValues(\.minorUnits), sql: sql.filter { ownIDs.contains($0.key) },
      netWorth: series.points.map(\.value.minorUnits), expense: total(.expense, nil), income: total(.income, nil),
      monthly: months.map { total(.expense, $0.firstDay...$0.lastDay(calendar: calendar)) })
  }

  static func importSaldo(_ database: any DatabaseWriter, calendar: Calendar) async throws -> Data {
    let store = SQLiteImportStore(database: database, calendar: calendar, convertsDebtAccounts: false)
    let pipeline = ImportPipeline(
      store: store, accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database), calendar: calendar)
    let data = try Data(contentsOf: try #require(RealSamples.file(prefix: "saldo")))
    var preview = try await pipeline.preview(data: data, fileName: "saldo.csv", targetAccountID: nil)
    preview.acceptSuggestedReviewChoices()
    _ = try await pipeline.commit(preview)
    return data
  }

  static func mismatches(_ before: Snapshot, _ after: Snapshot) -> (own: Int, sql: Int, points: Int, months: Int) {
    (
      Set(before.own.keys).union(after.own.keys).filter { before.own[$0] != after.own[$0] }.count,
      Set(before.sql.keys).union(after.sql.keys).filter { before.sql[$0] != after.sql[$0] }.count,
      zip(before.netWorth, after.netWorth).filter { $0 != $1 }.count,
      zip(before.monthly, after.monthly).filter { $0 != $1 }.count
    )
  }

  @Test("R-DEBT-17, R-DEBT-18: real Saldo — linking debt-kind accounts changes no balance, net worth or report")
  func realRuntimeLink() async throws {
    let calendar = Calendar.current
    let database = try AbacusDatabase.open(at: nil)
    let data = try await Self.importSaldo(database, calendar: calendar)
    let accountsRepo = SQLiteAccountRepository(database: database, calendar: calendar)
    let before = try await Self.snapshot(database, book: .empty, calendar: calendar)
    let debtAccounts = try await accountsRepo.accounts(includeArchived: true).filter { $0.kind == .debt }
    let oldBalances = try await accountsRepo.balances(asOf: Day("2100-01-01")!)

    let result = try await database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: calendar) }
    let book = try await SQLiteDebtRepository(database: database, calendar: calendar).book()
    let after = try await Self.snapshot(database, book: book, calendar: calendar)
    let m = Self.mismatches(before, after)
    // Each person's balance per currency = the sum of the former accounts of that person.
    let balances = Calc.debtBalances(book, calendar: calendar)
    var expected: [String: Int64] = [:]
    for account in debtAccounts {
      expected["\(Debt.personKey(account.name))|\(account.currency.rawValue)", default: 0] += oldBalances[account.id] ?? 0
    }
    var actual: [String: Int64] = [:]
    for debt in book.debts {
      for money in balances[debt.id] ?? [] where money.minorUnits != 0 {
        actual["\(debt.personKey)|\(money.currency.rawValue)"] = money.minorUnits
      }
    }
    let debtMismatches = Set(expected.filter { $0.value != 0 }.keys).union(actual.keys)
      .filter { (expected[$0] ?? 0) != (actual[$0] ?? 0) }.count
    print(
      "Real debt link: debt-kind accounts \(debtAccounts.count) · debts \(book.debts.count) (created \(result.debtsCreated)) · "
        + "links \(book.links.count) · own balance mismatches \(m.own) (SQL \(m.sql)) · net-worth points "
        + "\(after.netWorth.count), mismatches \(m.points) · expense/income equal \(before.expense == after.expense)/"
        + "\(before.income == after.income) · monthly mismatches \(m.months) · debts differing from their account \(debtMismatches)")
    #expect(m.own == 0 && m.sql == 0 && m.points == 0 && m.months == 0)
    #expect(before.expense == after.expense && before.income == after.income)
    #expect(debtMismatches == 0)
    // One debt per person (accounts of one name share it); every debt-kind account is linked.
    #expect(book.debts.count <= debtAccounts.count && book.links.count == debtAccounts.count)

    // Re-importing the same export finds nothing new.
    let again = try await ImportPipeline(
      store: SQLiteImportStore(database: database, calendar: calendar), accounts: accountsRepo,
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database), calendar: calendar
    ).preview(data: data, fileName: "saldo.csv", targetAccountID: nil)
    print("Real debt link: re-import new \(again.counts.new), already imported \(again.counts.alreadyImported)")
    #expect(again.counts.new == 0)
  }

  /// Copies every table of `source` that `target` also has, column by column (the columns both
  /// have), except the debt tables.
  static func copyRows(from source: any DatabaseWriter, to target: any DatabaseWriter) throws {
    let skipped: Set<String> = ["debts", "debtRecords", "debtAccounts"]
    let tables = try source.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
    }.filter { !skipped.contains($0) }
    for table in tables {
      let targetColumns = try target.read { db in try db.tableExists(table) ? try db.columns(in: table).map(\.name) : [] }
      guard !targetColumns.isEmpty else { continue }
      let rows = try source.read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier)") }
      guard let first = rows.first else { continue }
      let columns = first.columnNames.filter { targetColumns.contains($0) }
      let names = columns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
      let marks = Array(repeating: "?", count: columns.count).joined(separator: ", ")
      try target.write { db in
        for row in rows {
          try db.execute(
            sql: "INSERT INTO \(table.quotedDatabaseIdentifier) (\(names)) VALUES (\(marks))",
            arguments: StatementArguments(columns.map { row[$0] as DatabaseValue }))
        }
      }
    }
  }

  @Test("R-DEBT-19, R-DEBT-18: real Saldo through the whole chain (v10 records and legs, then v13) — own balances, net worth and reports equal")
  func realMigrationChain() async throws {
    let calendar = Calendar.current
    let source = try AbacusDatabase.open(at: nil)
    let data = try await Self.importSaldo(source, calendar: calendar)
    let before = try await Self.snapshot(source, book: .empty, calendar: calendar)
    let accountsBefore = try await SQLiteAccountRepository(database: source, calendar: calendar).accounts(includeArchived: true)
    let oldBalances = try await SQLiteAccountRepository(database: source, calendar: calendar).balances(asOf: Day("2100-01-01")!)
    let txnCountBefore = try await SQLiteTxnRepository(database: source, calendar: calendar).transactions(matching: TxnQuery()).count

    // A copy in the pre-debts shape (v9), then v10 (the frozen conversion) up to v12, then v13.
    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let target = try DatabaseQueue(configuration: configuration)
    let migrator = AbacusDatabase.migrator()
    try migrator.migrate(target, upTo: "v9: category createdAt")
    try Self.copyRows(from: source, to: target)
    try migrator.migrate(target, upTo: "v12: rule debt person")
    let v12Debts = try await target.read { db in try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "debts""#) ?? 0 }
    let v12Records = try await target.read { db in try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "debtRecords""#) ?? 0 }
    let result = try await target.write { db in try DebtMigrationV13.run(db) }
    try migrator.migrate(target)  // registers v13 as applied (the run above made it a no-op)

    let book = try await SQLiteDebtRepository(database: target, calendar: calendar).book()
    let after = try await Self.snapshot(target, book: book, calendar: calendar)
    let m = Self.mismatches(before, after)
    let balances = Calc.debtBalances(book, calendar: calendar)
    // Each person's balance per currency = the sum of the former debt accounts of that person.
    var expected: [String: Int64] = [:]
    for account in accountsBefore where account.kind == .debt {
      expected["\(Debt.personKey(account.name))|\(account.currency.rawValue)", default: 0] += oldBalances[account.id] ?? 0
    }
    var actual: [String: Int64] = [:]
    for debt in book.debts {
      for money in balances[debt.id] ?? [] where money.minorUnits != 0 {
        actual["\(debt.personKey)|\(money.currency.rawValue)"] = money.minorUnits
      }
    }
    let debtMismatches = Set(expected.filter { $0.value != 0 }.keys).union(actual.keys)
      .filter { (expected[$0] ?? 0) != (actual[$0] ?? 0) }.count
    let txnCountAfter = try await SQLiteTxnRepository(database: target, calendar: calendar).transactions(matching: TxnQuery()).count
    print(
      "Real migration: v12 debts \(v12Debts) records \(v12Records) → debts \(result.debtsAfter) (merged \(result.mergedDebts), "
        + "flag conflicts \(result.flagConflicts)) · linked source accounts \(result.linkedSourceAccounts) · transfers "
        + "\(result.transfers) (virtual accounts created \(result.virtualAccountsCreated), dropped report flags "
        + "\(result.droppedReportFlags), split lines \(result.splitLines)) · manual records \(result.manualRecords) · "
        + "txns \(txnCountBefore) → \(txnCountAfter)")
    print(
      "Real migration: own balance mismatches \(m.own) (SQL \(m.sql)) · net-worth points \(after.netWorth.count), "
        + "mismatches \(m.points) · expense/income equal \(before.expense == after.expense)/\(before.income == after.income) · "
        + "monthly mismatches \(m.months) · per-person-per-currency balance mismatches \(debtMismatches)")
    #expect(m.own == 0 && m.sql == 0 && m.months == 0)
    #expect(before.expense == after.expense && before.income == after.income)
    #expect(debtMismatches == 0)
    if result.flagConflicts == 0 { #expect(m.points == 0) }
    // Every converted debt account is linked; no leg is left.
    let legsLeft = try await target.read { db in
      try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "txns" WHERE "debtRecordID" IS NOT NULL"#) ?? 0
    }
    #expect(legsLeft == 0)
    // Importing the same export again finds nothing new: fingerprints stayed on transactions and records.
    let reimport = try await ImportPipeline(
      store: SQLiteImportStore(database: target, calendar: calendar),
      accounts: SQLiteAccountRepository(database: target, calendar: calendar),
      categories: SQLiteCategoryRepository(database: target), events: SQLiteEventRepository(database: target),
      rules: SQLiteRuleRepository(database: target), calendar: calendar
    ).preview(data: data, fileName: "saldo.csv", targetAccountID: nil)
    print("Real migration: re-import new \(reimport.counts.new), already imported \(reimport.counts.alreadyImported)")
    #expect(reimport.counts.new == 0)
    #expect(try await target.read { db in try db.columns(in: "debts").contains { $0.name == "currency" } } == false)
  }
}
