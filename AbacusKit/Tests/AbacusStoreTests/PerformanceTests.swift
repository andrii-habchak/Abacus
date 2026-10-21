import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Performance")
struct PerformanceTests {
  typealias F = StoreFixture

  /// R-NF-2: 200 ms, the target for the shipped (optimised) build. Unoptimised test builds
  /// decode rows about 2.3× slower (measured: the 5 000-row query takes ~80 ms optimised and
  /// ~180 ms unoptimised), so plain `swift test` gets twice the budget to stay stable on CI;
  /// `swift test -c release` checks the real target.
  #if DEBUG
    static let budget = Duration.milliseconds(400)
  #else
    static let budget = Duration.milliseconds(200)
  #endif

  /// 20 000 synthetic transactions over two years: expenses, income, transfers, refunds, every
  /// tenth with an attached record, some in an event.
  static func seed20k(_ f: F) async throws {
    try f.seedBasics()
    let payees = ["Shop", "Market", "Cafe", "Metro", "Pharmacy", "Cinema", "Bakery", "Fuel"]
    let expenseCategories = [F.groceries, F.eatingOut, F.food, F.transport, F.fees]
    let start = F.at("2024-10-22")
    var rows: [TxnWithLines] = []
    rows.reserveCapacity(20_000)
    for n in 0..<20_000 {
      let id = UUID()
      let occurredAt = start.addingTimeInterval(Double(n) * 3_150)  // ~ 27 per day
      let account = [F.bank, F.card, F.loan][n % 3]
      var txn: Txn
      switch n % 20 {
      case 0:
        txn = Txn(id: id, type: .income, occurredAt: occurredAt, accountID: F.bank.id, amountMinor: 5_000_00, categoryID: F.salary.id, payee: "Employer")
      case 1:
        txn = Txn(id: id, type: .transfer, occurredAt: occurredAt, accountID: F.bank.id, amountMinor: 100_00, toAccountID: F.card.id, toAmountMinor: 23_00)
      default:
        txn = Txn(
          id: id, type: .expense, occurredAt: occurredAt, accountID: account.id, amountMinor: Int64(100 + n % 9_000),
          categoryID: expenseCategories[n % expenseCategories.count].id, isRefund: n % 50 == 7,
          payee: "\(payees[n % payees.count]) \(n % 97)", note: n % 7 == 0 ? "note \(n)" : "",
          eventID: n % 40 == 3 ? F.trip.id : nil)
      }
      txn.createdAt = occurredAt
      let lines = n % 10 == 2 ? [AttachedRecord(txnID: id, categoryID: F.fees.id, amountMinor: 1_00, note: "fee")] : []
      rows.append(TxnWithLines(txn: txn, lines: lines))
    }
    try await f.imports.commit(ImportCommit(batch: ImportBatch(source: .saldo, fileName: "synthetic.csv"), txns: rows))
  }

  func measure(_ body: () async throws -> Void) async rethrows -> Duration {
    // Best of three: the first run warms SQLite's page cache and statement cache.
    var best = Duration.seconds(1_000)
    for _ in 0..<3 {
      let start = ContinuousClock.now
      try await body()
      best = min(best, ContinuousClock.now - start)
    }
    return best
  }

  @Test("R-NF-2: list query with filters, search and totals over 20 000 transactions < 200 ms")
  func listQuery20k() async throws {
    let f = try F()
    let seedStart = ContinuousClock.now
    try await Self.seed20k(f)
    let seedTime = ContinuousClock.now - seedStart
    #expect(seedTime < .seconds(10), "committing 20 000 transactions took \(seedTime)")

    let today = Day("2026-10-21")!
    let queries: [(String, TxnQuery)] = [
      ("last 30 days", .lastThirtyDays(today: today)),
      ("search", TxnQuery(fromDay: Day("2024-01-01"), toDay: today, search: "market 1")),
      ("parent category, one year", TxnQuery(fromDay: Day("2025-10-21"), toDay: today, categoryIDs: [F.food.id])),
      ("account + type, one year", TxnQuery(fromDay: Day("2025-10-21"), toDay: today, accountIDs: [F.card.id], types: [.expense])),
      ("event", TxnQuery(eventIDs: [F.trip.id])),
      ("attached-record category", TxnQuery(fromDay: Day("2026-01-01"), toDay: today, categoryIDs: [F.fees.id])),
    ]
    for (name, query) in queries {
      var count = 0
      let time = try await measure {
        let result = try await f.txns.list(matching: query)
        count = result.rows.count
      }
      #expect(count > 0, "\(name) returned nothing")
      #expect(time < Self.budget, "\(name): \(count) rows in \(time)")
    }
  }

  @Test("R-NF-2: dashboard aggregations over 20 000 transactions < 200 ms")
  func dashboard20k() async throws {
    let f = try F()
    try await Self.seed20k(f)
    let monthly = try await measure { _ = try await f.reports.monthlySpending(Month(year: 2026, month: 9)) }
    #expect(monthly < Self.budget, "monthly spending: \(monthly)")
    let netWorth = try await measure {
      _ = try await f.reports.netWorthSeries(from: Month(year: 2024, month: 10), today: Day("2026-10-21")!)
    }
    #expect(netWorth < Self.budget, "net worth series: \(netWorth)")
  }
}
