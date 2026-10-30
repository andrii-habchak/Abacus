import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

/// Categories page actions and the import chip (C33).
@MainActor
@Suite("Categories · show transactions and re-assign")
struct CategoryActionsTests {
  let store = ManagePreviewStore.sample()
  let food = PreviewData.id(201), groceries = PreviewData.id(202), eatingOut = PreviewData.id(203)
  let transport = PreviewData.id(206), taxi = PreviewData.id(207), salary = PreviewData.id(251)

  func model() async -> CategoriesModel {
    let model = CategoriesModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  // MARK: Filters

  @Test("A category jump shows every date and remembers the range to restore")
  func categoryFilter() {
    let last3 = TransactionFilters.DateRange.preset(.last3Months)
    let filters = TransactionFilters.category(food, dateRangeBefore: last3)
    #expect(filters.categoryIDs == [food])
    #expect(filters.dateRange == TransactionFilters.allDates)
    #expect(filters.dateRangeBeforeCategory == last3)
    #expect(filters.hasActiveFilters)
  }

  @Test("Clearing the category filter brings the previous range back; a hand-made range stays")
  func restoreRange() {
    let before = TransactionFilters.DateRange.preset(.thisYear)
    var filters = TransactionFilters.category(food, dateRangeBefore: before)
    filters.categoryIDs = []
    #expect(filters.dateRange == before)
    #expect(filters.dateRangeBeforeCategory == nil)

    var byHand = TransactionFilters.category(food, dateRangeBefore: before)
    byHand.dateRange = .preset(.lastMonth)
    byHand.categoryIDs = []
    #expect(byHand.dateRange == .preset(.lastMonth))

    // A second category keeps the all-dates range until the last one goes.
    var two = TransactionFilters.category(food, dateRangeBefore: before)
    two.categoryIDs.insert(transport)
    two.categoryIDs.remove(food)
    #expect(two.dateRange == TransactionFilters.allDates)
    two.categoryIDs = []
    #expect(two.dateRange == before)
  }

  @Test("The built-in Uncategorised jump filters uncategorised rows of that kind and restores likewise")
  func uncategorisedFilter() {
    let before = TransactionFilters.DateRange.preset(.thisMonth)
    var filters = TransactionFilters.category(nil, kind: .income, dateRangeBefore: before)
    #expect(filters.includeUncategorised && filters.categoryIDs.isEmpty)
    #expect(filters.types == DashboardDrillDown.types(kind: .income, uncategorised: true))
    filters.includeUncategorised = false
    #expect(filters.dateRange == before)
  }

  @Test("A jump from a list already showing all dates keeps nothing to restore")
  func nothingToRestore() {
    let filters = TransactionFilters.category(food, dateRangeBefore: TransactionFilters.allDates)
    #expect(filters.dateRangeBeforeCategory == nil)
  }

  @Test("The debt filter's own restore is unchanged")
  func debtUnchanged() {
    var filters = TransactionFilters.debt(UUID(), accountIDs: [UUID()])
    let debt = filters.debtIDs.first!
    filters.dateRangeBeforeDebt = .preset(.thisYear)
    filters.removeDebt(debt)
    #expect(filters.dateRange == .preset(.thisYear))
  }

  // MARK: Session

  @Test("The session opens Transactions filtered by the category, restoring the previous range")
  func sessionJump() async {
    let session = AppSession.preview()
    await session.categories.load()
    session.transactions.filters.dateRange = .preset(.last3Months)
    session.showTransactions(ofCategory: food)
    #expect(session.app.section == .transactions)
    let filters = session.app.pendingTransactionFilters
    #expect(filters?.categoryIDs == [food])
    #expect(filters?.dateRange == TransactionFilters.allDates)
    #expect(filters?.dateRangeBeforeCategory == .preset(.last3Months))

    session.app.pendingTransactionFilters = nil
    session.showTransactions(ofCategory: UUID())
    #expect(session.app.pendingTransactionFilters == nil)

    session.showTransactions(ofCategory: CategoriesModel.uncategorisedID)
    #expect(session.app.pendingTransactionFilters?.includeUncategorised == true)
  }

  @Test("The context-menu action reaches the session callback")
  func menuAction() async {
    let model = await model()
    var shown: [UUID] = []
    model.onShowTransactions = { shown.append($0) }
    model.showTransactions(of: groceries)
    model.showTransactions(of: UUID())
    model.showTransactions(of: CategoriesModel.uncategorisedID)
    #expect(shown == [groceries, CategoriesModel.uncategorisedID])
  }

  // MARK: Re-assign sheet

  @Test("The sheet lists active same-kind targets except the category and its own subcategories")
  func sheetTargets() async throws {
    let model = await model()
    await model.requestReassign(food)
    let sheet = try #require(model.reassignSheet)
    let ids = Set(sheet.targets.map(\.id))
    #expect(!ids.contains(food) && !ids.contains(groceries) && !ids.contains(eatingOut))
    #expect(ids.contains(transport) && !ids.contains(salary))
    #expect(sheet.repointRules && !sheet.archiveAfterwards)
    #expect(sheet.targetID != nil)
    #expect(sheet.summary.contains("will move to"))
    #expect(sheet.notes.contains { $0.contains("subcategories") })
  }

  @Test("Confirming moves the transactions and refreshes the usage counts")
  func confirm() async throws {
    let model = await model()
    let all = try await store.txnRepository.transactions(matching: TxnQuery())
    let moving = all.filter { $0.txn.categoryID == taxi }.count
    let before = all.filter { $0.txn.categoryID == transport }.count
    #expect(moving > 0)
    await model.requestReassign(taxi)
    var sheet = try #require(model.reassignSheet)
    #expect(sheet.impact.transactions == moving)
    sheet.targetID = transport
    sheet.archiveAfterwards = true
    #expect(sheet.summary.hasPrefix(ManageText.transactions(moving) + " will move to Transport"))
    await model.confirmReassign(sheet)
    #expect(model.reassignSheet == nil)
    let after = try await store.txnRepository.transactions(matching: TxnQuery())
    #expect(after.filter { $0.txn.categoryID == transport }.count == before + moving)
    #expect(after.filter { $0.txn.categoryID == taxi }.isEmpty)
    #expect(model.category(taxi)?.isArchived == true)
  }

  @Test("A category nothing uses cannot be re-assigned; the sheet says so")
  func nothingToMove() async throws {
    let model = await model()
    await model.requestReassign(PreviewData.id(214))  // Travel: unused
    let sheet = try #require(model.reassignSheet)
    #expect(!model.canConfirmReassign(sheet))
    #expect(sheet.summary.contains("nothing to move"))
  }

  @Test("The picker starts with the built-in Uncategorised, then same-kind active targets without self or children")
  func pickerItems() async throws {
    let model = await model()
    await model.requestReassign(food)
    let sheet = try #require(model.reassignSheet)
    let first = try #require(sheet.pickerItems.first)
    #expect(first.value == CategoriesModel.uncategorisedID)
    #expect(first.title == "Uncategorised (no category)")
    let ids = Set(sheet.pickerItems.map(\.value))
    #expect(!ids.contains(food) && !ids.contains(groceries) && !ids.contains(eatingOut))
    #expect(ids.contains(transport) && !ids.contains(salary))
    #expect(sheet.pickerItems.dropFirst().map(\.value) == sheet.targets.map(\.id))
    // A parent that matches the search brings its children.
    let hits = CategorySearch.hits(sheet.pickerItems, query: "transport", isSelected: { _ in false })
    #expect(hits.contains { $0.item.value == taxi })
  }

  @Test("Moving to the built-in Uncategorised clears the category, keeps the rules and archives on request")
  func toUncategorised() async throws {
    let model = await model()
    let all = try await store.txnRepository.transactions(matching: TxnQuery())
    let moving = all.filter { $0.txn.categoryID == taxi }.count
    await model.requestReassign(taxi)
    var sheet = try #require(model.reassignSheet)
    sheet.targetID = CategoriesModel.uncategorisedID
    sheet.archiveAfterwards = true
    #expect(sheet.targetIsUncategorised && !sheet.canRepointRules)
    #expect(sheet.summary.hasPrefix(ManageText.transactions(moving) + " will move to Uncategorised"))
    #expect(model.canConfirmReassign(sheet))
    await model.confirmReassign(sheet)
    #expect(model.reassignSheet == nil)
    let after = try await store.txnRepository.transactions(matching: TxnQuery())
    #expect(after.filter { $0.txn.categoryID == taxi }.isEmpty)
    #expect(after.filter { $0.txn.categoryID == nil && $0.txn.type != .transfer }.count >= moving)
    #expect(model.category(taxi)?.isArchived == true)
  }

  @Test("The built-in Uncategorised offers no re-assign")
  func builtIn() async {
    let model = await model()
    #expect(!model.canReassign(CategoriesModel.uncategorisedID))
    #expect(model.canReassign(food))
  }

  // MARK: Import chip

  @Test("Clearing the import filter keeps the other filters")
  func importClear() {
    let batch = ImportBatch(source: .pko, fileName: "pko.csv")
    var filters = TransactionFilters.importBatch(batch)
    filters.search = "x"
    filters.importBatch = nil
    #expect(filters.search == "x" && filters.importBatch == nil)
  }
}
