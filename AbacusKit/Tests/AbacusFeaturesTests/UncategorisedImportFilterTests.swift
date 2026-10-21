import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// The "Uncategorised" and import-batch filters (WP C1) on the preview world plus a few
/// transactions without a category and from two imports.
enum C1Sample {
  static let batch = ImportBatch(
    id: PreviewData.id(950), source: .pko, fileName: "statement.csv",
    importedAt: Date(timeIntervalSince1970: 1_792_584_000))  // 2026-10-21 12:00 UTC
  static let otherBatch = ImportBatch(id: PreviewData.id(951), source: .saldo, fileName: "saldo.csv")

  static func at(_ day: String) -> Date { Day(day)!.date().addingTimeInterval(12 * 3600) }

  /// An uncategorised expense and income, an uncategorised expense from `batch`, a categorised
  /// expense from `batch` and a transfer from `otherBatch` (transfers have no category).
  static let txns: [Txn] = [
    Txn(
      id: PreviewData.id(960), type: .expense, occurredAt: at("2026-10-16"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 12_00, payee: "Kiosk", createdAt: at("2026-10-16")),
    Txn(
      id: PreviewData.id(961), type: .income, occurredAt: at("2026-10-14"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 50_00, payee: "Friend", createdAt: at("2026-10-14")),
    Txn(
      id: PreviewData.id(962), type: .expense, occurredAt: at("2026-10-13"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 8_00, payee: "Card payment", source: .pko, importBatchID: batch.id, createdAt: at("2026-10-13")),
    Txn(
      id: PreviewData.id(963), type: .expense, occurredAt: at("2025-12-30"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 30_00, categoryID: PreviewData.id(202), payee: "Old groceries", source: .pko,
      importBatchID: batch.id, createdAt: at("2025-12-30")),
    Txn(
      id: PreviewData.id(964), type: .transfer, occurredAt: at("2026-10-11"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 100_00, toAccountID: PreviewData.cashPLN.id, toAmountMinor: 100_00, payee: "Saldo transfer",
      source: .saldo, importBatchID: otherBatch.id, createdAt: at("2026-10-11")),
  ]

  static func store() -> TransactionsPreviewStore {
    TransactionsPreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, events: PreviewData.events,
      txns: PreviewData.txns + txns, attachedRecords: PreviewData.attachedRecords)
  }

  @MainActor
  static func model(filters: TransactionFilters = .default) -> TransactionsViewModel {
    let store = store()
    return TransactionsViewModel(
      transactions: store.transactions, accounts: store.accounts, categories: store.categories,
      events: store.events, converter: RateTable.transactionsPreview, displayCurrency: .PLN, filters: filters,
      today: { PreviewData.today })
  }
}

@Suite("Transactions · Uncategorised and import filters")
struct UncategorisedImportQueryTests {
  func payees(_ query: TxnQuery) async throws -> [String] {
    try await C1Sample.store().transactions.transactions(matching: query).map(\.txn.payee)
  }

  @Test("R-HOME-3, R-LIST-2: in memory, Uncategorised matches expenses and incomes without a category, not transfers")
  func uncategorised() async throws {
    #expect(try await payees(TxnQuery(includeUncategorised: true)) == ["Kiosk", "Friend", "Card payment"])
    // "Uncategorised OR one of these": the fees category matches through an attached record.
    let withFees = try await payees(TxnQuery(categoryIDs: [PreviewData.id(213)], includeUncategorised: true))
    #expect(withFees == ["Kiosk", "To EUR card", "Friend", "Card payment"])
    #expect(try await payees(TxnQuery(types: [.income], includeUncategorised: true)) == ["Friend"])
  }

  @Test("R-IMP-6: in memory, the import filter keeps only that import's transactions, any date")
  func importBatch() async throws {
    #expect(try await payees(TxnQuery(importBatchIDs: [C1Sample.batch.id])) == ["Card payment", "Old groceries"])
    let both = try await payees(TxnQuery(importBatchIDs: [C1Sample.batch.id, C1Sample.otherBatch.id]))
    #expect(both == ["Card payment", "Saldo transfer", "Old groceries"])
    let uncategorisedOfBatch = TxnQuery(includeUncategorised: true, importBatchIDs: [C1Sample.batch.id])
    #expect(try await payees(uncategorisedOfBatch) == ["Card payment"])
  }

  @Test("R-LIST-5: with Uncategorised only the main amount without a category counts")
  func totalsRule() {
    let rule = TransactionTotalsRule(categoryFilter: nil, includeUncategorised: true)
    let kiosk = TxnWithLines(txn: C1Sample.txns[0], lines: [])
    #expect(rule.parts(of: kiosk) == (income: 0, expense: 12_00))
    let categorised = TxnWithLines(
      txn: C1Sample.txns[3],
      lines: [AttachedRecord(txnID: C1Sample.txns[3].id, categoryID: nil, amountMinor: 1_00)])
    #expect(rule.parts(of: categorised) == (income: 0, expense: 0))
    let withLine = TxnWithLines(
      txn: C1Sample.txns[0],
      lines: [AttachedRecord(txnID: C1Sample.txns[0].id, categoryID: PreviewData.id(213), amountMinor: 2_00)])
    let both = TransactionTotalsRule(categoryFilter: [PreviewData.id(213)], includeUncategorised: true)
    #expect(both.parts(of: withLine) == (income: 0, expense: 14_00))
    #expect(TransactionTotalsRule(categoryFilter: [PreviewData.id(213)]).parts(of: withLine) == (income: 0, expense: 2_00))
  }
}

@Suite("Transactions · filter state for Uncategorised and imports")
struct UncategorisedImportFiltersTests {
  let today = PreviewData.today

  @Test("R-HOME-3: the Uncategorized slice drills down to expenses without a category in the month")
  func drillDown() throws {
    let october = Month(year: 2026, month: 10)
    let filters = TransactionFilters.drillDown(category: nil, month: october)
    #expect(filters.isCategoryFiltered)
    #expect(filters.hasActiveFilters)
    let query = try #require(filters.query(today: today))
    #expect(query.includeUncategorised)
    #expect(query.categoryIDs.isEmpty)
    #expect(query.types == [.expense])
    #expect(query.fromDay == Day("2026-10-01"))
    #expect(query.toDay == Day("2026-10-31"))
    #expect(query == DashboardDrillDown.query(categoryID: nil, month: october))
    // A category drill-down is unchanged.
    let food = try #require(TransactionFilters.drillDown(category: PreviewData.id(201), month: october).query(today: today))
    #expect(!food.includeUncategorised)
    #expect(food.categoryIDs == [PreviewData.id(201)])
  }

  @Test("R-IMP-6: Show transactions filters to the batch over every date; clearing restores the default")
  func importFilter() throws {
    var filters = TransactionFilters.importBatch(C1Sample.batch)
    #expect(filters.hasActiveFilters)
    let query = try #require(filters.query(today: today))
    #expect(query.importBatchIDs == [C1Sample.batch.id])
    #expect(query.fromDay == Day("1900-01-01"))
    #expect(query.toDay == Day("9999-12-31"))
    filters.clear()
    #expect(filters == .default)
    #expect(try #require(filters.query(today: today)).importBatchIDs.isEmpty)
  }
}

@MainActor
@Suite("Transactions · view model with Uncategorised and imports")
struct UncategorisedImportViewModelTests {
  @Test("R-LIST-2: Uncategorised is offered only when such transactions exist; ticking it filters the list")
  func uncategorisedOption() async {
    let plain = TransactionsViewModel.preview()
    await plain.load()
    #expect(!plain.hasUncategorised)
    #expect(!plain.showsUncategorisedOption)

    let model = C1Sample.model()
    await model.load()
    #expect(model.hasUncategorised)
    #expect(model.showsUncategorisedOption)
    model.toggleUncategorised()
    await model.reload()
    #expect(model.categoryLabel == "Uncategorised")
    #expect(model.content.days.flatMap(\.rows).map(\.title) == ["Kiosk", "Friend", "Card payment"])
    #expect(model.content.totals.expense == Money(minorUnits: 20_00, currency: .PLN))
    #expect(model.content.totals.income == Money(minorUnits: 50_00, currency: .PLN))
    model.toggleCategory(PreviewData.id(201))
    #expect(model.categoryLabel == "2 categories")
    model.clearFilters()
    #expect(!model.filters.includeUncategorised)
  }

  @Test("R-IMP-6: the import chip names the file and day; removing it keeps the other filters")
  func importChip() async {
    var filters = TransactionFilters.importBatch(C1Sample.batch)
    filters.toggleType(.transfer)
    let model = C1Sample.model(filters: filters)
    await model.load()
    #expect(model.importLabel == "Import: statement.csv · Oct 21, 2026")
    #expect(model.dateLabel == "All dates")
    #expect(model.content.days.flatMap(\.rows).map(\.title) == ["Card payment", "Old groceries"])
    model.clearImportFilter()
    await model.reload()
    #expect(model.importLabel == nil)
    #expect(model.filters.dateRange == TransactionFilters.allDates)
    #expect(!model.filters.types.contains(.transfer))
    #expect(model.content.days.flatMap(\.rows).count > 2)
  }
}

@MainActor
@Suite("Dashboard and shell · Uncategorised and import drill-downs")
struct UncategorisedImportShellTests {
  @Test("R-HOME-3: picking the Uncategorized slice drills down to the month's expenses without a category")
  func uncategorisedSlice() async throws {
    let store = DashboardPreviewStore.previewData()
    try await store.txnRepository.save(C1Sample.txns[0], lines: [])
    try await store.txnRepository.save(C1Sample.txns[1], lines: [])
    let model = DashboardModel(dependencies: .preview(store: store), displayCurrency: .PLN)
    await model.load()
    let slice = try #require(model.expenses?.slices.first { $0.id == .uncategorized })
    #expect(slice.drillsDown)
    let target = try #require(model.select(slice))
    #expect(target.categoryID == nil)
    #expect(target.month == Month(year: 2026, month: 10))
    #expect(model.selectedSlice == .uncategorized)
    let query = DashboardDrillDown.query(categoryID: target.categoryID, month: target.month)
    let rows = try await store.txnRepository.transactions(matching: query)
    #expect(rows.map(\.txn.payee) == ["Kiosk"])
  }

  @Test("R-IMP-6: an import's Show transactions opens the list filtered to that batch")
  func showImport() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let session = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    let wizard = try #require(session.importWizard)
    await wizard.load()
    await wizard.open(data: try ImportHarness.fixture("saldo", "spec-example"), fileName: "spec-example.csv")
    await wizard.commit()
    let batch = try #require(wizard.summary?.batch)

    session.showTransactions(ofImport: PreviewData.id(999))
    #expect(session.app.pendingTransactionFilters == nil)
    session.showTransactions(ofImport: batch.id)
    #expect(session.app.section == .transactions)
    let filters = try #require(session.app.pendingTransactionFilters)
    #expect(filters.importBatch?.id == batch.id)

    session.transactions.filters = filters
    await session.transactions.load()
    #expect(session.transactions.rows.count == 3)
    #expect(session.transactions.rows.allSatisfy { $0.txn.importBatchID == batch.id })
    #expect(session.transactions.importLabel?.hasPrefix("Import: spec-example.csv · ") == true)
  }
}
