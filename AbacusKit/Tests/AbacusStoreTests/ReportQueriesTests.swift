import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Dashboard aggregations")
struct ReportQueriesTests {
  typealias F = StoreFixture

  static func seeded() async throws -> F {
    let f = try F()
    try f.seedBasics()
    try await f.insert(
      F.expense(100, "2026-03-01", 40_00, F.groceries),
      lines: [
        AttachedRecord(txnID: F.id(100), kind: .expense, categoryID: F.fees.id, amountMinor: 2_00),
        AttachedRecord(txnID: F.id(100), kind: .income, categoryID: F.cashback.id, amountMinor: 1_00),
      ])
    try await f.insert(F.expense(101, "2026-03-02", 10_00, F.eatingOut, account: F.card, event: F.trip))
    try await f.insert(F.expense(102, "2026-03-03", 5_00, F.groceries, refund: true))
    try await f.insert(F.income(103, "2026-03-04", 1_000_00, F.salary))
    try await f.insert(
      F.transfer(104, "2026-03-05", from: F.bank, to: F.card, 43_00, received: 10_00),
      lines: [AttachedRecord(txnID: F.id(104), kind: .expense, categoryID: F.fees.id, amountMinor: 1_00)])
    try await f.insert(F.expense(105, "2026-03-31", 7_00, F.transport, time: "23:30"))  // still March locally
    try await f.insert(F.expense(106, "2026-04-01", 99_00, F.transport, time: "00:30"))  // April locally, March in UTC
    return f
  }

  func sums(_ amounts: [CategoryAmount]) -> [UUID?: Int64] {
    amounts.reduce(into: [:]) { $0[$1.categoryID, default: 0] += $1.amountMinor }
  }

  @Test("R-HOME-3, R-TX-6: monthly expenses by category include attached records; transfers are not spending")
  func monthlyExpenses() async throws {
    let f = try await Self.seeded()
    let report = try await f.reports.monthlySpending(Month(year: 2026, month: 3))
    #expect(sums(report.expenses) == [F.groceries.id: 40_00, F.fees.id: 3_00, F.eatingOut.id: 10_00, F.transport.id: 7_00])
    #expect(sums(report.income) == [F.salary.id: 1_000_00, F.cashback.id: 1_00])
    #expect(report.expenses.first { $0.categoryID == F.eatingOut.id }?.currency == .EUR)
    #expect(report.expenses.first { $0.categoryID == F.eatingOut.id }?.day == Day("2026-03-02"))
  }

  @Test("R-TX-4, R-SET-3: refunds are income by default and reduce spending when the setting is on")
  func refunds() async throws {
    let f = try await Self.seeded()
    let march = Month(year: 2026, month: 3)
    var report = try await f.reports.monthlySpending(march)
    #expect(sums(report.expenses)[F.groceries.id] == 40_00)
    #expect(sums(report.refunds) == [F.groceries.id: 5_00])

    try await f.settings.set(.refundsReduceSpending, "true")
    report = try await f.reports.monthlySpending(march)
    #expect(sums(report.expenses)[F.groceries.id] == 35_00)
    #expect(report.refunds.isEmpty)

    // An explicit argument wins over the setting.
    report = try await f.reports.monthlySpending(march, refundsReduceSpending: false)
    #expect(sums(report.expenses)[F.groceries.id] == 40_00)
  }

  @Test("R-BUD-2, R-CAT-2: spent per category in the budget currency, children rolled up into parents")
  func budgetSpent() async throws {
    let f = try await Self.seeded()
    let report = try await f.reports.monthlySpending(Month(year: 2026, month: 3))
    let categories = try await f.categories.categories(kind: nil, includeArchived: true)
    let (totals, unconverted) = report.expenses.rolledUpToParents(categories)
      .totalsByCategory(in: .PLN, using: FixedConverter(rates: ["EURPLN": 4]))
    #expect(unconverted == 0)
    // Food = groceries 40 + eating out 10 EUR × 4.
    #expect(totals[F.food.id] == Money(minorUnits: 80_00, currency: .PLN))
    #expect(totals[F.fees.id] == Money(minorUnits: 3_00, currency: .PLN))
    #expect(totals[F.groceries.id] == nil)
  }

  @Test("R-EVT-3: an event's spending by category")
  func eventSpending() async throws {
    let f = try await Self.seeded()
    let report = try await f.reports.spending(eventID: F.trip.id)
    #expect(sums(report.expenses) == [F.eatingOut.id: 10_00])
    let (totals, _) = report.expenses.totalsByCategory(in: .PLN, using: FixedConverter(rates: ["EURPLN": 4]))
    #expect(totals.values.reduce(Money.zero(.PLN), +) == Money(minorUnits: 40_00, currency: .PLN))
  }

  @Test("R-HOME-1, R-ACC-4: month-end balances per account; archived accounts excluded from net worth")
  func netWorth() async throws {
    let f = try await Self.seeded()
    let days = SQLiteReportQueries.netWorthDays(from: Month(year: 2026, month: 2), today: Day("2026-04-15")!, calendar: F.calendar)
    #expect(days == [Day("2026-02-28")!, Day("2026-03-31")!, Day("2026-04-15")!])

    let series = try await f.reports.netWorthSeries(from: Month(year: 2026, month: 2), today: Day("2026-04-15")!)
    #expect(series.days == days)
    // Bank: 1000 → 1000 − 40 − 2 + 1 + 5 + 1000 − 43 − 1 − 7 = 1913 → − 99.
    #expect(series.balances[F.bank.id] == [1_000_00, 1_913_00, 1_814_00])
    #expect(series.balances[F.card.id] == [0, 0, 0])  // −10 spent, +10 received
    #expect(series.balances[F.loan.id] == [-500_00, -500_00, -500_00])

    let converter = FixedConverter(rates: ["EURPLN": 4], latest: ["EURPLN": 5])
    #expect(series.netWorth(in: .PLN, using: converter).map { $0?.minorUnits } == [500_00, 1_413_00, 1_314_00])

    try await f.accounts.setArchived(F.loan.id, true)
    let active = try await f.reports.netWorthSeries(from: Month(year: 2026, month: 3), today: Day("2026-03-20")!)
    #expect(active.accounts.map(\.id) == [F.bank.id, F.card.id])
    #expect(active.netWorth(in: .PLN, using: converter).map { $0?.minorUnits } == [1_920_00])
  }

  @Test("R-HOME-1: the last point uses the latest rate, earlier points their day's rate")
  func netWorthRates() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.income(100, "2026-03-10", 100_00, F.salary, account: F.card))
    let series = try await f.reports.netWorthSeries(from: Month(year: 2026, month: 3), today: Day("2026-04-02")!)
    let converter = FixedConverter(rates: ["EURPLN": 4], latest: ["EURPLN": 5])
    // Bank 1000 + loan −500 + card 100 EUR.
    #expect(series.netWorth(in: .PLN, using: converter).map { $0?.minorUnits } == [900_00, 1_000_00])
    #expect(series.netWorth(in: .PLN, using: FixedConverter(rates: [:])) == [nil, nil])
  }

  @Test("R-ACC-3: an account counts its opening balance only from its opening date")
  func openingDate() async throws {
    let f = try F()
    try f.seedBasics()
    let later = Account(name: "New", currency: .PLN, kind: .cash, openingBalanceMinor: 50_00, openingDate: F.at("2026-03-15"))
    try await f.accounts.save(later)
    let series = try await f.reports.balances(on: [Day("2026-03-14")!, Day("2026-03-15")!])
    #expect(series.balances[later.id] == [0, 50_00])
  }
}
