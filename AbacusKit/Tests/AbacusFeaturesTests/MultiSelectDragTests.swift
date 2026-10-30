import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

/// WP C27: multi-selection on the Accounts and Categories lists — the selection set, what a
/// multi-row drag really moves, and the drop rules applied to every dragged row (reorder, nest,
/// group creation, refusal) — plus the drag edge auto-scroll step.
@MainActor
@Suite("Multi-select drag and drop (C27)")
struct MultiSelectDragTests {
  let store = ManagePreviewStore.sample()
  let mono = PreviewData.monobankGroup.id, pko = PreviewData.pkoGroup.id, revolut = PreviewData.revolutGroup.id
  let black = PreviewData.monobank.id, personal = PreviewData.pkoPersonal.id, usd = PreviewData.pkoUSD.id
  let eur = PreviewData.revolutEUR.id, cash = PreviewData.cashPLN.id
  let deposit = PreviewData.eurDeposit.id, loan = PreviewData.loanFromFriend.id
  let food = PreviewData.id(201), groceries = PreviewData.id(202)
  let rent = PreviewData.id(205), health = PreviewData.id(209)
  let fees = PreviewData.id(213), travel = PreviewData.id(214), salary = PreviewData.id(251)

  func accounts() async -> AccountsModel {
    let model = AccountsModel(dependencies: ManageFixture.dependencies(store), displayCurrency: .UAH)
    await model.load()
    return model
  }

  func categories() async -> CategoriesModel {
    let model = CategoriesModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  func order(_ model: AccountsModel) -> [UUID] { model.rows.map(\.id) }
  func order(_ model: CategoriesModel) -> [UUID] { model.rows.map(\.id) }

  /// The ids of `ids` as they appear in `order`, to compare relative positions.
  func relative(_ ids: [UUID], in order: [UUID]) -> [UUID] { order.filter(ids.contains) }

  // MARK: Selection

  @Test("Accounts: several rows are a multi-selection, the inspector selection is cleared; one row is a plain selection")
  func accountSelection() async throws {
    let model = await accounts()
    model.select(ids: [cash, deposit])
    #expect(model.selection == nil)
    #expect(model.selectedIDs == [cash, deposit])
    #expect(model.draft == nil)
    #expect(model.groupDraft == nil)

    // Unknown ids are ignored; a single known id is the ordinary selection again.
    model.select(ids: [cash, UUID()])
    #expect(model.selection == cash)
    #expect(model.multiSelection.isEmpty)
    #expect(model.draft?.id == cash)

    model.select(ids: [mono, cash, loan])
    #expect(model.selectedIDs == [mono, cash, loan])
    // A reload keeps the rows that still exist.
    await model.load()
    #expect(model.selectedIDs == [mono, cash, loan])
    model.select(ids: [])
    #expect(model.selectedIDs.isEmpty)
  }

  @Test("Categories: several rows are a multi-selection; Uncategorised can be part of it")
  func categorySelection() async throws {
    let model = await categories()
    model.select(ids: [health, fees, food])
    #expect(model.selection == nil)
    #expect(model.selectedIDs == [health, fees, food])
    #expect(model.draft == nil)
    model.select(ids: [health, salary])  // salary is on the other tab
    #expect(model.selection == health)
    model.select(ids: [CategoriesModel.uncategorisedID, health])
    #expect(model.selectedIDs == [CategoriesModel.uncategorisedID, health])
    await model.load()
    #expect(model.selectedIDs == [CategoriesModel.uncategorisedID, health])
    model.select(health)
    #expect(model.multiSelection.isEmpty)
  }

  // MARK: What a drag moves

  @Test("A selected group carries its accounts: they are not moved twice; list order, unknown ids dropped")
  func draggedItems() async throws {
    let model = await accounts()
    let items = model.draggedItems([loan, personal, pko, cash, UUID(), usd])
    #expect(items == relative([pko, cash, loan], in: order(model)))
    // The group's own accounts alone are moved on their own.
    #expect(model.draggedItems([usd, personal]) == relative([usd, personal], in: order(model)))

    let cats = await categories()
    #expect(cats.draggedItems([groceries, health, food]) == relative([food, health], in: order(cats)))
    #expect(cats.draggedItems([CategoriesModel.uncategorisedID, health]) == [health])
  }

  // MARK: Accounts

  @Test("Between rows: the selection lands before / after the row in list order (custom order)")
  func accountReorder() async throws {
    let model = await accounts()
    let selection = [loan, cash, deposit]
    let list = relative(selection, in: order(model))
    #expect(model.canDrop(selection, on: mono, position: .before))
    await model.drop(selection, on: mono, position: .before)
    #expect(model.sort == .custom)
    var rows = order(model)
    let at = try #require(rows.firstIndex(of: mono))
    #expect(Array(rows[(at - 3)..<at]) == list)
    #expect(selection.allSatisfy { model.account($0)?.groupID == nil })

    // After an account inside a group: they join that group, right below it, in order.
    await model.drop(selection, on: personal, position: .after)
    rows = order(model)
    let p = try #require(rows.firstIndex(of: personal))
    #expect(Array(rows[(p + 1)...(p + 3)]) == list)
    #expect(list.allSatisfy { model.account($0)?.groupID == pko })
    #expect(Set(model.groups.map(\.id)) == [mono, pko, revolut])
  }

  @Test("Onto a group: every account joins it; accounts already in it are skipped")
  func accountOntoGroup() async throws {
    let model = await accounts()
    #expect(model.account(black)?.groupID == mono)
    #expect(model.canDrop([black, cash, deposit], on: mono, position: .onto))
    await model.drop([black, cash, deposit], on: mono, position: .onto)
    #expect(model.account(cash)?.groupID == mono)
    #expect(model.account(deposit)?.groupID == mono)
    #expect(model.account(black)?.groupID == mono)
    #expect(model.groupPrompt == nil)
    // Nothing left to move: refused, like a single account already in the group.
    #expect(!model.canDrop([black, cash], on: mono, position: .onto))
    #expect(!model.canDrop(black, on: mono, position: .onto))
  }

  @Test("Onto an ungrouped account: one prompt, one group holding the target and every dragged account")
  func accountGroupCreation() async throws {
    let model = await accounts()
    #expect(model.canDrop([deposit, loan, eur], on: cash, position: .onto))
    await model.drop([loan, deposit, eur], on: cash, position: .onto)
    let prompt = try #require(model.groupPrompt)
    #expect(prompt.target == cash)
    #expect(prompt.allMoving == relative([loan, deposit, eur], in: order(model)))
    #expect(prompt.defaultName == "Cash")
    await model.confirmGroupPrompt(name: "Wallets")
    let group = try #require(model.groups.first { $0.name == "Wallets" })
    for id in [cash, deposit, loan, eur] { #expect(model.account(id)?.groupID == group.id) }
    let rows = order(model)
    let at = try #require(rows.firstIndex(of: group.id))
    #expect(rows[at + 1] == cash)
    #expect(Set(rows[(at + 2)...(at + 4)]) == [deposit, loan, eur])
  }

  @Test("Refusals: a group among accounts onto an account or group, a row onto itself, nothing changes")
  func accountRefusals() async throws {
    let model = await accounts()
    let before = order(model)
    #expect(!model.canDrop([mono, cash], on: pko, position: .onto))
    #expect(!model.canDrop([mono, cash], on: deposit, position: .onto))
    #expect(!model.canDrop([cash, deposit], on: cash, position: .onto))
    #expect(!model.canDrop([cash, deposit], on: cash, position: .before))
    #expect(!model.canDrop([cash, deposit], on: deposit, position: .after))
    #expect(!model.canDrop([UUID(), UUID()], on: cash, position: .before))
    #expect(!model.canDrop([], on: cash, position: .before))
    await model.drop([mono, cash], on: pko, position: .onto)
    await model.drop([cash, deposit], on: cash, position: .onto)
    #expect(model.groupPrompt == nil)
    #expect(order(model) == before)
  }

  @Test("A group moved together with its own accounts: nothing is duplicated, the hierarchy stays")
  func groupWithItsChildren() async throws {
    let model = await accounts()
    let accountsBefore = model.accounts.count
    let members = Set(model.accounts.filter { $0.groupID == pko }.map(\.id))
    #expect(members.count >= 2)
    let selection = [cash, pko] + Array(members)
    #expect(model.canDrop(selection, on: revolut, position: .after))
    await model.drop(selection, on: revolut, position: .after)
    #expect(model.accounts.count == accountsBefore)
    #expect(model.groups.count == 3)
    #expect(Set(model.accounts.filter { $0.groupID == pko }.map(\.id)) == members)
    #expect(model.account(cash)?.groupID == revolut)  // right below a group: its first account (single-item rule)
    let rows = order(model)
    let r = try #require(rows.firstIndex(of: revolut))
    let p = try #require(rows.firstIndex(of: pko))
    #expect(p > r)
    // The group's block (group + its accounts) stays contiguous.
    #expect(Set(rows[(p + 1)...(p + members.count)]) == members)
    #expect(Set(rows).count == rows.count)
    // Dropping the group into its own account is refused.
    #expect(!model.canDrop([pko, cash], on: personal, position: .onto))
    #expect(!model.canDrop([pko, cash], on: personal, position: .before))
  }

  @Test("Regression: a one-element drop equals the single-item drop")
  func singleItemRegression() async throws {
    let single = await accounts()
    let multi = await accounts()
    await single.drop(cash, on: mono, position: .before)
    await multi.drop([cash], on: mono, position: .before)
    #expect(order(single) == order(multi))
    #expect(single.canDrop(cash, on: personal, position: .onto) == multi.canDrop([cash], on: personal, position: .onto))
    await single.drop(deposit, on: cash, position: .onto)
    await multi.drop([deposit], on: cash, position: .onto)
    #expect(single.groupPrompt?.target == multi.groupPrompt?.target)
    #expect(multi.groupPrompt?.alsoMoving == [])
  }

  // MARK: Categories

  @Test("Between rows: the selection lands in list order at the top level; subcategories come out")
  func categoryReorder() async throws {
    let model = await categories()
    #expect(model.canDrop([fees, health, rent], on: food, position: .before))
    await model.drop([fees, health, rent], on: food, position: .before)
    #expect(model.sort == .custom)
    var rows = order(model)
    let at = try #require(rows.firstIndex(of: food))
    #expect(Set(rows[(at - 3)..<at]) == [health, fees, rent])
    #expect(model.category(rent)?.parentID == nil)

    await model.drop([health, fees], on: travel, position: .after)
    rows = order(model)
    let t = try #require(rows.firstIndex(of: travel))
    #expect(Array(rows[(t + 1)...(t + 2)]) == relative([health, fees], in: rows))
  }

  @Test("Onto a category: they become its subcategories, last, in list order; a parent keeps its own children")
  func categoryNest() async throws {
    let model = await categories()
    #expect(model.canDrop([fees, health], on: travel, position: .onto))
    await model.drop([fees, health], on: travel, position: .onto)
    #expect(model.category(health)?.parentID == travel)
    #expect(model.category(fees)?.parentID == travel)
    let rows = order(model)
    let t = try #require(rows.firstIndex(of: travel))
    #expect(Array(rows[(t + 1)...(t + 2)]) == relative([health, fees], in: rows))
    // Selected parent and its own subcategory: the parent carries it.
    let cats = await categories()
    await cats.drop([food, groceries], on: travel, position: .before)
    #expect(cats.category(groceries)?.parentID == food)
    #expect(cats.category(food)?.parentID == nil)
  }

  @Test("Refusals: a parent with subcategories onto a row, onto itself, Uncategorised; nothing changes")
  func categoryRefusals() async throws {
    let model = await categories()
    let before = order(model)
    #expect(!model.canDrop([food, health], on: travel, position: .onto))
    #expect(!model.canDrop([health, fees], on: health, position: .onto))
    #expect(!model.canDrop([health, fees], on: fees, position: .before))
    #expect(!model.canDrop([CategoriesModel.uncategorisedID, health], on: travel, position: .onto))
    #expect(!model.canDrop([health, salary], on: travel, position: .onto))
    #expect(!model.canDrop([], on: travel, position: .before))
    await model.drop([food, health], on: travel, position: .onto)
    #expect(order(model) == before)
    #expect(model.category(health)?.parentID == nil)
  }

  @Test("Regression: a one-element category drop equals the single-item drop")
  func categorySingleRegression() async throws {
    let single = await categories()
    let multi = await categories()
    await single.drop(health, on: travel, position: .onto)
    await multi.drop([health], on: travel, position: .onto)
    #expect(order(single) == order(multi))
    #expect(single.category(health)?.parentID == multi.category(health)?.parentID)
    #expect(single.canDrop(food, on: travel, position: .onto) == multi.canDrop([food], on: travel, position: .onto))
  }

  // MARK: Edge auto-scroll

  @Test("Edge auto-scroll: nothing in the middle, up near the top, down near the bottom, faster further out")
  func edgeScroll() {
    let height = 400.0
    #expect(OutlineAutoScroll.step(y: 200, height: height) == 0)
    #expect(OutlineAutoScroll.step(y: OutlineAutoScroll.edgeZone, height: height) == 0)
    let near = OutlineAutoScroll.step(y: 30, height: height)
    let edge = OutlineAutoScroll.step(y: 2, height: height)
    #expect(near < 0 && edge < near)
    #expect(OutlineAutoScroll.step(y: -50, height: height) == -OutlineAutoScroll.maxStep)
    let down = OutlineAutoScroll.step(y: height - 30, height: height)
    #expect(down > 0 && OutlineAutoScroll.step(y: height + 40, height: height) == OutlineAutoScroll.maxStep)
    // A list shorter than two edge zones never auto-scrolls.
    #expect(OutlineAutoScroll.step(y: 5, height: 60) == 0)
  }
}
