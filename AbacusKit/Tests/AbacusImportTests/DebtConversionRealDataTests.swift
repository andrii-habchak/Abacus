import AbacusDomain
import AbacusStore
import AbacusTestSupport
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// R-DEBT-8 on the owner's real Saldo export, in memory: imported the pre-v10 way (debt
/// accounts with transfers), then converted exactly as migration "v10: debts" does. Prints
/// counts only — never names, amounts or descriptions (R-NF-6).
@Suite("Debt conversion — real export", .tags(.realData), .enabled(if: RealSamples.has(prefix: "saldo")))
struct DebtConversionRealDataTests {
  /// Any fixed rate per pair: the invariants hold at every rate.
  struct AnyRates: CurrencyConverter {
    static let perUAH: [Currency: Decimal] = [.UAH: 1, .PLN: Decimal(string: "10.5")!, .EUR: 44, .USD: 41]
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { Self.perUAH[from]! / Self.perUAH[to]! }
    func latestRate(from: Currency, to: Currency) -> Decimal? { Self.perUAH[from]! / Self.perUAH[to]! }
    var latestDay: Day? { nil }
  }

  @Test("R-DEBT-8: real Saldo — own balances, net worth history and reports unchanged by the conversion")
  func realConversionInvariants() async throws {
    let calendar = Calendar.current
    let database = try AbacusDatabase.open(at: nil)
    let store = SQLiteImportStore(database: database, calendar: calendar, convertsDebtAccounts: false)
    let accountsRepo = SQLiteAccountRepository(database: database, calendar: calendar)
    let txnsRepo = SQLiteTxnRepository(database: database, calendar: calendar)
    let pipeline = ImportPipeline(
      store: store, accounts: accountsRepo, categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), rules: SQLiteRuleRepository(database: database),
      calendar: calendar)
    let data = try Data(contentsOf: try #require(RealSamples.file(prefix: "saldo")))
    var preview = try await pipeline.preview(data: data, fileName: "saldo.csv", targetAccountID: nil)
    preview.acceptSuggestedReviewChoices()
    _ = try await pipeline.commit(preview)

    let today = Day(Date(), calendar: calendar)
    let categories = try await SQLiteCategoryRepository(database: database).categories(kind: nil, includeArchived: true)
    func snapshot(_ book: DebtBook) async throws -> (
      own: [Account.ID: Int64], sql: [Account.ID: Int64], netWorth: [Int64], expense: Int64, income: Int64,
      monthly: [Int64]
    ) {
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
      return (
        balances.filter { ownIDs.contains($0.key) }.mapValues(\.minorUnits), sql.filter { ownIDs.contains($0.key) },
        series.points.map(\.value.minorUnits), total(.expense, nil), total(.income, nil),
        months.map { total(.expense, $0.firstDay...$0.lastDay(calendar: calendar)) }
      )
    }

    let before = try await snapshot(.empty)
    let debtAccountsBefore = try await accountsRepo.accounts(includeArchived: true).filter { $0.kind == .debt }
    let txnCountBefore = try await txnsRepo.transactions(matching: TxnQuery()).count
    let oldBalances = try await accountsRepo.balances(asOf: Day("2100-01-01")!)

    let result = try await database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: calendar) }
    let book = try await SQLiteDebtRepository(database: database, calendar: calendar).book()
    let after = try await snapshot(book)

    let ownMismatches = Set(before.own.keys).union(after.own.keys).filter { before.own[$0] != after.own[$0] }.count
    let sqlMismatches = Set(before.sql.keys).union(after.sql.keys).filter { before.sql[$0] != after.sql[$0] }.count
    let pointMismatches = zip(before.netWorth, after.netWorth).filter { $0 != $1 }.count
    let monthMismatches = zip(before.monthly, after.monthly).filter { $0 != $1 }.count
    let debtBalances = Calc.debtBalances(book)
    print(
      "Real debt conversion: debt accounts \(debtAccountsBefore.count) · debts \(book.debts.count) · records "
        + "\(result.records) · legs \(result.legs) · replaced txns \(result.replacedTxns) · dropped reports "
        + "\(result.droppedReports) · disabled rules \(result.disabledRules) · non-zero debts "
        + "\(debtBalances.values.filter { $0.minorUnits != 0 }.count) · txns \(txnCountBefore) → "
        + "\(try await txnsRepo.transactions(matching: TxnQuery()).count)")
    print(
      "Real debt conversion: own accounts \(before.own.count), balance mismatches \(ownMismatches) (SQL \(sqlMismatches)); "
        + "net-worth points \(after.netWorth.count), mismatches \(pointMismatches); expense/income totals equal "
        + "\(before.expense == after.expense)/\(before.income == after.income); monthly expense mismatches \(monthMismatches)")
    #expect(ownMismatches == 0)
    #expect(sqlMismatches == 0)
    #expect(pointMismatches == 0)
    #expect(before.expense == after.expense)
    #expect(before.income == after.income)
    #expect(monthMismatches == 0)
    #expect(book.debts.count == debtAccountsBefore.count)
    #expect(book.debts.allSatisfy(\.countsInNetWorth) == debtAccountsBefore.allSatisfy { !$0.isArchived })

    // Each debt equals its former account's balance; the accounts are empty and archived.
    let accounts = try await accountsRepo.accounts(includeArchived: true)
    let txns = try await txnsRepo.transactions(matching: TxnQuery())
    let debtMismatches = book.debts.filter { debt in
      debtBalances[debt.id]?.minorUnits != debt.sourceAccountID.flatMap { oldBalances[$0] }
    }.count
    print("Real debt conversion: debts whose balance differs from the former account: \(debtMismatches)")
    #expect(debtMismatches == 0)
    for account in accounts where account.kind == .debt {
      #expect(account.isArchived && account.openingBalanceMinor == 0)
      #expect(!txns.contains { $0.txn.accountID == account.id || $0.txn.toAccountID == account.id })
    }

    // Re-importing the same export finds nothing new (fingerprints on legs and records).
    let again = try await ImportPipeline(
      store: SQLiteImportStore(database: database, calendar: calendar), accounts: accountsRepo,
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database), calendar: calendar
    ).preview(data: data, fileName: "saldo.csv", targetAccountID: nil)
    print("Real debt conversion: re-import new \(again.counts.new), already imported \(again.counts.alreadyImported)")
    #expect(again.counts.new == 0)
  }
}
