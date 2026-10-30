import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C36: the Needs review tab with its Decisions / Categories sub-filters: selection (click,
/// Cmd, Shift) and bulk actions on review cards (synthetic PKO fixture: two review rows, an
/// incoming exchange half and an outgoing unknown-type fee).
@MainActor
struct ImportReviewTabTests {
  private static let account = Account(
    id: PreviewData.id(9401), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let savings = Account(
    id: PreviewData.id(9402), name: "Savings", currency: .PLN, kind: .savings, openingBalanceMinor: 0,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600))
  private static let groceries = AbacusDomain.Category(id: PreviewData.id(9410), name: "Groceries", kind: .expense)
  private static let salary = AbacusDomain.Category(id: PreviewData.id(9411), name: "Salary", kind: .income)

  private func harness() async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [Self.account, Self.savings])
    try await h.saveCategory(Self.groceries)
    try await h.saveCategory(Self.salary)
    await h.model.open(data: try ImportHarness.fixture("pko", "all-types"), fileName: "pko.csv")
    if h.model.needsTargetAccount { await h.model.chooseTargetAccount(Self.account.id) }
    h.model.tab = .review
    return h
  }

  @Test("C36: the review list is the cards first, then the category rows; Cmd toggles and Shift ranges over both")
  func selectionOverReviewList() async throws {
    let h = try await harness()
    let model = h.model
    let cards = model.reviewItems.map(\.id)
    let rows = model.categoryRows.map(\.id)
    let ids = cards + rows
    try #require(cards.count == 2 && rows.count >= 2)
    #expect(model.selectableIDs == ids)

    model.select(cards[1], mode: .replace)
    #expect(model.selection == [cards[1]])
    model.select(cards[0], mode: .toggle)
    #expect(model.selection == [cards[0], cards[1]])
    model.select(cards[1], mode: .toggle)
    #expect(model.selection == [cards[0]])
    // Shift from the last clicked card (the second) across the card/row boundary.
    model.select(rows[1], mode: .range)
    #expect(model.selection == Set(ids[1...3]))
    model.select(cards[0], mode: .range)
    #expect(model.selection == Set(ids[0...1]))
    #expect(model.bulk.selected == 2)

    model.selectAll()
    #expect(model.selection == Set(ids))
  }

  @Test("C36: a sub-filter lists only its part; Select all and range work inside it; changing it clears the selection")
  func subFilters() async throws {
    let h = try await harness()
    let model = h.model
    let cards = model.reviewItems.map(\.id)
    let rows = model.categoryRows.map(\.id)

    model.reviewFilter = .decisions
    #expect(model.selectableIDs == cards)
    model.selectAll()
    #expect(model.selection == Set(cards))
    #expect(model.bulk.selected == 2)

    model.reviewFilter = .categories
    #expect(model.selection.isEmpty)
    #expect(model.selectableIDs == rows)
    model.select(rows[0], mode: .replace)
    model.select(rows[2], mode: .range)
    #expect(model.selection == Set(rows[0...2]))
    model.selectAll()
    #expect(model.selection == Set(rows))

    model.reviewFilter = .all
    #expect(model.selection.isEmpty)
    // The tab change still clears too.
    model.select(cards[0], mode: .replace)
    model.tab = .transactions
    #expect(model.selection.isEmpty)
  }

  @Test("C36: bulk Category on review cards records them as their kind with the category; the other kind is untouched")
  func bulkCategoryOnCards() async throws {
    let h = try await harness()
    let model = h.model
    let income = try #require(model.reviewItems.first { $0.recordKind == .income })
    let expense = try #require(model.reviewItems.first { $0.recordKind == .expense })
    model.select(income.id, mode: .replace)
    model.select(expense.id, mode: .toggle)
    #expect(model.bulk.categoryKinds == [.expense, .income])

    model.bulkSetCategory(Self.salary.id, kind: .income)
    let decidedIncome = try #require(model.reviewItems.first { $0.id == income.id })
    #expect(decidedIncome.selected == .record(.income))
    #expect(decidedIncome.selectedCategory == Self.salary.id)
    #expect(model.reviewItems.first { $0.id == expense.id }?.selected == nil)

    model.bulkSetCategory(Self.groceries.id, kind: .expense)
    let decidedExpense = try #require(model.reviewItems.first { $0.id == expense.id })
    #expect(decidedExpense.selected == .record(.expense))
    #expect(decidedExpense.selectedCategory == Self.groceries.id)
    // The cards stay selected and can be acted on again.
    #expect(model.bulk.selected == 2)
    #expect(model.ruleSheet == nil)
  }

  @Test("C36: bulk Category works on a mixed selection of review cards and category rows")
  func bulkCategoryMixed() async throws {
    let h = try await harness()
    let model = h.model
    let expenseCard = try #require(model.reviewItems.first { $0.recordKind == .expense })
    let expenseRows = model.categoryRows.filter { row in model.preview?.row(row.id)?.type == .expense }
    let row = try #require(expenseRows.first)
    model.select(expenseCard.id, mode: .replace)
    model.select(row.id, mode: .toggle)
    model.bulkSetCategory(Self.groceries.id, kind: .expense)
    #expect(model.reviewItems.first { $0.id == expenseCard.id }?.selectedCategory == Self.groceries.id)
    #expect(model.preview?.row(row.id)?.category == .existing(Self.groceries.id))
    #expect(!model.categoryRows.contains { $0.id == row.id })
  }

  @Test("C36: bulk Skip skips the selected review cards, and Undo takes it back")
  func bulkSkipCards() async throws {
    let h = try await harness()
    let model = h.model
    model.selectAll()
    model.reviewFilter = .decisions
    model.selectAll()
    #expect(model.bulk.skipRows == 2)
    model.bulkSkip()
    #expect(model.reviewItems.allSatisfy { $0.selected == .skip })
    #expect(model.canUndoBulk)
    model.undoBulk()
    #expect(model.reviewItems.allSatisfy { $0.selected == nil })
  }

  @Test("C36: bulk Account turns review cards into transfers to the account")
  func bulkAccountCards() async throws {
    let h = try await harness()
    let model = h.model
    model.reviewFilter = .decisions
    model.selectAll()
    #expect(model.bulk.accountRows == 2)
    model.bulkSetTransfer(to: Self.savings.id)
    #expect(model.reviewItems.allSatisfy { $0.selected == .transfer && $0.selectedTransferAccount == Self.savings.id })
  }

  @Test("C36: bulk Debt records the selected review cards as transfers to a debt account")
  func bulkDebtCards() async throws {
    let h = try await harness()
    let model = h.model
    model.reviewFilter = .decisions
    model.selectAll()
    #expect(model.bulk.debtRows == 2)
    await model.openBulkDebt()
    var draft = try #require(model.debtDraft)
    draft.personName = "Anna"
    model.saveDebt(draft)
    #expect(model.reviewItems.allSatisfy { $0.selected == .debt })
  }
}
