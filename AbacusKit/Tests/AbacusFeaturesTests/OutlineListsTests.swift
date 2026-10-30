import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// WP S2 (D55): drops of the native outline lists (account onto account → new group), editor
/// sheets holding their own draft, the "New account" split button's actions and "New
/// transaction" on the selected account.
@MainActor
@Suite("Outline lists and editor sheets (S2)")
struct OutlineListsTests {
  let store = ManagePreviewStore.sample()
  let mono = PreviewData.monobankGroup.id, pko = PreviewData.pkoGroup.id, revolut = PreviewData.revolutGroup.id
  let black = PreviewData.monobank.id, personal = PreviewData.pkoPersonal.id, usd = PreviewData.pkoUSD.id
  let eur = PreviewData.revolutEUR.id, cash = PreviewData.cashPLN.id
  let deposit = PreviewData.eurDeposit.id, loan = PreviewData.loanFromFriend.id
  let food = PreviewData.id(201), groceries = PreviewData.id(202), housing = PreviewData.id(204)
  let travel = PreviewData.id(214)

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

  func names(_ model: AccountsModel) -> [String] { model.rows.map(\.name) }

  // MARK: Account onto account (D55)

  @Test("D55: an account onto an ungrouped account asks for a name, then a group in its place holds both")
  func accountOntoAccountMakesGroup() async throws {
    let model = await accounts()
    await model.setSort(.nameAscending)
    #expect(model.canDrop(deposit, on: cash, position: .onto))
    let before = names(model)
    await model.drop(deposit, on: cash, position: .onto)
    // Nothing moved yet: the name comes first, suggested from the target's first word.
    let prompt = try #require(model.groupPrompt)
    #expect(prompt.target == cash)
    #expect(prompt.moving == deposit)
    #expect(prompt.defaultName == "Cash")
    #expect(names(model) == before)

    await model.confirmGroupPrompt(name: "  Wallets ")
    #expect(model.groupPrompt == nil)
    let group = try #require(model.groups.first { $0.name == "Wallets" })
    #expect(model.account(cash)?.groupID == group.id)
    #expect(model.account(deposit)?.groupID == group.id)
    // A plain move: the sort stays; the group shows its two accounts beneath it.
    #expect(model.sort == .nameAscending)
    let rows = model.rows
    let at = try #require(rows.firstIndex { $0.id == group.id })
    #expect(rows[at].isGroup)
    #expect(Set(rows[(at + 1)...(at + 2)].map(\.id)) == [cash, deposit])
    #expect(rows[(at + 1)...(at + 2)].allSatisfy { $0.isChild })
    // Stored: survives a reload; balances untouched.
    let again = await accounts()
    #expect(again.account(deposit)?.groupID == group.id)
    #expect(again.account(cash)?.openingBalanceMinor == PreviewData.cashPLN.openingBalanceMinor)
  }

  @Test("D55: in custom order the new group takes the target's place, target first")
  func newGroupKeepsPlace() async throws {
    let model = await accounts()
    #expect(model.sort == .custom)
    let before = names(model)
    let cashIndex = try #require(before.firstIndex(of: "Cash PLN"))
    await model.drop(loan, on: cash, position: .onto)
    await model.confirmGroupPrompt(name: "Mixed")
    let after = names(model)
    #expect(Array(after[cashIndex...(cashIndex + 2)]) == ["Mixed", "Cash PLN", "Loan from friend"])
  }

  @Test("D55: Cancel or an empty name leaves everything; a grouped account leaves its group (which stays)")
  func groupPromptCancelAndLeave() async throws {
    let model = await accounts()
    await model.drop(deposit, on: cash, position: .onto)
    await model.confirmGroupPrompt(name: "   ")
    #expect(model.groupPrompt != nil)
    model.cancelGroupPrompt()
    #expect(model.groupPrompt == nil)
    #expect(model.account(deposit)?.groupID == nil)
    #expect(model.groups.count == 3)

    // Revolut EUR out of Revolut onto Cash PLN: a new group; Revolut stays, empty (D48 folders).
    #expect(model.canDrop(eur, on: cash, position: .onto))
    await model.drop(eur, on: cash, position: .onto)
    await model.confirmGroupPrompt(name: model.groupPrompt?.defaultName ?? "")
    let cashGroup = try #require(model.account(cash)?.groupID)
    #expect(model.account(eur)?.groupID == cashGroup)
    #expect(model.group(revolut) != nil)
    #expect(model.rows.first { $0.id == revolut }?.detail == "0 accounts")
  }

  @Test("D55: onto an account in a group joins that group; groups never nest; not onto itself")
  func ontoGroupedAccount() async throws {
    let model = await accounts()
    #expect(model.canDrop(cash, on: personal, position: .onto))
    await model.drop(cash, on: personal, position: .onto)
    #expect(model.groupPrompt == nil)
    #expect(model.account(cash)?.groupID == pko)
    // A group onto an account or a group: refused (one level).
    #expect(!model.canDrop(mono, on: deposit, position: .onto))
    #expect(!model.canDrop(mono, on: personal, position: .onto))
    #expect(!model.canDrop(mono, on: pko, position: .onto))
    #expect(!model.canDrop(deposit, on: deposit, position: .onto))
    // Out to the top level between top-level rows.
    await model.drop(cash, on: deposit, position: .before)
    #expect(model.account(cash)?.groupID == nil)
  }

  // MARK: Account sheets (D55)

  @Test("D55: the account sheet edits its own draft; Save stores it and closes, Cancel drops it")
  func accountSheet() async throws {
    let model = await accounts()
    model.edit(cash)
    guard case .account(var draft) = model.sheet else {
      Issue.record("no account sheet")
      return
    }
    #expect(model.selection == cash)
    #expect(!model.canSave(draft))
    draft.name = ""
    #expect(model.validationMessage(draft) == "Enter a name.")
    #expect(!model.canSave(draft))
    draft.name = "Cash zł"
    #expect(model.canSave(draft))
    // A reload while the sheet is open never touches the sheet's draft.
    await model.load()
    await model.save(draft)
    #expect(model.sheet == nil)
    #expect(model.account(cash)?.name == "Cash zł")

    model.edit(cash)
    model.dismissSheet()
    #expect(model.sheet == nil)
    #expect(model.selection == cash)
  }

  @Test("D55: New account (main part, in a group, top level) and New group open sheets; Cancel gives the selection back")
  func newAccountSplitButton() async throws {
    let model = await accounts()
    model.select(personal)
    model.newAccount(currency: .PLN)
    guard case .account(let draft) = model.sheet else {
      Issue.record("no account sheet")
      return
    }
    #expect(draft.isNew)
    #expect(draft.groupID == pko)
    model.dismissSheet()
    #expect(model.selection == personal)

    model.newAccount(currency: .EUR, inGroup: revolut)
    guard case .account(var inGroup) = model.sheet else {
      Issue.record("no account sheet")
      return
    }
    #expect(inGroup.groupID == revolut)
    inGroup.name = "Revolut Savings"
    await model.save(inGroup)
    #expect(model.sheet == nil)
    #expect(model.account(inGroup.id)?.groupID == revolut)
    #expect(model.selection == inGroup.id)

    model.newAccount(currency: .UAH, inGroup: nil)
    if case .account(let top) = model.sheet { #expect(top.groupID == nil) } else { Issue.record("no sheet") }
    model.dismissSheet()

    model.newGroup()
    guard case .group(var group) = model.sheet else {
      Issue.record("no group sheet")
      return
    }
    #expect(model.validationMessage(group) == "Enter a name.")
    group.name = "Cash"
    await model.save(group)
    #expect(model.sheet == nil)
    #expect(model.groups.contains { $0.name == "Cash" })
    // A group's own sheet, and Delete group… from it closes the sheet.
    model.edit(group.id)
    guard case .group = model.sheet else {
      Issue.record("no group sheet")
      return
    }
    model.requestDeleteGroup()
    await model.confirmDialog()
    #expect(model.sheet == nil)
    #expect(model.group(group.id) == nil)
  }

  @Test("D55: archiving from the account sheet closes it")
  func archiveFromSheet() async throws {
    let model = await accounts()
    model.edit(deposit)
    await model.archiveOrUnarchive()
    #expect(model.dialog != nil || model.archiveSheet != nil)
    if model.archiveSheet != nil { await model.confirmArchive() } else { await model.confirmDialog() }
    #expect(model.sheet == nil)
    #expect(model.account(deposit)?.isArchived == true)
  }

  // MARK: Category sheets and drops (D55)

  @Test("D55: the category sheet edits its own draft; Uncategorised edits its colour only")
  func categorySheet() async throws {
    let model = await categories()
    model.edit(groceries)
    var draft = try #require(model.sheet)
    #expect(!model.canSave(draft))
    #expect(model.canChangeParent(draft))
    draft.name = "Food shop"
    draft.parentID = housing
    await model.save(draft)
    #expect(model.sheet == nil)
    #expect(model.category(groceries)?.name == "Food shop")
    #expect(model.category(groceries)?.parentID == housing)

    // A parent with subcategories can't change its parent.
    model.edit(food)
    let parent = try #require(model.sheet)
    #expect(!model.canChangeParent(parent))
    #expect(model.parentOptions(parent).allSatisfy { $0.id != food && $0.parentID == nil })
    model.dismissSheet()

    model.edit(CategoriesModel.uncategorisedID)
    var builtIn = try #require(model.sheet)
    #expect(builtIn.isBuiltIn)
    #expect(model.parentOptions(builtIn).isEmpty)
    builtIn.colorHex = "#0F96B0"
    await model.save(builtIn)
    #expect(model.sheet == nil)
    #expect(model.uncategorisedColor == "#0F96B0")

    model.select(food)
    model.newCategory()
    let new = try #require(model.sheet)
    #expect(new.isNew)
    #expect(model.validationMessage(new) == "Enter a name.")
    model.dismissSheet()
    #expect(model.selection == food)
  }

  @Test("D55: categories — onto a top-level row nests, a subcategory between top-level rows goes top level")
  func categoryDrops() async throws {
    let model = await categories()
    #expect(model.canDrop(travel, on: housing, position: .onto))
    await model.drop(travel, on: housing, position: .onto)
    #expect(model.category(travel)?.parentID == housing)
    await model.drop(travel, on: food, position: .before)
    #expect(model.category(travel)?.parentID == nil)
    #expect(model.sort == .custom)
    // One level: a parent with subcategories never nests; Uncategorised is never a target.
    #expect(!model.canDrop(food, on: housing, position: .onto))
    #expect(!model.canDrop(travel, on: CategoriesModel.uncategorisedID, position: .onto))
    // Below the last row: top level, last.
    await model.drop(groceries, on: nil, position: .after)
    #expect(model.category(groceries)?.parentID == nil)
    #expect(model.rows.last?.id == groceries)
  }

  // MARK: New transaction on the selected account (D55)

  @Test("D55: on Accounts, New transaction starts on the selected account and its currency")
  func newTransactionOnAccount() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let session = AppSession.live(
      database: database, source: StubSource(rates: B1Fixture.rates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await session.start()
    defer { session.stop() }
    await session.loadSampleData()
    await session.accounts.load()
    let account = try #require(
      session.accounts.accounts.first { !$0.isArchived && $0.currency == .EUR }
        ?? session.accounts.accounts.first { !$0.isArchived })

    session.app.section = .accounts
    session.accounts.select(nil)
    session.app.requestNewTransaction()
    #expect(session.app.editor == .new)

    session.accounts.select(account.id)
    session.app.requestNewTransaction()
    #expect(session.app.editor == .newInAccount(account.id))

    let editor = TransactionEditorModel(mode: .newInAccount(account.id), dependencies: session.editorDependencies)
    await editor.load()
    #expect(editor.isNew)
    #expect(editor.account?.id == account.id)
    #expect(editor.draft.currencyCode == account.currency.rawValue)

    // Elsewhere the selection doesn't matter.
    session.app.section = .transactions
    session.app.requestNewTransaction()
    #expect(session.app.editor == .new)
  }

  // MARK: Outline proposals → model drops (the list's delegate)

  @Test("D55: outline proposals map to before / after / onto; pinned rows and empty parents handled")
  func outlineResolver() {
    let pin = UUID(), a = UUID(), a1 = UUID(), a2 = UUID(), b = UUID(), empty = UUID()
    let tree = OutlineDropResolver(roots: [
      .init(id: pin, isPinned: true), .init(id: a, children: [a1, a2]), .init(id: b), .init(id: empty),
    ])
    typealias R = OutlineDropResolver.Resolved
    // Onto a row (top level or child); never onto the pinned row.
    #expect(tree.resolve(parent: a, index: nil) == R(target: a, position: .onto, index: nil))
    #expect(tree.resolve(parent: a1, index: nil) == R(target: a1, position: .onto, index: nil))
    #expect(tree.resolve(parent: pin, index: nil) == nil)
    #expect(tree.resolve(parent: UUID(), index: nil) == nil)
    // Between top-level rows: nothing above the pinned row; the end = top level, last.
    #expect(tree.resolve(parent: nil, index: 0) == R(target: a, position: .before, index: 1))
    #expect(tree.resolve(parent: nil, index: 2) == R(target: b, position: .before, index: 2))
    #expect(tree.resolve(parent: nil, index: 4) == R(target: nil, position: .after, index: 4))
    // Inside a parent: before a child, after the last one; an empty parent = onto it.
    #expect(tree.resolve(parent: a, index: 0) == R(target: a1, position: .before, index: 0))
    #expect(tree.resolve(parent: a, index: 2) == R(target: a2, position: .after, index: 2))
    #expect(tree.resolve(parent: empty, index: 0) == R(target: empty, position: .onto, index: nil))
    // The gap around a row when nesting is refused.
    #expect(tree.gap(around: b, upper: true) == R(target: b, position: .before, index: 2))
    #expect(tree.gap(around: b, upper: false) == R(target: empty, position: .before, index: 3))
    #expect(tree.gap(around: a1, upper: false) == R(target: a2, position: .before, index: 1))
    #expect(tree.gap(around: a2, upper: false) == R(target: a2, position: .after, index: 2))
  }

  @Test("D55: resolved proposals drive the real models (categories and accounts)")
  func resolverWithModels() async throws {
    let model = await categories()
    let roots = OutlineDropResolver(
      roots: [.init(id: CategoriesModel.uncategorisedID, isPinned: true)]
        + model.rows.filter { !$0.isChild }.map { row in
          .init(id: row.id, children: model.rows.filter { model.category($0.id)?.parentID == row.id }.map(\.id))
        })
    // Travel dragged into Food's children, at index 0: before Groceries → a subcategory of Food.
    let into = try #require(roots.resolve(parent: food, index: 0))
    #expect(model.canDrop(travel, on: into.target, position: into.position))
    await model.drop(travel, on: into.target, position: into.position)
    #expect(model.category(travel)?.parentID == food)
    #expect(model.rows.drop { $0.id != food }.dropFirst().first?.id == travel)
    // Dropped at the very top (above Uncategorised): first top-level category.
    let top = try #require(roots.resolve(parent: nil, index: 0))
    await model.drop(travel, on: top.target, position: top.position)
    #expect(model.category(travel)?.parentID == nil)
    #expect(model.rows.first?.id == travel)
  }
}
