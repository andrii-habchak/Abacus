import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Accounts")
struct AccountRepositoryTests {
  typealias F = StoreFixture

  @Test("R-ACC-4: archived accounts are hidden unless asked for and can be unarchived")
  func archive() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.accounts.setArchived(F.card.id, true)
    #expect(try await f.accounts.accounts(includeArchived: false).map(\.id) == [F.bank.id, F.loan.id])
    #expect(try await f.accounts.accounts(includeArchived: true).count == 3)
    try await f.accounts.setArchived(F.card.id, false)
    #expect(try await f.accounts.accounts(includeArchived: false).count == 3)
    await #expect(throws: RepositoryError.notFound) { try await f.accounts.setArchived(F.id(999), true) }
  }

  @Test("R-ACC-4: archiving keeps history")
  func archiveKeepsHistory() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, account: F.card))
    try await f.accounts.setArchived(F.card.id, true)
    #expect(try await f.txns.transactions(matching: TxnQuery()).count == 1)
  }

  @Test("R-ACC-5: an account with transactions cannot be deleted; an unused one can")
  func deleteRules() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.transfer(100, "2026-03-02", from: F.bank, to: F.loan, 50_00))
    await #expect(throws: RepositoryError.accountHasTransactions) { try await f.accounts.delete(F.bank.id) }
    // The receiving side of a transfer counts as use too.
    await #expect(throws: RepositoryError.accountHasTransactions) { try await f.accounts.delete(F.loan.id) }
    try await f.accounts.delete(F.card.id)
    #expect(try await f.accounts.accounts(includeArchived: true).map(\.id) == [F.bank.id, F.loan.id])
    await #expect(throws: RepositoryError.notFound) { try await f.accounts.delete(F.card.id) }
  }

  @Test("R-ACC-1: save inserts and updates; currency is fixed after the first transaction")
  func saveAndCurrencyLock() async throws {
    let f = try F()
    try f.seedBasics()
    var card = F.card
    card.name = "Travel card"
    card.currency = .USD
    try await f.accounts.save(card)  // no transactions yet: currency may change
    #expect(try await f.accounts.accounts(includeArchived: true).first { $0.id == card.id }?.currency == .USD)
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, account: card))
    card.currency = .EUR
    await #expect(throws: StoreError.currencyLocked) { try await f.accounts.save(card) }
    card.currency = .USD
    card.name = "Renamed"
    try await f.accounts.save(card)
    #expect(try await f.accounts.accounts(includeArchived: true).first { $0.id == card.id }?.name == "Renamed")
  }

  @Test("R-ACC-3: balance = opening balance + transaction effects incl. transfers, refunds and attached records")
  func balances() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(
      F.expense(100, "2026-03-02", 100_00, F.groceries),
      lines: [
        AttachedRecord(txnID: F.id(100), kind: .expense, categoryID: F.fees.id, amountMinor: 2_00),
        AttachedRecord(txnID: F.id(100), kind: .income, categoryID: F.cashback.id, amountMinor: 1_00),
      ])
    try await f.insert(F.expense(101, "2026-03-03", 30_00, F.groceries, refund: true))
    try await f.insert(F.income(102, "2026-03-04", 500_00, F.salary))
    try await f.insert(F.income(103, "2026-03-05", 20_00, F.salary, reversal: true))
    try await f.insert(F.transfer(104, "2026-03-06", from: F.bank, to: F.card, 430_00, received: 100_00))
    try await f.insert(F.transfer(105, "2026-03-07", from: F.bank, to: F.loan, 200_00))
    try await f.insert(F.expense(106, "2026-04-01", 5_00, F.groceries))  // after the date asked

    let balances = try await f.accounts.balances(asOf: Day("2026-03-31")!)
    // 1000 − 100 − 2 + 1 + 30 + 500 − 20 − 430 − 200
    #expect(balances[F.bank.id] == 779_00)
    #expect(balances[F.card.id] == 100_00)
    #expect(balances[F.loan.id] == -300_00)
  }
}
