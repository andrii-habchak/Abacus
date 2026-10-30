import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C28: what opening Transactions with "All dates" costs on 5,000 and 20,000 synthetic rows
/// (model side only: fetch + content; the AppKit table is measured in the running app). Prints
/// `C28 <case> <step> <ms>`; asserts only a loose bound so the suite stays stable.
@MainActor
@Suite("Transactions list benchmark (C28)", .serialized)
struct TransactionsListBenchmarkTests {
  nonisolated static let today = Day(year: 2026, month: 10, day: 21)
  static let calendar = Calendar.current

  func model(count: Int) throws -> TransactionsViewModel {
    let database = try LargeSampleData.database(
      size: .init(transactions: count), today: Self.today, calendar: Self.calendar)
    return TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      displayCurrency: .PLN, filters: TransactionFilters(dateRange: TransactionFilters.allDates),
      calendar: Self.calendar, today: { Self.today },
      debts: SQLiteDebtRepository(database: database, calendar: Self.calendar))
  }

  func ms(_ work: () async -> Void) async -> Int {
    let clock = ContinuousClock()
    let start = clock.now
    await work()
    let d = clock.now - start
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
  }

  @Test("All dates: time to first rows, filter change", arguments: [5_000, 20_000])
  func allDates(count: Int) async throws {
    let model = try model(count: count)
    let first = await ms { await model.load() }
    print("C28 \(count) first-rows(load) \(first) ms; loaded \(model.rows.count) of \(model.content.totals.count)")
    let more = await ms { await model.loadMore() }
    print("C28 \(count) next-page(loadMore) \(more) ms; loaded \(model.rows.count)")
    model.filters.search = "a"
    let search = await ms { await model.reload() }
    print("C28 \(count) filter-change(search) \(search) ms; loaded \(model.rows.count)")
    model.filters.search = ""
    model.filters.types = [.expense]
    let types = await ms { await model.reload() }
    print("C28 \(count) filter-change(type) \(types) ms; loaded \(model.rows.count)")
    #expect(first < 60_000)
  }
}
