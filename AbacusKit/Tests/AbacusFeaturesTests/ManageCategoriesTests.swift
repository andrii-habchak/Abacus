import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@MainActor
@Suite("Manage · Categories")
struct ManageCategoriesTests {
  let store = ManagePreviewStore.sample()
  let food = PreviewData.id(201), groceries = PreviewData.id(202), eatingOut = PreviewData.id(203)
  let housing = PreviewData.id(204), transport = PreviewData.id(206), taxi = PreviewData.id(207)
  let fuel = PreviewData.id(208), health = PreviewData.id(209), travel = PreviewData.id(214)

  func model() async -> CategoriesModel {
    let model = CategoriesModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  func txns() async throws -> [TxnWithLines] {
    try await store.txnRepository.transactions(matching: TxnQuery())
  }

  @Test("R-MGMT-2, R-CAT-2: the expense tab shows parents followed by their indented children with usage")
  func expenseTree() async throws {
    let model = await model()
    let rows = model.rows
    #expect(Array(rows.prefix(5).map(\.name)) == ["Food", "Groceries", "Eating out", "Housing", "Rent"])
    #expect(rows[0].isChild == false)
    #expect(rows[1].isChild)
    let used = try await txns().filter { $0.txn.categoryID == groceries }.count
    #expect(rows[1].usage == "\(used) transactions")
    #expect(rows.first { $0.id == travel }?.usage == "")
    #expect(model.selection == food)
  }

  @Test("R-MGMT-2, R-CAT-1: the income tab lists income categories only")
  func incomeTab() async {
    let model = await model()
    model.setKind(.income)
    #expect(model.rows.map(\.name) == ["Salary", "Cashback", "Refunds"])
    #expect(model.selection == PreviewData.id(251))
  }

  @Test("R-CAT-1: the inspector shows usage, including the monthly budget")
  func usageText() async {
    let model = await model()
    model.select(groceries)
    #expect(model.usageText.hasPrefix("Used by "))
    #expect(model.usageText.hasSuffix("and the monthly budget."))
    model.select(travel)
    #expect(model.usageText == "Not used by any transaction. Parent totals include its subcategories.")
  }

  @Test("R-CAT-1, R-CAT-2: new categories and subcategories are created in the current tab")
  func create() async throws {
    let model = await model()
    model.newCategory()
    #expect(model.inspectorTitle == "New category")
    model.draft?.name = "Pets"
    model.draft?.colorHex = ManageText.swatches[3]
    await model.save()
    let pets = try #require(model.categories.first { $0.name == "Pets" })
    #expect(pets.kind == .expense)
    #expect(pets.parentID == nil)
    #expect(pets.colorHex == ManageText.swatches[3])
    #expect(model.rows.last?.name == "Pets")

    model.select(transport)
    model.newSubcategory()
    #expect(model.inspectorTitle == "New subcategory")
    // R-MGMT-7: a random palette colour apart from the parent's.
    let picked = try #require(model.draft?.colorHex)
    #expect(ColorPalette.colors.contains(picked))
    #expect(picked != model.category(transport)?.colorHex)
    model.draft?.name = "Parking"
    await model.save()
    let parking = try #require(model.categories.first { $0.name == "Parking" })
    #expect(parking.parentID == transport)
    #expect(model.rows.map(\.name).contains("Parking"))
  }

  @Test("R-CAT-2: parents are top-level categories of the same kind; a category with children stays top level")
  func parentOptions() async {
    let model = await model()
    model.select(groceries)
    #expect(model.canChangeParent)
    let options = model.parentOptions.map(\.name)
    #expect(options.contains("Food"))
    #expect(!options.contains("Eating out"))
    #expect(!options.contains("Salary"))
    model.select(food)
    #expect(!model.canChangeParent)
  }

  @Test("R-MGMT-2: dragging a parent moves it with its children")
  func reorderParent() async {
    let model = await model()
    let rows = model.rows
    let transportIndex = rows.firstIndex { $0.id == transport }!
    // Drop Transport at the very top.
    await model.move(fromOffsets: [transportIndex], toOffset: 0)
    #expect(Array(model.rows.prefix(5).map(\.name)) == ["Transport", "Taxi", "Fuel", "Food", "Groceries"])
  }

  @Test("R-MGMT-2: dragging a subcategory under another parent moves it there")
  func reorderChild() async throws {
    let model = await model()
    let rows = model.rows
    let taxiIndex = rows.firstIndex { $0.id == taxi }!
    let groceriesIndex = rows.firstIndex { $0.id == groceries }!
    // Drop Taxi right below Groceries.
    await model.move(fromOffsets: [taxiIndex], toOffset: groceriesIndex + 1)
    #expect(Array(model.rows.prefix(4).map(\.name)) == ["Food", "Groceries", "Taxi", "Eating out"])
    #expect(model.category(taxi)?.parentID == food)
    let saved = try await store.categoryRepository.categories(kind: .expense, includeArchived: true)
    #expect(saved.first { $0.id == taxi }?.parentID == food)
  }

  @Test("R-CAT-3: deleting a used category asks for a same-kind target and moves transactions and budget there")
  func deleteWithReassign() async throws {
    let model = await model()
    let groceryTxns = try await txns().filter { $0.txn.categoryID == groceries }.count
    model.select(groceries)
    model.requestDelete()
    let dialog = try #require(model.dialog)
    #expect(dialog.title == "Delete “Groceries”?")
    #expect(dialog.message.hasPrefix("Groceries is used by \(groceryTxns) transactions and the monthly budget."))
    #expect(dialog.confirmTitle == "Move and delete")
    #expect(dialog.offersArchive)
    #expect(!dialog.targets.contains { $0.id == groceries })
    #expect(!dialog.targets.contains { $0.name == "Salary" })
    #expect(model.reassignTarget == eatingOut)
    await model.confirmDialog()
    #expect(model.category(groceries) == nil)
    let moved = try await txns().filter { $0.txn.categoryID == eatingOut }.count
    #expect(moved >= groceryTxns + 2)
    let plan = try #require(try await store.budgetRepository.plan(for: PreviewData.today.yearMonth))
    #expect(!plan.allocations.contains { $0.categoryID == groceries })
    #expect(plan.allocations.first { $0.categoryID == eatingOut }?.limitMinor == 2_400_00)
  }

  @Test("R-CAT-3: “Archive instead” keeps the category on old transactions")
  func archiveInstead() async throws {
    let model = await model()
    model.select(health)
    model.requestDelete()
    await model.archiveInstead()
    #expect(model.dialog == nil)
    #expect(model.category(health)?.isArchived == true)
    #expect(model.rows.first { $0.id == health }?.isArchived == true)
    #expect(model.archiveTitle == "Unarchive")
    await model.archiveOrUnarchive()
    #expect(model.category(health)?.isArchived == false)
  }

  @Test("R-CAT-3: an unused category is deleted without a target")
  func deleteUnused() async throws {
    let model = await model()
    model.select(travel)
    model.requestDelete()
    let dialog = try #require(model.dialog)
    #expect(dialog.message == "It is not used anywhere.")
    #expect(dialog.confirmTitle == "Delete")
    #expect(!dialog.needsTarget)
    await model.confirmDialog()
    #expect(model.category(travel) == nil)
  }

  @Test("R-CAT-3: deleting a parent moves its subcategories to the top level")
  func deleteParent() async throws {
    let model = await model()
    model.select(transport)
    model.requestDelete()
    let dialog = try #require(model.dialog)
    #expect(dialog.message.contains("Its subcategories (Taxi, Fuel) move to the top level."))
    model.reassignTarget = housing
    await model.confirmDialog()
    #expect(model.category(transport) == nil)
    #expect(model.category(taxi)?.parentID == nil)
    #expect(model.category(fuel)?.parentID == nil)
    let plan = try #require(try await store.budgetRepository.plan(for: PreviewData.today.yearMonth))
    #expect(plan.allocations.first { $0.categoryID == housing }?.limitMinor == 400_00)
  }

  @Test("R-CAT-3: “Move and delete” needs a target for a used category")
  func targetRequired() async {
    let model = await model()
    model.select(groceries)
    model.requestDelete()
    model.reassignTarget = nil
    #expect(!model.canConfirmDialog)
    await model.confirmDialog()
    #expect(model.category(groceries) != nil)
    #expect(model.dialog != nil)
    model.cancelDialog()
    #expect(model.dialog == nil)
  }
}
