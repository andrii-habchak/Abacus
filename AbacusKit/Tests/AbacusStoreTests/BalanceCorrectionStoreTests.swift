import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C29, R-ACC-4: `txns.isBalanceCorrection` (schema v14) survives the store and the SQL report
/// query skips it.
@Suite("Balance correction flag (v14)")
struct BalanceCorrectionStoreTests {
  typealias F = StoreFixture

  @Test("R-ACC-4: the flag round-trips and defaults to false")
  func roundTrip() async throws {
    let f = try F()
    try f.seedBasics()
    var flagged = F.expense(100, "2026-03-02", 10_00, F.groceries)
    flagged.isBalanceCorrection = true
    try await f.insert(flagged)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries))
    #expect(try await f.txns.transaction(F.id(100))?.txn.isBalanceCorrection == true)
    #expect(try await f.txns.transaction(F.id(101))?.txn.isBalanceCorrection == false)
  }

  @Test("R-ACC-4: the SQL spending report leaves a correction out")
  func spendingQuery() async throws {
    let f = try F()
    try f.seedBasics()
    var flagged = F.expense(100, "2026-03-02", 10_00, F.groceries)
    flagged.isBalanceCorrection = true
    try await f.insert(flagged)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries))
    let report = try await SQLiteReportQueries(database: f.database).monthlySpending(Month("2026-03")!)
    #expect(report.expenses.map(\.amountMinor).reduce(0, +) == 20_00)
  }
}
