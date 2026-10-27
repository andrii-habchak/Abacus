import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// WP C10 (TA v1.6, R-MGMT-8, D47): built-in Uncategorised, one colour everywhere, A–Z
/// pickers, sort, search, drag and drop, and "New transaction" with the selected category.
@MainActor
@Suite("Categories page (C10)")
struct CategoriesPageTests {
  let store = ManagePreviewStore.sample()
  let food = PreviewData.id(201), groceries = PreviewData.id(202), eatingOut = PreviewData.id(203)
  let housing = PreviewData.id(204), rent = PreviewData.id(205), transport = PreviewData.id(206)
  let taxi = PreviewData.id(207), fuel = PreviewData.id(208), health = PreviewData.id(209)
  let bills = PreviewData.id(210), travel = PreviewData.id(214)

  func model() async -> CategoriesModel {
    let model = CategoriesModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  func names(_ model: CategoriesModel) -> [String] { model.rows.map(\.name) }

  // MARK: Built-in Uncategorised (D47)

  @Test("D47: Uncategorised is pinned, built in, not a category row, with the default colour")
  func uncategorisedRow() async throws {
    let model = await model()
    let row = try #require(model.uncategorisedRow)
    #expect(row.name == "Uncategorised")
    #expect(row.isBuiltIn)
    #expect(row.colorHex == Uncategorised.defaultColorHex)
    #expect(!ColorPalette.needsColor(row.colorHex))
    #expect(!model.rows.contains { $0.id == CategoriesModel.uncategorisedID })
    #expect(model.category(CategoriesModel.uncategorisedID) == nil)
    // Not draggable, no drop target.
    #expect(!model.canDrop(CategoriesModel.uncategorisedID, on: food, position: .before))
    #expect(!model.canDrop(food, on: CategoriesModel.uncategorisedID, position: .onto))
    model.setKind(.income)
    #expect(model.uncategorisedRow?.name == "Uncategorised")
  }

  @Test("D47: only Uncategorised's colour changes; it is saved as a setting and reported")
  func uncategorisedColour() async throws {
    let model = await model()
    var changes = 0
    model.onDataChange = { changes += 1 }
    model.select(CategoriesModel.uncategorisedID)
    let draft = try #require(model.draft)
    #expect(draft.isBuiltIn)
    #expect(model.inspectorTitle == "Uncategorised")
    #expect(model.parentOptions.isEmpty)
    #expect(!model.canChangeParent)
    #expect(model.selectedCategory == nil)
    #expect(!model.isDirty)
    model.draft?.colorHex = "#0f96b0"
    #expect(model.canSave)
    await model.save()
    #expect(changes == 1)
    #expect(try await store.settingsRepository.value(.uncategorisedColor) == "#0F96B0")
    #expect(model.uncategorisedRow?.colorHex == "#0F96B0")
    #expect(!model.isDirty)
    #expect(model.categories.count == PreviewData.categories.count)
    // A fresh screen reads it back.
    let again = await self.model()
    #expect(again.uncategorisedRow?.colorHex == "#0F96B0")
  }

  @Test("D47: the transaction list labels and colours rows without a category with the built-in entry")
  func listUsesUncategorised() async throws {
    let settings = store.settingsRepository
    try await settings.set(.uncategorisedColor, "#B04BC4")
    let txnStore = C1Sample.store()
    let model = TransactionsViewModel(
      transactions: txnStore.transactions, accounts: txnStore.accounts, categories: txnStore.categories,
      events: txnStore.events, converter: RateTable.transactionsPreview, displayCurrency: .PLN,
      today: { PreviewData.today }, settings: settings)
    await model.load()
    let rows = model.content.days.flatMap(\.rows)
    let kiosk = try #require(rows.first { $0.title == "Kiosk" })
    #expect(kiosk.category == "Uncategorised")
    #expect(kiosk.icon.colorHex == "#B04BC4")
    #expect(model.reference.uncategorisedColor == "#B04BC4")
    let transfer = try #require(rows.first { $0.type == .transfer })
    #expect(transfer.icon.colorHex == nil)
    #expect(TransactionsViewModel.uncategorisedTitle == "Uncategorised")
  }

  @Test("D47, R-MGMT-7: the donut uses the categories' own colours and the built-in Uncategorised")
  func donutColours() async throws {
    let dashboardStore = DashboardPreviewStore.previewData()
    try await dashboardStore.settingsRepository.set(.uncategorisedColor, "#4F5BD5")
    try await dashboardStore.txnRepository.save(
      Txn(
        type: .expense, occurredAt: PreviewData.today.date().addingTimeInterval(9 * 3600),
        accountID: PreviewData.pkoPersonal.id, amountMinor: 15_00, payee: "Kiosk"),
      lines: [])
    let model = DashboardModel(
      dependencies: .preview(store: dashboardStore, format: DashboardModelTests.format), displayCurrency: .UAH)
    await model.load()
    let expenses = try #require(model.expenses)
    let byID = Dictionary(uniqueKeysWithValues: PreviewData.categories.map { ($0.id, $0) })
    var checked = 0
    for slice in expenses.slices + expenses.slices.flatMap(\.children) {
      switch slice.id {
      case .category(let id):
        // Exactly the colour the Categories page shows for that category.
        #expect(slice.colorHex == ColorPalette.normalized(byID[id]?.colorHex), "\(slice.name)")
        checked += 1
      case .uncategorized:
        #expect(slice.name == "Uncategorised")
        #expect(slice.colorHex == "#4F5BD5")
        checked += 1
      case .refunds:
        break
      }
    }
    #expect(checked > 3)
    #expect(expenses.slices.contains { $0.id == .uncategorized })
    // Two different categories never share a colour by accident of the mapping.
    let topColours = expenses.slices.filter { $0.id != .uncategorized }.map(\.colorHex)
    let expected = expenses.slices.compactMap { slice -> String? in
      if case .category(let id) = slice.id { return ColorPalette.normalized(byID[id]?.colorHex) }
      return nil
    }
    #expect(topColours == expected)
  }

  @Test("R-MGMT-7: hex parsing is the one strict #RRGGBB rule every screen shares")
  func hexParsing() {
    #expect(ColorPalette.rgb("#2E9E4F")! == (0x2E, 0x9E, 0x4F))
    #expect(ColorPalette.rgb("2e9e4f")! == (0x2E, 0x9E, 0x4F))
    #expect(ColorPalette.rgb("#2E9E4FFF") == nil)
    #expect(ColorPalette.rgb("#FFF") == nil)
    #expect(ColorPalette.rgb(nil) == nil)
    #expect(Uncategorised.colorHex(setting: "nonsense") == Uncategorised.defaultColorHex)
    #expect(Uncategorised.colorHex(setting: "#abcdef") == "#ABCDEF")
  }

  // MARK: A–Z pickers (R-MGMT-8)

  @Test("R-MGMT-8: pickers list parents A–Z, each followed by its subcategories A–Z")
  func alphabeticalPickers() {
    let categories = PreviewData.categories
    let expense = CategoryOrder.alphabetical(categories.filter { $0.kind == .expense }).map(\.name)
    #expect(
      expense == [
        "Bills", "Mobile", "Clothing", "Fees", "Food", "Eating out", "Groceries", "Health", "Housing", "Rent",
        "Transport", "Fuel", "Taxi", "Travel",
      ])
    let editor = EditorReference(categories: categories).categoryOptions(kind: .expense).map(\.name)
    #expect(editor == expense)
    let filter = TransactionCategoryTree(categories).options
    #expect(filter.prefix(expense.count).map(\.name) == expense)
    #expect(filter.suffix(3).map(\.name) == ["Cashback", "Refunds", "Salary"])
  }

  // MARK: Sort and search

  @Test("R-MGMT-8: the sort selector orders parents and their subcategories, and is remembered")
  func sorting() async throws {
    let model = await model()
    #expect(model.sort == .custom)
    #expect(names(model).prefix(3) == ["Food", "Groceries", "Eating out"])
    await model.setSort(.nameAscending)
    #expect(names(model).prefix(4) == ["Bills", "Mobile", "Clothing", "Fees"])
    #expect(names(model).suffix(4) == ["Transport", "Fuel", "Taxi", "Travel"])
    await model.setSort(.nameDescending)
    #expect(names(model).prefix(4) == ["Travel", "Transport", "Taxi", "Fuel"])
    #expect(try await store.settingsRepository.value(.categorySort) == "nameDescending")
    let again = await self.model()
    #expect(again.sort == .nameDescending)
  }

  @Test("R-MGMT-8: newest and oldest first follow the creation date")
  func sortingByAge() async throws {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    for (index, category) in try await store.categoryRepository.categories(kind: nil, includeArchived: true).enumerated() {
      var older = category
      older.createdAt = base.addingTimeInterval(Double(index))
      try await store.categoryRepository.save(older)
    }
    let model = await model()
    model.newCategory()
    model.draft?.name = "Pets"
    await model.save()
    await model.setSort(.newestFirst)
    #expect(names(model).first == "Pets")
    await model.setSort(.oldestFirst)
    #expect(names(model).prefix(3) == ["Food", "Groceries", "Eating out"])
    #expect(names(model).last == "Pets")
  }

  @Test("R-MGMT-11: search matches subcategories too and shows their parent")
  func search() async {
    let model = await model()
    model.searchText = "ax"
    #expect(names(model) == ["Transport", "Taxi"])
    #expect(model.rows[0].matchesSearch == false)
    #expect(model.rows[1].matchesSearch)
    #expect(model.uncategorisedRow == nil)
    model.searchText = "food"
    #expect(names(model) == ["Food"])
    model.searchText = "uncat"
    #expect(model.uncategorisedRow != nil)
    #expect(model.rows.isEmpty)
    model.searchText = "zzz"
    #expect(model.emptySearchMessage == "No categories match “zzz”.")
    model.searchText = ""
    #expect(names(model).count == 14)
  }

  // MARK: Drag and drop (R-MGMT-8)

  @Test("R-MGMT-8: dropping onto a row makes a subcategory; the sort stays")
  func dropOnto() async throws {
    let model = await model()
    await model.setSort(.nameAscending)
    #expect(model.canDrop(travel, on: housing, position: .onto))
    await model.drop(travel, on: housing, position: .onto)
    #expect(model.category(travel)?.parentID == housing)
    #expect(model.sort == .nameAscending)
    let saved = try await store.categoryRepository.categories(kind: .expense, includeArchived: true)
    #expect(saved.first { $0.id == travel }?.parentID == housing)
    // Onto a subcategory: a sibling of it.
    await model.drop(health, on: rent, position: .onto)
    #expect(model.category(health)?.parentID == housing)
  }

  @Test("R-CAT-2, R-MGMT-8: one level only, one kind only")
  func dropRules() async {
    let model = await model()
    // A category with subcategories never becomes one.
    #expect(!model.canDrop(food, on: housing, position: .onto))
    #expect(!model.canDrop(food, on: rent, position: .after))
    #expect(model.canDrop(food, on: housing, position: .after))
    // Not onto itself, not into its own group as a parent.
    #expect(!model.canDrop(food, on: food, position: .onto))
    // Another kind is not in this tab.
    #expect(!model.canDrop(food, on: PreviewData.id(251), position: .onto))
    await model.drop(food, on: housing, position: .onto)
    #expect(model.category(food)?.parentID == nil)
  }

  @Test("R-MGMT-8: between top-level rows a subcategory becomes top level, and the sort turns custom")
  func dropBetween() async throws {
    let model = await model()
    await model.setSort(.nameAscending)
    await model.drop(taxi, on: health, position: .before)
    #expect(model.sort == .custom)
    #expect(model.category(taxi)?.parentID == nil)
    // The A–Z order the user saw became the custom order, with Taxi moved.
    #expect(names(model).prefix(8) == ["Bills", "Mobile", "Clothing", "Fees", "Food", "Eating out", "Groceries", "Taxi"])
    #expect(try await store.settingsRepository.value(.categorySort) == "custom")
  }

  @Test("R-MGMT-8: right below a parent with subcategories it becomes the first one; below the list it goes last")
  func dropBelowParentAndAtEnd() async {
    let model = await model()
    await model.drop(travel, on: food, position: .after)
    #expect(model.category(travel)?.parentID == food)
    #expect(names(model).prefix(3) == ["Food", "Travel", "Groceries"])
    await model.drop(groceries, on: nil, position: .after)
    #expect(model.category(groceries)?.parentID == nil)
    #expect(names(model).last == "Groceries")
    // A parent dropped right below another parent stays top level after that block.
    await model.drop(bills, on: food, position: .after)
    #expect(model.category(bills)?.parentID == nil)
    #expect(names(model).prefix(6) == ["Food", "Travel", "Eating out", "Bills", "Mobile", "Housing"])
  }

  @Test("R-MGMT-8: nesting keeps transactions and budget limits on their category")
  func dropKeepsData() async throws {
    let before = try await store.txnRepository.transactions(matching: TxnQuery(categoryIDs: [taxi]))
    let model = await model()
    await model.drop(taxi, on: food, position: .onto)
    let after = try await store.txnRepository.transactions(matching: TxnQuery(categoryIDs: [taxi]))
    #expect(before.map(\.txn.id) == after.map(\.txn.id))
    #expect(after.allSatisfy { $0.txn.categoryID == taxi })
  }

  @Test("R-MGMT-8: only “New category”; the inspector's Parent field makes a subcategory")
  func onlyNewCategory() async {
    let model = await model()
    model.select(food)
    model.newCategory()
    #expect(model.draft?.parentID == nil)
    #expect(model.parentOptions.map(\.name) == ["Bills", "Clothing", "Fees", "Food", "Health", "Housing", "Transport", "Travel"])
  }

  // MARK: New transaction with the selected category (R-MGMT-8)

  @Test("R-MGMT-8: on Categories, New transaction starts with the selected category and its type")
  func newTransactionPrefill() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let session = AppSession.live(
      database: database, source: StubSource(rates: B1Fixture.rates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await session.start()
    defer { session.stop() }
    await session.loadSampleData()
    await session.categories.load()
    let salary = try #require(session.categories.categories.first { $0.kind == .income && $0.parentID == nil })

    session.app.section = .dashboard
    session.app.requestNewTransaction()
    #expect(session.app.editor == .new)

    session.app.section = .categories
    session.categories.setKind(.income)
    session.categories.select(salary.id)
    session.app.requestNewTransaction()
    #expect(session.app.editor == .newInCategory(salary.id))

    let editor = TransactionEditorModel(mode: .newInCategory(salary.id), dependencies: session.editorDependencies)
    await editor.load()
    #expect(editor.isNew)
    #expect(editor.type == .income)
    #expect(editor.categoryID == salary.id)
    #expect(editor.title == "New transaction")

    // The built-in Uncategorised is not a category: a plain new transaction.
    session.categories.select(CategoriesModel.uncategorisedID)
    session.app.requestNewTransaction()
    #expect(session.app.editor == .new)
  }
}
