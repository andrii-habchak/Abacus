import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C31: selection, the Category assignment tab, bulk Category/Account/Debt/Skip, rule
/// suggestions and "+ New category…" of the import wizard (synthetic PKO fixture).
@MainActor
struct ImportBulkTests {
  private static let account = Account(
    id: PreviewData.id(9301), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let savings = Account(
    id: PreviewData.id(9302), name: "Savings", currency: .PLN, kind: .savings, openingBalanceMinor: 0,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600))
  private static let groceries = AbacusDomain.Category(id: PreviewData.id(9310), name: "Groceries", kind: .expense)
  private static let salary = AbacusDomain.Category(id: PreviewData.id(9311), name: "Salary", kind: .income)

  /// The wizard on the PKO fixture, categories saved, Category assignment tab open.
  private func harness(categories: Bool = true) async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [Self.account, Self.savings])
    if categories {
      try await h.saveCategory(Self.groceries)
      try await h.saveCategory(Self.salary)
    }
    await h.model.open(data: try ImportHarness.fixture("pko", "all-types"), fileName: "pko.csv")
    if h.model.needsTargetAccount { await h.model.chooseTargetAccount(Self.account.id) }
    return h
  }

  // MARK: Tab and counts

  @Test("C36: Needs review counts decisions and rows that need a category, each row once; the sub-filters split them")
  func tabAndCount() async throws {
    let h = try await harness()
    let model = h.model
    let needing = model.rowItems.filter(\.needsCategory)
    #expect(needing.count > 1)
    #expect(model.categoryRows.map(\.id) == needing.map(\.id))
    let decisions = model.reviewItems.count
    #expect(decisions == 2)
    #expect(Set(model.reviewItems.map(\.id)).isDisjoint(with: model.categoryRows.map(\.id)))
    let total = decisions + needing.count
    #expect(model.needsReviewTotal == total)
    #expect(model.tabs.first { $0.tab == .review }?.label == "Needs review (\(total))")
    #expect(model.tabs.contains { $0.label.hasPrefix("Category assignment") } == false)
    #expect(model.cards.first { $0.status == .needsReview }?.count == "\(total)")
    #expect(model.reviewFilters.map(\.label) == ["All (\(total))", "Decisions (\(decisions))", "Categories (\(needing.count))"])
    #expect(model.reviewFilter == .all)

    let first = try #require(needing.first)
    model.setCategory(.existing(Self.groceries.id), forRow: first.id)
    #expect(model.categoryRows.count == needing.count - 1)
    #expect(model.tabs.first { $0.tab == .review }?.label == "Needs review (\(total - 1))")
    #expect(model.cards.first { $0.status == .needsReview }?.count == "\(total - 1)")
  }

  // MARK: Selection

  @Test("C31: click selects one row, Cmd+click toggles, Shift+click ranges from the last click; a tab change clears it")
  func selectionSemantics() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    let ids = model.categoryRows.map(\.id)
    try #require(ids.count >= 4)

    model.select(ids[1], mode: .replace)
    #expect(model.selection == [ids[1]])
    model.select(ids[3], mode: .toggle)
    #expect(model.selection == [ids[1], ids[3]])
    model.select(ids[1], mode: .toggle)
    #expect(model.selection == [ids[3]])
    // Range from the last clicked row (the anchor is ids[1] after the second toggle).
    model.select(ids[0], mode: .range)
    #expect(model.selection == Set(ids[0...1]))
    model.select(ids[3], mode: .range)
    #expect(model.selection == Set(ids[1...3]))
    model.select(ids[2], mode: .replace)
    #expect(model.selection == [ids[2]])
    model.select(ids[0], mode: .range)
    #expect(model.selection == Set(ids[0...2]))

    model.tab = .transactions
    #expect(model.selection.isEmpty)
  }

  @Test("C31: rows that leave the list (categorised) leave the selection")
  func selectionPruned() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    let ids = model.categoryRows.map(\.id)
    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    model.setCategory(.existing(Self.groceries.id), forRow: ids[0])
    #expect(model.selection == [ids[1]])
  }

  // MARK: Bulk category and rules

  @Test("C31: bulk Category sets the category on the selected rows of one kind; the other kind keeps its own menu")
  func bulkCategory() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    model.selectAll()
    let info = model.bulk
    #expect(info.selected == model.categoryRows.count)
    #expect(info.expenseRows + info.incomeRows == info.selected)
    let expenses = info.expenseRows
    try #require(expenses > 1)

    model.bulkSetCategory(Self.groceries.id, kind: .expense)
    #expect(model.categoryRows.count == info.incomeRows)
    #expect(model.bulkMessage == "Category set on \(expenses) rows.")
    let picked = model.rowItems.filter { item in
      if case .picker(.existing(Self.groceries.id), _, _) = item.category { return true }
      return false
    }
    #expect(picked.count == expenses)
    #expect(model.selection.count == info.incomeRows)

    // One step back.
    #expect(model.canUndoBulk)
    model.undoBulk()
    #expect(model.categoryRows.count == info.selected)
  }

  @Test("C31: after a bulk Category one rule per distinct pattern is suggested; confirming applies ticks and edited text")
  func ruleSuggestions() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    model.selectAll()
    model.bulkSetCategory(Self.groceries.id, kind: .expense)
    let sheet = try #require(model.ruleSheet)
    let preview = try #require(model.preview)
    let patterns = sheet.suggestions.map(\.pattern)
    #expect(Set(patterns).count == patterns.count)
    #expect(sheet.suggestions.allSatisfy { $0.categoryID == Self.groceries.id && $0.isOn && $0.isValid })
    // Grouped: the rows behind the suggestions are exactly the rows that got a rule pattern.
    #expect(sheet.suggestions.flatMap(\.rowIDs).count == preview.rows.filter { $0.rulePattern != nil }.count)
    #expect(sheet.suggestions.contains { $0.rowCount > 1 } || sheet.suggestions.count == preview.rulesToSave.count)
    #expect(preview.rulesToSave.count == sheet.suggestions.count)

    var edited = sheet
    edited.suggestions[0].pattern = "  My Edited  Pattern "
    if edited.suggestions.count > 1 { edited.suggestions[1].isOn = false }
    model.ruleSheet = edited
    model.applyRuleSheet()
    #expect(model.ruleSheet == nil)
    let saved = try #require(model.preview).rulesToSave.map(\.pattern)
    #expect(saved.contains("my edited pattern"))
    #expect(saved.count == sheet.suggestions.count - (sheet.suggestions.count > 1 ? 1 : 0))

    model.acceptSuggestions()
    await model.commit()
    #expect(model.step == .done)
    #expect(try await h.rules().map(\.pattern).contains("my edited pattern"))
  }

  @Test("C31: a payee that already has an enabled rule is not offered again")
  func existingRuleNotOffered() async throws {
    let h = try await harness()
    try await SQLiteRuleRepository(database: h.database).save(
      CategoryRule(pattern: "grocery store", categoryID: Self.groceries.id, origin: .manual, hitCount: 0, position: 0))
    await h.model.open(data: try ImportHarness.fixture("pko", "all-types"), fileName: "pko.csv")
    if h.model.needsTargetAccount { await h.model.chooseTargetAccount(Self.account.id) }
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    model.selectAll()
    model.bulkSetCategory(Self.groceries.id, kind: .expense)
    let patterns = model.ruleSheet?.suggestions.map(\.pattern) ?? []
    #expect(!patterns.contains("grocery store"))
  }

  // MARK: Bulk account, debt, skip

  @Test("C31: bulk Account makes the selected rows transfers to the chosen own account")
  func bulkAccount() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    let ids = Array(model.categoryRows.map(\.id).prefix(2))
    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    #expect(model.bulk.accountRows == 2)
    model.bulkSetTransfer(to: Self.savings.id)
    let rows = try #require(model.preview).rows.filter { ids.contains($0.id) }
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.type == .transfer && $0.counterAccount == .existing(Self.savings.id) })
    #expect(model.rowItems.filter { ids.contains($0.id) }.allSatisfy { $0.statusLabel == "New transfer" })
    #expect(model.categoryRows.count == (model.preview?.uncategorisedCount ?? -1))
    #expect(model.bulkMessage?.contains("transfer") == true)

    // The own account itself is refused.
    model.select(ids[0], mode: .replace)
    model.bulkSetTransfer(to: Self.account.id)
    #expect(model.bulkMessage?.contains("None of the selected rows") == true)
  }

  @Test("C31: bulk Debt records the selected rows as transfers to one debt account")
  func bulkDebt() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    let ids = Array(model.categoryRows.map(\.id).prefix(2))
    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    #expect(model.bulk.debtRows == 2)
    await model.openBulkDebt()
    var draft = try #require(model.debtDraft)
    #expect(draft.title.hasPrefix("Transfer 2 payments"))
    draft.personName = "Anna"
    model.saveDebt(draft)
    #expect(model.debtDraft == nil)
    for id in ids {
      let item = try #require(model.rowItems.first { $0.id == id })
      #expect(item.statusLabel == "Transfer to debt")
      #expect(item.debt?.hasPrefix("Transfer to debt · Anna") == true)
    }
    #expect(model.bulkMessage?.contains("debt account of “Anna”") == true)
  }

  @Test("C31: bulk Skip leaves rows out (new rows, duplicates, review rows); Include brings them back")
  func bulkSkipAndInclude() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    let ids = Array(model.categoryRows.map(\.id).prefix(2))
    let imports = try #require(model.preview).transactionsToCreate
    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    #expect(model.bulk.skipRows == 2)
    model.bulkSkip()
    #expect(model.rowItems.filter { ids.contains($0.id) }.allSatisfy { $0.status == .skipped && $0.excludedByUser })
    #expect(try #require(model.preview).transactionsToCreate == imports - 2)
    #expect(model.categoryRows.map(\.id).filter(ids.contains).isEmpty)

    // They are gone from the assignment list, so look at all rows and include them again.
    model.tab = .transactions
    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    #expect(model.bulk.includeRows == 2)
    model.bulkInclude()
    #expect(try #require(model.preview).transactionsToCreate == imports)
    #expect(model.rowItems.filter { ids.contains($0.id) }.allSatisfy { $0.status == .new })

    // Review rows: Skip sets the review choice.
    let review = try #require(model.reviewItems.first)
    model.tab = .review
    model.reviewFilter = .decisions
    model.select(review.id, mode: .replace)
    model.bulkSkip()
    #expect(model.reviewItems.first { $0.id == review.id }?.selected == .skip)
  }

  @Test("C31: selection works in the review cards; a bulk Category records the review rows as that kind")
  func bulkReviewRows() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    let item = try #require(model.reviewItems.first)
    model.select(item.id, mode: .replace)
    #expect(model.bulk.selected == 1)
    let kind = item.recordKind
    #expect(model.bulk.categoryKinds == [kind])
    let category = kind == .income ? Self.salary.id : Self.groceries.id
    model.bulkSetCategory(category, kind: kind)
    let decided = try #require(model.reviewItems.first { $0.id == item.id })
    #expect(decided.selected == .record(kind))
    #expect(decided.selectedCategory == category)
    // Review rows get no learned rule.
    #expect(model.ruleSheet == nil)
  }

  // MARK: Categories created during the import

  @Test("C31: a category created while the wizard is open shows in the row pickers after a refresh and can be selected")
  func categoryRefresh() async throws {
    let h = try await harness(categories: false)
    let model = h.model
    let row = try #require(model.rowItems.first { $0.needsCategory })
    guard case .picker(_, let before, _) = row.category else { Issue.record("no picker"); return }
    #expect(!before.contains { $0.label == "Pets" })

    // Created elsewhere (the Categories page), not through the wizard.
    let pets = AbacusDomain.Category(id: PreviewData.id(9320), name: "Pets", kind: .expense)
    try await SQLiteCategoryRepository(database: h.database).save(pets)
    await model.refreshReference()
    guard case .picker(_, let after, _) = try #require(model.rowItems.first { $0.id == row.id }).category else {
      Issue.record("no picker")
      return
    }
    #expect(after.contains { $0.choice == .existing(pets.id) })
    model.setCategory(.existing(pets.id), forRow: row.id)
    #expect(model.preview?.row(row.id)?.category == .existing(pets.id))
    // The preview knows the new category too: the pick is offered as a rule.
    #expect(model.preview?.rulesToSave.isEmpty == false)
  }

  @Test("C31: + New category… creates the category with the row's kind and an optional parent, and selects it for the row")
  func newCategoryFromRow() async throws {
    let h = try await harness()
    let model = h.model
    let row = try #require(model.rowItems.first { $0.needsCategory })
    guard case .picker(_, let options, _) = row.category else { Issue.record("no picker"); return }
    #expect(options.last?.choice == .createNew)
    #expect(options.last?.label == "+ New category…")

    model.setCategory(.createNew, forRow: row.id)
    var draft = try #require(model.newCategoryDraft)
    #expect(draft.kind == .expense)
    #expect(draft.target == .row(row.id))
    #expect(model.newCategoryParents(.expense).map(\.id) == [Self.groceries.id])
    draft.name = " Pets "
    draft.parentID = Self.groceries.id
    await model.saveNewCategory(draft)
    #expect(model.newCategoryDraft == nil)

    let stored = try await SQLiteCategoryRepository(database: h.database).categories(kind: .expense, includeArchived: false)
    let created = try #require(stored.first { $0.name == "Pets" })
    #expect(created.parentID == Self.groceries.id && created.kind == .expense)
    #expect(model.preview?.row(row.id)?.category == .existing(created.id))
    guard case .picker(.existing(let selected), let options2, _) = try #require(model.rowItems.first { $0.id == row.id }).category else {
      Issue.record("not selected")
      return
    }
    #expect(selected == created.id)
    #expect(options2.contains { $0.label == "Groceries › Pets" })

    // The same name again selects the existing category instead of a duplicate.
    let other = try #require(model.rowItems.first { $0.needsCategory })
    model.beginNewCategory(forRow: other.id)
    var again = try #require(model.newCategoryDraft)
    again.name = "pets"
    again.parentID = Self.groceries.id
    await model.saveNewCategory(again)
    let all = try await SQLiteCategoryRepository(database: h.database).categories(kind: .expense, includeArchived: true)
    #expect(all.filter { $0.name.lowercased() == "pets" }.count == 1)
    #expect(model.preview?.row(other.id)?.category == .existing(created.id))
  }

  @Test("C31: + New category… from the bulk bar creates a category and assigns it to the selection")
  func newCategoryForSelection() async throws {
    let h = try await harness()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .categories
    model.selectAll()
    let expenses = model.bulk.expenseRows
    model.beginNewCategoryForSelection(kind: .expense)
    var draft = try #require(model.newCategoryDraft)
    draft.name = "Misc"
    await model.saveNewCategory(draft)
    let created = try #require(
      try await SQLiteCategoryRepository(database: h.database).categories(kind: .expense, includeArchived: false)
        .first { $0.name == "Misc" })
    let assigned = model.preview?.rows.filter { $0.category == .existing(created.id) }.count
    #expect(assigned == expenses)
  }
}
