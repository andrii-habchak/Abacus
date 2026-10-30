import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// R-DEBT-22: the Transactions debt filter on the synthetic debt sample (Alex: EUR and PLN
/// accounts; Maria: UAH account and a bank account).
@MainActor
@Suite("Transactions · debt filter (C21)")
struct DebtFilterTests {
  static let calendar = Calendar.current

  func model(filters: TransactionFilters = .default) throws -> TransactionsViewModel {
    let database = try DebtSample.database(calendar: Self.calendar)
    return TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      displayCurrency: .PLN, filters: filters, calendar: Self.calendar, today: { PreviewData.today },
      debts: SQLiteDebtRepository(database: database, calendar: Self.calendar))
  }

  let alexAccounts: Set<Account.ID> = [DebtSample.alexEUR.id, DebtSample.alexPLN.id]
  let mariaAccounts: Set<Account.ID> = [DebtSample.mariaUAH.id, DebtSample.mariaBank.id]

  func touched(_ model: TransactionsViewModel) -> Set<Account.ID> {
    Set(model.rows.flatMap { [$0.txn.accountID] + ($0.txn.toAccountID.map { [$0] } ?? []) })
  }

  @Test("R-DEBT-22: picking a debt expands to all its linked accounts as account entries")
  func debtExpandsToAccounts() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    #expect(model.debtOptions.map(\.name).contains("Alex Example"))
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.debtIDs == [DebtSample.alex.id])
    #expect(model.filters.accountIDs == alexAccounts)
    #expect(Set(model.debtAccountChips.map(\.id)) == alexAccounts)
    #expect(model.debtLabel == "Debt: Alex Example")
    #expect(model.accountLabel == "2 accounts")

    await model.reload()
    #expect(!model.rows.isEmpty)
    #expect(model.rows.allSatisfy { !alexAccounts.isDisjoint(with: touched(model).intersection([$0.txn.accountID, $0.txn.toAccountID ?? $0.txn.accountID])) })
    // Maria's accounts are not in the list.
    #expect(touched(model).isDisjoint(with: [DebtSample.mariaUAH.id]))
  }

  @Test("R-DEBT-22: un-ticking one account keeps the debt and the other accounts")
  func unselectOneAccountKeepsTheRest() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    model.toggleDebt(DebtSample.alex.id)
    model.removeAccountEntry(DebtSample.alexPLN.id)
    #expect(model.filters.debtIDs == [DebtSample.alex.id])
    #expect(model.filters.accountIDs == [DebtSample.alexEUR.id])
    #expect(model.debtAccountChips.map(\.id) == [DebtSample.alexEUR.id])
    await model.reload()
    #expect(model.rows.allSatisfy { $0.txn.accountID == DebtSample.alexEUR.id || $0.txn.toAccountID == DebtSample.alexEUR.id })

    // Clearing the debt still removes what it added.
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.accountIDs.isEmpty)
  }

  @Test("R-DEBT-22: every account un-ticked matches nothing, not everything")
  func noAccountLeft() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    model.toggleDebt(DebtSample.alex.id)
    for id in alexAccounts { model.removeAccountEntry(id) }
    #expect(model.filters.isDebtFiltered)
    #expect(model.query == nil)
    await model.reload()
    #expect(model.rows.isEmpty)
  }

  @Test("R-DEBT-22: clearing the debt removes its chips but not accounts selected independently")
  func clearingTheDebt() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    // The user picked Alex's EUR account on their own, plus an unrelated account.
    model.filters.toggleAccount(DebtSample.alexEUR.id)
    model.filters.toggleAccount(PreviewData.pkoPersonal.id)
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.accountIDs == alexAccounts.union([PreviewData.pkoPersonal.id]))
    #expect(model.filters.debtAddedAccountIDs == [DebtSample.alexPLN.id])
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.debtIDs.isEmpty)
    #expect(model.filters.accountIDs == [DebtSample.alexEUR.id, PreviewData.pkoPersonal.id])
    #expect(model.debtAccountChips.isEmpty)
    #expect(model.debtLabel == "All debts")
  }

  @Test("R-DEBT-22: two debts, and Clear filters resets debt and chips")
  func twoDebtsAndClear() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    model.toggleDebt(DebtSample.alex.id)
    model.toggleDebt(DebtSample.maria.id)
    #expect(model.filters.accountIDs == alexAccounts.union(mariaAccounts))
    #expect(model.debtLabel == "2 debts")
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.accountIDs == mariaAccounts)
    model.clearFilters()
    #expect(model.filters == .default)
    #expect(!model.filters.hasActiveFilters)
  }

  @Test("R-DEBT-22: combines with type, search and dates; totals follow the filtered rows")
  func combinesWithOtherFilters() async throws {
    let model = try model()
    await model.load()
    await model.loadDebtOptions()
    model.filters.dateRange = TransactionFilters.allDates
    model.toggleDebt(DebtSample.alex.id)
    await model.reload()
    let all = model.rows.count
    let total = model.content.totals

    model.filters.search = "repaid"
    await model.reload()
    #expect(model.rows.map(\.txn.payee) == ["Alex repaid"])
    #expect(model.content.totals.count == 1)
    #expect(model.rows.count < all)

    model.filters.search = ""
    model.filters.setCustomRange(from: Day("2026-10-01")!, to: Day("2026-10-31")!)
    await model.reload()
    #expect(model.rows.count < all)
    #expect(model.rows.allSatisfy { Day($0.txn.occurredAt, calendar: Self.calendar).string.hasPrefix("2026-10") })

    model.filters.dateRange = TransactionFilters.allDates
    await model.reload()
    #expect(model.content.totals == total)
    #expect(model.filters.hasActiveFilters)
  }

  @Test("R-DEBT-22: the picker is searchable by name")
  func pickerSearch() async throws {
    let model = try model()
    await model.loadDebtOptions()
    #expect(Set(model.debtOptions(matching: "").map(\.id)).isSuperset(of: DebtSample.debts.map(\.id)))
    let names = model.debtOptions.map(\.name)
    #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    #expect(model.debtOptions(matching: " alex ").map(\.id) == [DebtSample.alex.id])
    #expect(model.debtOptions(matching: "MARIA").map(\.id) == [DebtSample.maria.id])
    #expect(model.debtOptions(matching: "zzz").isEmpty)
  }

  @Test("R-DEBT-22: filters(showingDebt:) selects the debt and its accounts over every date")
  func filtersForDebt() async throws {
    let model = try model()
    let filters = try #require(await model.filters(showingDebt: DebtSample.maria.id))
    #expect(filters == .debt(DebtSample.maria.id, accountIDs: mariaAccounts))
    #expect(filters.accountIDs == mariaAccounts)
    #expect(filters.dateRange == TransactionFilters.allDates)
    #expect(await model.filters(showingDebt: UUID()) == nil)
  }

  @Test("R-DEBT-22: the shell entry point opens Transactions with the debt filter")
  func entryPoint() async throws {
    let database = try DebtSample.database(calendar: Self.calendar)
    let session = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    defer { session.stop() }
    await session.showTransactions(ofDebt: DebtSample.alex.id).value
    #expect(session.app.section == .transactions)
    let filters = try #require(session.app.pendingTransactionFilters)
    #expect(filters.debtIDs == [DebtSample.alex.id])
    #expect(filters.accountIDs == alexAccounts)

    // An unknown debt does nothing.
    session.app.pendingTransactionFilters = nil
    await session.showTransactions(ofDebt: UUID()).value
    #expect(session.app.pendingTransactionFilters == nil)

    // Applied the way the shell does: the list shows only that debt's accounts.
    session.transactions.filters = filters
    await session.transactions.load()
    #expect(session.transactions.debtLabel == "Debt: Alex Example")
    #expect(!session.transactions.rows.isEmpty)
  }
}
