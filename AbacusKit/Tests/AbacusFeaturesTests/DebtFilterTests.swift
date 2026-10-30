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
    #expect(model.filters.debtAddedAccountIDs == alexAccounts)
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
    model.filters.toggleAccount(DebtSample.alexPLN.id)
    #expect(model.filters.debtIDs == [DebtSample.alex.id])
    #expect(model.filters.accountIDs == [DebtSample.alexEUR.id])
    #expect(model.filters.debtAddedAccountIDs == [DebtSample.alexEUR.id])
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
    for id in alexAccounts { model.filters.toggleAccount(id) }
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
    // C24: the unrelated account is dropped when the debt is applied; the linked one stays.
    #expect(model.filters.accountIDs == alexAccounts)
    #expect(model.filters.debtAddedAccountIDs == [DebtSample.alexPLN.id])
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.debtIDs.isEmpty)
    #expect(model.filters.accountIDs == [DebtSample.alexEUR.id])
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
    var expected = TransactionFilters.debt(DebtSample.maria.id, accountIDs: mariaAccounts)
    expected.dateRangeBeforeDebt = TransactionFilters.default.dateRange  // C28: remembered
    #expect(filters == expected)
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

  // MARK: C24 — debt filter fixes (docs/status/C24.md)

  /// A person whose three accounts all carry their name, one per currency (the owner's case).
  static let kittyDebt = Debt(
    id: PreviewData.id(1450), personName: "Kitty Same", countsInNetWorth: true,
    createdAt: Date(timeIntervalSince1970: 1_780_000_050))
  static let kittyAccounts: [Account] = [(1451, Currency.PLN), (1452, .EUR), (1453, .UAH)].map { n, currency in
    Account(
      id: PreviewData.id(n), name: "Kitty Same", currency: currency, kind: .debt, openingBalanceMinor: 0,
      openingDate: Date(timeIntervalSince1970: 1_700_000_000), position: 80 + n - 1451)
  }

  /// The sample database plus a debt with three same-named accounts and a transfer on each.
  func kittyModel(filters: TransactionFilters = .default) async throws -> TransactionsViewModel {
    let database = try DebtSample.database(calendar: Self.calendar)
    let accounts = Self.kittyAccounts
    let debt = Self.kittyDebt
    let calendar = Self.calendar
    try await database.write { db in
      try db.seed {
        for account in accounts { account }
        debt
        for account in accounts {
          DebtAccountLink(
            accountID: account.id, debtID: debt.id, role: .virtual,
            createdAt: Date(timeIntervalSince1970: 1_780_000_060))
        }
        for (i, account) in accounts.enumerated() {
          Txn(
            id: PreviewData.id(1700 + i), type: .transfer, occurredAt: Day("2026-10-1\(i)")!.date(calendar: calendar),
            accountID: PreviewData.pkoPersonal.id, amountMinor: 10_00, toAccountID: account.id,
            payee: "To Kitty \(i)", createdAt: Day("2026-10-1\(i)")!.date(calendar: calendar))
        }
      }
    }
    let model = TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      displayCurrency: .PLN, filters: filters, calendar: Self.calendar, today: { PreviewData.today },
      debts: SQLiteDebtRepository(database: database, calendar: Self.calendar))
    await model.load()
    await model.loadDebtOptions()
    return model
  }

  @Test("R-DEBT-22: every way of removing the debt filter completes and restores the list", .timeLimit(.minutes(1)))
  func everyRemovalPathCompletes() async throws {
    let id = Self.kittyDebt.id
    let removals: [(String, @MainActor (TransactionsViewModel) -> Void)] = [
      ("chip x", { $0.toggleDebt(id) }),
      ("debts popup", { $0.toggleDebt(id) }),
      ("clear filters", { $0.clearFilters() }),
      ("filters replaced by the default", { $0.filters = .default }),
      ("each account entry, then the debt", { model in
        for account in Self.kittyAccounts { model.filters.toggleAccount(account.id) }
        model.toggleDebt(id)
      }),
    ]
    for (name, remove) in removals {
      let model = try await kittyModel(filters: .default)
      model.filters = try #require(await model.filters(showingDebt: id))
      await model.reload()
      #expect(model.rows.count == 3, "\(name): debt applied")
      remove(model)
      await model.reload()
      #expect(!model.filters.isDebtFiltered, "\(name)")
      #expect(model.filters.accountIDs.isEmpty, "\(name)")
      #expect(model.filters.debtLinkedIDs.isEmpty, "\(name)")
      #expect(model.debtLabel == "All debts", "\(name)")
      
      #expect(model.loadedQuery == model.query, "\(name)")
      #expect(model.errorMessage == nil, "\(name)")
    }
  }

  @Test("C24: the list view is keyed by the query of the rows on screen, not by the pending one")
  func loadedQueryFollowsTheRows() async throws {
    let model = try await kittyModel()
    #expect(model.loadedQuery == model.query)
    let before = model.loadedQuery
    model.toggleDebt(Self.kittyDebt.id)
    // The filter changed but the rows are the old ones until the reload lands: same identity.
    #expect(model.loadedQuery == before)
    #expect(model.query != before)
    await model.reload()
    #expect(model.loadedQuery == model.query)
    #expect(model.loadedQuery != before)
    // A debt without any ticked account matches nothing: the identity still moves on.
    for account in Self.kittyAccounts { model.filters.toggleAccount(account.id) }
    await model.reload()
    #expect(model.rows.isEmpty)
    #expect(model.loadedQuery == nil)
  }

  @Test("R-DEBT-22 / C28: a debt with three same-named accounts reads one label; un-ticking an account keeps the debt")
  func debtLabelAndAccountCount() async throws {
    let model = try await kittyModel()
    model.toggleDebt(Self.kittyDebt.id)
    #expect(model.filters.accountIDs == Set(Self.kittyAccounts.map(\.id)))
    #expect(model.debtLabel == "Debt: Kitty Same")
    #expect(model.accountLabel == "3 accounts")

    // Un-ticking one account in the Accounts menu keeps the debt.
    let eur = try #require(Self.kittyAccounts.first { $0.currency == .EUR })
    model.filters.toggleAccount(eur.id)
    #expect(model.filters.isDebtFiltered)
    #expect(model.accountLabel == "2 accounts")
    await model.reload()
    #expect(model.rows.count == 2)

    // Ticked again: back to 3 accounts (the bar has only buttons, no chips).
    model.filters.toggleAccount(eur.id)
    #expect(model.accountLabel == "3 accounts")
    #expect(model.debtLabel == "Debt: Kitty Same")
  }

  @Test("C24: while a debt is selected the Accounts menu lists only its accounts; removing it restores the list")
  func accountsMenuFollowsTheDebt() async throws {
    let model = try await kittyModel()
    let all = model.accountOptions.map(\.id)
    #expect(all.count > Self.kittyAccounts.count + 4)

    model.toggleDebt(Self.kittyDebt.id)
    #expect(Set(model.accountOptions.map(\.id)) == Set(Self.kittyAccounts.map(\.id)))
    // A second debt: the union.
    model.toggleDebt(DebtSample.maria.id)
    #expect(Set(model.accountOptions.map(\.id)) == Set(Self.kittyAccounts.map(\.id)).union(mariaAccounts))
    // Removing one narrows it again.
    model.toggleDebt(Self.kittyDebt.id)
    #expect(Set(model.accountOptions.map(\.id)) == mariaAccounts)
    model.toggleDebt(DebtSample.maria.id)
    #expect(model.accountOptions.map(\.id) == all)
  }

  @Test("C24: a debt together with an unrelated account cannot be built (always 0 rows)")
  func unrelatedAccountIsNotAllowed() async throws {
    let model = try await kittyModel()
    // Picked before: dropped when the debt is applied.
    model.filters.toggleAccount(PreviewData.pkoPersonal.id)
    model.toggleDebt(Self.kittyDebt.id)
    #expect(model.filters.accountIDs == Set(Self.kittyAccounts.map(\.id)))
    // Picked afterwards (not offered by the menu): ignored.
    model.filters.toggleAccount(PreviewData.pkoPersonal.id)
    #expect(model.filters.accountIDs == Set(Self.kittyAccounts.map(\.id)))
    await model.reload()
    #expect(model.rows.count == 3)

    // An independent selection that belongs to a removed debt leaves with it when another debt stays.
    model.toggleDebt(DebtSample.maria.id)
    let eur = try #require(Self.kittyAccounts.first { $0.currency == .EUR })
    model.filters.toggleAccount(eur.id)  // un-tick
    model.filters.toggleAccount(eur.id)  // tick again: independent now
    model.toggleDebt(Self.kittyDebt.id)
    #expect(model.filters.accountIDs == mariaAccounts)
  }
}
