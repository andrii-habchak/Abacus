import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Transactions and the list query")
struct TxnRepositoryTests {
  typealias F = StoreFixture

  /// A small month of data used by the filter tests.
  static func seeded() async throws -> F {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-01", 40_00, F.groceries, payee: "Żabka", note: "milk"))
    try await f.insert(
      F.expense(101, "2026-03-02", 60_00, F.eatingOut, account: F.card, payee: "Bistro", event: F.trip),
      lines: [AttachedRecord(txnID: F.id(101), kind: .expense, categoryID: F.fees.id, amountMinor: 3_00, note: "FX fee")])
    try await f.insert(F.income(102, "2026-03-03", 1_000_00, F.salary, payee: "Employer"))
    try await f.insert(F.transfer(103, "2026-03-04", from: F.bank, to: F.loan, 100_00))
    try await f.insert(F.expense(104, "2026-03-05", 15_00, F.transport, payee: "Metro", event: F.trip))
    try await f.insert(F.expense(105, "2026-03-06", 10_00, F.groceries, payee: "Żabka", refund: true))
    try await f.insert(F.expense(106, "2026-02-20", 25_00, F.food, payee: "Market"))
    return f
  }

  func ids(_ rows: [TxnWithLines]) -> [Int] {
    rows.map { Int($0.txn.id.uuidString.suffix(12))! }
  }

  @Test("R-TX-6: saving replaces attached records; deleting removes them with the parent")
  func attachedRecords() async throws {
    let f = try F()
    try f.seedBasics()
    let txn = F.expense(100, "2026-03-01", 40_00, F.groceries)
    try await f.txns.save(txn, lines: [
      AttachedRecord(txnID: UUID(), kind: .expense, categoryID: F.fees.id, amountMinor: 1_00),
      AttachedRecord(txnID: UUID(), kind: .income, categoryID: F.cashback.id, amountMinor: 50),
    ])
    var row = try #require(try await f.txns.transaction(txn.id))
    #expect(row.lines.count == 2)
    #expect(row.lines.allSatisfy { $0.txnID == txn.id })
    #expect(row.lines.map(\.position) == [0, 1])

    var edited = txn
    edited.amountMinor = 45_00
    try await f.txns.save(edited, lines: [AttachedRecord(txnID: txn.id, categoryID: F.fees.id, amountMinor: 2_00)])
    row = try #require(try await f.txns.transaction(txn.id))
    #expect(row.txn.amountMinor == 45_00)
    #expect(row.lines.map(\.amountMinor) == [2_00])

    try await f.txns.delete(txn.id)
    #expect(try await f.txns.transaction(txn.id) == nil)
    let orphanLines = try await f.database.read { db in try AttachedRecord.fetchCount(db) }
    #expect(orphanLines == 0)
    await #expect(throws: RepositoryError.notFound) { try await f.txns.delete(txn.id) }
  }

  @Test("R-LIST-1: the default query is the last 30 days, newest first")
  func lastThirtyDays() async throws {
    let f = try await Self.seeded()
    try await f.insert(F.expense(107, "2026-02-04", 1_00, F.groceries))  // 31 days before 2026-03-06
    try await f.insert(F.expense(108, "2026-02-05", 1_00, F.groceries))  // 30th day back
    let rows = try await f.txns.transactions(matching: .lastThirtyDays(today: Day("2026-03-06")!))
    #expect(ids(rows) == [105, 104, 103, 102, 101, 100, 106, 108])
  }

  @Test("R-LIST-2: date range is inclusive calendar days in the user's time zone")
  func dateRange() async throws {
    let f = try await Self.seeded()
    // 00:30 local on 2026-03-07 is still 2026-03-06 in UTC.
    try await f.insert(F.expense(107, "2026-03-07", 1_00, F.groceries, time: "00:30"))
    try await f.insert(F.expense(108, "2026-03-06", 1_00, F.groceries, time: "23:59"))
    let rows = try await f.txns.transactions(matching: TxnQuery(fromDay: Day("2026-03-05"), toDay: Day("2026-03-06")))
    #expect(ids(rows) == [108, 105, 104])
  }

  @Test("R-LIST-2: a parent category selects its children; attached-record categories match")
  func categoryFilter() async throws {
    let f = try await Self.seeded()
    let food = try await f.txns.transactions(matching: TxnQuery(categoryIDs: [F.food.id]))
    #expect(ids(food) == [105, 101, 100, 106])
    let fees = try await f.txns.transactions(matching: TxnQuery(categoryIDs: [F.fees.id]))
    #expect(ids(fees) == [101])
    #expect(fees.first?.lines.count == 1)
    let child = try await f.txns.transactions(matching: TxnQuery(categoryIDs: [F.groceries.id, F.transport.id]))
    #expect(ids(child) == [105, 104, 100])
  }

  @Test("R-LIST-2: account (either side of a transfer), type and event filters combine")
  func otherFilters() async throws {
    let f = try await Self.seeded()
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.loan.id]))) == [103])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(accountIDs: [F.card.id, F.loan.id]))) == [103, 101])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(types: [.income, .transfer]))) == [103, 102])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(eventIDs: [F.trip.id]))) == [104, 101])
    let combined = TxnQuery(
      fromDay: Day("2026-03-01"), toDay: Day("2026-03-31"), categoryIDs: [F.food.id],
      accountIDs: [F.bank.id], types: [.expense])
    #expect(ids(try await f.txns.transactions(matching: combined)) == [105, 100])
  }

  @Test("R-EVT-3: the list can be filtered by event")
  func eventFilter() async throws {
    let f = try await Self.seeded()
    let rows = try await f.txns.transactions(matching: TxnQuery(eventIDs: [F.trip.id]))
    #expect(rows.allSatisfy { $0.txn.eventID == F.trip.id })
    #expect(rows.count == 2)
  }

  @Test("R-LIST-3: sort by date ascending or descending")
  func sort() async throws {
    let f = try await Self.seeded()
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(newestFirst: true))) == [105, 104, 103, 102, 101, 100, 106])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(newestFirst: false))) == [106, 100, 101, 102, 103, 104, 105])
  }

  @Test("R-LIST-6: case-insensitive search over description and note, Unicode included")
  func search() async throws {
    let f = try await Self.seeded()
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(search: "żAB"))) == [105, 100])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(search: "MILK"))) == [100])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(search: "fx fee"))) == [101])
    #expect(ids(try await f.txns.transactions(matching: TxnQuery(search: "  metro "))) == [104])
    #expect(try await f.txns.transactions(matching: TxnQuery(search: "%")).isEmpty)
  }

  @Test("R-LIST-5, R-TX-4: totals of the filtered set; refunds as income unless the setting says otherwise")
  func totals() async throws {
    let f = try await Self.seeded()
    let converter = FixedConverter(rates: ["EURPLN": 4])
    let march = TxnQuery(fromDay: Day("2026-03-01"), toDay: Day("2026-03-31"))

    // Off (default): the 10.00 refund is income.
    var result = try await f.txns.list(matching: march)
    #expect(result.rows.count == 6)
    var sums = result.totals.converted(to: .PLN, using: converter)
    // Expense: 40 + (60 + 3) × 4 + 15 = 307; income: 1000 + 10.
    #expect(sums.expense == Money(minorUnits: 307_00, currency: .PLN))
    #expect(sums.income == Money(minorUnits: 1_010_00, currency: .PLN))
    #expect(sums.net == Money(minorUnits: 703_00, currency: .PLN))
    #expect(sums.unconverted == 0)

    // R-SET-3 on: the refund reduces expense.
    try await f.settings.set(.refundsReduceSpending, "true")
    result = try await f.txns.list(matching: march)
    sums = result.totals.converted(to: .PLN, using: converter)
    #expect(sums.expense == Money(minorUnits: 297_00, currency: .PLN))
    #expect(sums.income == Money(minorUnits: 1_000_00, currency: .PLN))

    // A category filter counts only the matching parts: the fee line, not its parent's amount.
    result = try await f.txns.list(matching: TxnQuery(categoryIDs: [F.fees.id]))
    sums = result.totals.converted(to: .PLN, using: converter)
    #expect(sums.expense == Money(minorUnits: 12_00, currency: .PLN))

    // Missing rates are reported, not guessed.
    sums = try await f.txns.list(matching: march).totals.converted(to: .PLN, using: FixedConverter(rates: [:]))
    #expect(sums.unconverted == 1)
  }
}
