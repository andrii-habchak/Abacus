import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C28: paging, whole-set totals, date range restore, cascading filter menus, one-row filter bar.
@MainActor
@Suite("Transactions · paging and cascading filters (C28)")
struct TransactionsPagingFilterTests {
  nonisolated static let today = Day(year: 2026, month: 10, day: 21)
  static let calendar = Calendar.current

  func model(
    database: (any DatabaseWriter)? = nil, pageSize: Int = 40, filters: TransactionFilters = .init(dateRange: TransactionFilters.allDates)
  ) throws -> TransactionsViewModel {
    let database = try database ?? LargeSampleData.database(size: .init(transactions: 400), today: Self.today, calendar: Self.calendar)
    return TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      displayCurrency: .PLN, filters: filters, calendar: Self.calendar, today: { Self.today },
      debts: SQLiteDebtRepository(database: database, calendar: Self.calendar), pageSize: pageSize)
  }

  @Test("R-LIST-4: pages append without gaps or duplicates; a day split by a page boundary stays one section")
  func pagesAndBoundaries() async throws {
    let db = try LargeSampleData.database(size: .init(transactions: 400), today: Self.today, calendar: Self.calendar)
    let paged = try model(database: db, pageSize: 37)
    await paged.load()
    let total = paged.summary.count
    #expect(total > 100)
    #expect(paged.rows.count == 37)
    #expect(paged.hasMoreRows)
    while paged.hasMoreRows { await paged.loadMore() }
    #expect(paged.rows.count == total)

    let all = try model(database: db, pageSize: 100_000)
    await all.load()
    #expect(paged.rows.map(\.txn.id) == all.rows.map(\.txn.id))
    // One section per day even when a page boundary fell inside a day.
    let days = paged.content.days.map(\.day)
    #expect(days.count == Set(days).count)
    #expect(paged.content.days == all.content.days)
    #expect(paged.content.items == all.content.items)
  }

  @Test("R-LIST-5: totals, count and day sums cover the whole filtered set while only page one is loaded")
  func totalsOverTheWholeSet() async throws {
    let db = try LargeSampleData.database(size: .init(transactions: 400), today: Self.today, calendar: Self.calendar)
    let paged = try model(database: db, pageSize: 25)
    await paged.load()
    let all = try model(database: db, pageSize: 100_000)
    await all.load()
    #expect(paged.rows.count == 25 && all.rows.count == paged.summary.count)
    #expect(paged.content.totals == all.content.totals)
    #expect(paged.content.totals.count == all.rows.count)
    #expect(paged.content.netText == all.content.netText)
    // The first (possibly partly loaded) day shows its full-day net.
    let first = try #require(paged.content.days.first)
    let reference = try #require(all.content.days.first { $0.day == first.day })
    #expect(first.net == reference.net && first.netText == reference.netText)
    #expect(first.rows.count <= reference.rows.count)

    // The aggregate agrees with the legacy row-by-row computation.
    let legacy = TransactionListContent(
      rows: all.rows, reference: all.reference, displayCurrency: .PLN, converter: RateTable.transactionsPreview,
      today: Self.today, calendar: Self.calendar)
    #expect(legacy.totals == all.content.totals)
    #expect(legacy.days.map(\.netText) == all.content.days.map(\.netText))
  }

  @Test("R-LIST-5: the aggregate honours a category filter")
  func totalsWithCategoryFilter() async throws {
    let all = try model(pageSize: 100_000)
    await all.load()
    let category = try #require(all.reference.categories.options.first { !$0.hasChildren && $0.kind == .expense }).id
    all.filters.categoryIDs = [category]
    await all.reload()
    let legacy = TransactionListContent(
      rows: all.rows, reference: all.reference, displayCurrency: .PLN, converter: RateTable.transactionsPreview,
      today: Self.today, categoryFilter: [category], calendar: Self.calendar)
    #expect(all.content.totals == legacy.totals)
  }

  // MARK: Date range

  @Test("R-LIST-1 / R-DEBT-22: removing the debt filter restores the date range; Clear filters goes to the default")
  func dateRangeRestoreAndClear() async throws {
    let database = try DebtSample.database(calendar: Self.calendar)
    let model = try model(database: database, filters: TransactionFilters(dateRange: .preset(.thisMonth)))
    await model.load()
    model.filters = try #require(await model.filters(showingDebt: DebtSample.alex.id))
    #expect(model.filters.dateRange == TransactionFilters.allDates)
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.dateRange == .preset(.thisMonth))
    #expect(model.filters.dateRangeBeforeDebt == nil)

    // A range chosen by hand while the debt is shown stays.
    model.filters = try #require(await model.filters(showingDebt: DebtSample.alex.id))
    model.filters.dateRange = .preset(.lastMonth)
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.filters.dateRange == .preset(.lastMonth))

    // Choosing All dates by hand works; Clear filters returns to the last 30 days.
    model.filters.dateRange = TransactionFilters.allDates
    #expect(model.dateLabel == "All dates")
    model.filters = try #require(await model.filters(showingDebt: DebtSample.alex.id))
    model.clearFilters()
    #expect(model.filters.dateRange == .preset(.last30Days))
    #expect(model.filters == .default)
  }

  // MARK: Facets

  @Test("R-LIST-2 / R-DEBT-22: with a debt selected the Categories menu offers only Uncategorised")
  func debtLimitsCategories() async throws {
    let database = try DebtSample.database(calendar: Self.calendar)
    let model = try model(database: database)
    await model.load()
    await model.loadDebtOptions()
    await model.reload()
    #expect(!model.categoryMenu.isEmpty)  // without a debt there are categories to pick

    model.toggleDebt(DebtSample.alex.id)
    await model.reload()
    #expect(!model.rows.isEmpty)
    #expect(model.categoryMenu.isEmpty)
    #expect(model.showsUncategorisedOption)
    // Ticking it yields rows (the debt's transfers), never zero.
    model.toggleUncategorised()
    await model.reload()
    #expect(!model.rows.isEmpty)
    #expect(!model.isUncategorisedImpossible)
  }

  @Test("R-LIST-2: menus list only values with rows under the other filters; selected ones stay, marked")
  func cascadeAndSelectedStay() async throws {
    let database = try DebtSample.database(calendar: Self.calendar)
    let model = try model(database: database)
    await model.load()
    await model.loadDebtOptions()
    // Maria's accounts only: Alex's accounts and Alex have no rows.
    model.toggleDebt(DebtSample.maria.id)
    await model.reload()
    #expect(Set(model.accountOptions.map(\.id)) == Set(model.filters.debtLinkedAccountIDs))
    let events = model.eventOptions
    for event in events { #expect((model.eventCount(event.id) ?? 0) > 0) }

    // Types: only those with rows are offered while nothing is filtered.
    for entry in model.typeMenu { #expect((entry.count ?? 0) > 0) }

    // A ticked account whose rows vanish under another filter stays visible and is marked.
    model.clearFilters()
    model.filters.dateRange = TransactionFilters.allDates
    let account = try #require(model.reference.accounts.first { $0.id == DebtSample.mariaUAH.id })
    model.filters.toggleAccount(account.id)
    model.filters.search = "no transaction contains this text"
    await model.reload()
    #expect(model.rows.isEmpty)
    #expect(model.accountOptions.map(\.id) == [account.id])
    #expect(model.isAccountImpossible(account.id))
    #expect(model.filters.accountIDs == [account.id])  // never auto-cleared

    // The Debts menu follows the accounts facet: Alex has no rows under this search, so only
    // ticked debts remain.
    #expect(model.debtMenu(matching: "").isEmpty)
    model.toggleDebt(DebtSample.maria.id)
    await model.reload()
    #expect(model.debtMenu(matching: "").map(\.id) == [DebtSample.maria.id])
    #expect(model.isDebtImpossible(try #require(model.debtMenu(matching: "").first)))
  }

  @Test("R-LIST-2: a ticked category with no rows stays in the menu and is marked")
  func selectedCategoryStays() async throws {
    let model = try model()
    await model.load()
    let leaf = try #require(model.reference.categories.options.first { !$0.hasChildren && !$0.isChild }).id
    model.toggleCategory(leaf)
    model.filters.search = "no transaction contains this text"
    await model.reload()
    let entry = try #require(model.categoryMenu.first { $0.id == leaf })
    #expect(entry.isImpossible)
    #expect(model.categoryMenu.count == 1)
    #expect(model.filters.categoryIDs == [leaf])
  }

  // MARK: Bar

  @Test("R-LIST-2: one summary label per button, no chips; shortened labels for a narrow bar")
  func labels() async throws {
    let database = try DebtSample.database(calendar: Self.calendar)
    let model = try model(database: database)
    await model.load()
    await model.loadDebtOptions()
    #expect(model.fullLabels.date == "All dates")
    #expect(model.fullLabels.categories == "All categories")
    #expect(model.fullLabels.event == "Any event")
    #expect(model.fullLabels.debts == "All debts")
    model.toggleDebt(DebtSample.alex.id)
    #expect(model.fullLabels.debts == "Debt: Alex Example")
    #expect(model.fullLabels.accounts == "2 accounts")
    model.toggleDebt(DebtSample.maria.id)
    #expect(model.fullLabels.debts == "2 debts")
    #expect(model.fullLabels.accounts == "4 accounts")
    #expect(model.compactLabels.categories == "Categories")
    model.toggleDebt(DebtSample.maria.id)
    #expect(model.compactLabels.debts.count <= 16)
    model.filters.types = [.expense]
    #expect(model.fullLabels.types == "Expenses")
    #expect(model.filters.isTypeFiltered)
  }
}
