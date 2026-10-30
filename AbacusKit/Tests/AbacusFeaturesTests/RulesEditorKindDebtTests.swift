import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import Testing

/// C32: the rule editor's Expense / Income select and the debt picker. Synthetic data only.
@MainActor
@Suite("Rule editor: category kind and debt picker (C32)")
struct RulesEditorKindDebtTests {
  static let calendar = ImportHarness.calendar

  func model(debts: Bool = true) async throws -> (RulesModel, SQLiteDebtRepository) {
    let database = try AbacusDatabase.open(at: nil)
    let repository = SQLiteDebtRepository(database: database, calendar: Self.calendar)
    var dependencies = ManageFixture.dependencies(ManagePreviewStore.sample())
    if debts { dependencies.debts = repository }
    let model = RulesModel(dependencies: dependencies)
    await model.load()
    return (model, repository)
  }

  @Test("R-MGMT-6, C32: a new draft starts on Expense; the options list only categories of the kind, A–Z")
  func optionsFiltered() async throws {
    let (model, _) = try await model()
    model.newRule()
    #expect(model.editor?.categoryKind == .expense)
    let expense = model.categoryOptions(kind: .expense)
    let income = model.categoryOptions(kind: .income)
    #expect(!expense.isEmpty && expense.allSatisfy { $0.kind == .expense })
    #expect(income.map(\.name) == ["Cashback", "Refunds", "Salary"])
    #expect(expense.first?.name == "Bills" && expense.count + income.count == model.categoryOptions.count)
  }

  @Test("R-MGMT-6, C32: editing an income rule opens on Income; changing the kind clears a category of the other kind")
  func kindFollowsCategory() async throws {
    let (model, _) = try await model()
    let salary = try #require(model.categories.first { $0.name == "Salary" })
    let food = try #require(model.categories.first { $0.name == "Groceries" })
    let rule = CategoryRule(pattern: "payroll", categoryID: salary.id, position: 99)
    try await model.dependencies.rules.save(rule)
    await model.load()
    model.edit(rule.id)
    #expect(model.editor?.categoryKind == .income && model.editor?.categoryID == salary.id)
    #expect(model.editorValidation == nil)
    model.setCategoryKind(.income)
    #expect(model.editor?.categoryID == salary.id)
    model.setCategoryKind(.expense)
    #expect(model.editor?.categoryKind == .expense && model.editor?.categoryID == nil)
    #expect(model.editorValidation == "Choose a category.")
    model.editor?.categoryID = food.id
    #expect(model.editorValidation == nil)
    // An existing expense rule opens on Expense.
    model.cancelEditor()
    model.edit(ManageSample.rules[0].id)
    #expect(model.editor?.categoryKind == .expense)
  }

  @Test("R-MGMT-6, C32: a category of the other kind than the select is rejected")
  func validationRejectsOtherKind() async throws {
    let (model, _) = try await model()
    let salary = try #require(model.categories.first { $0.name == "Salary" })
    model.newRule()
    model.editor?.pattern = "payroll"
    model.editor?.categoryID = salary.id
    #expect(model.editorValidation == "Choose an expense category.")
    #expect(model.editorRule == nil)
    model.setCategoryKind(.income)
    model.editor?.categoryID = salary.id
    #expect(model.editorValidation == nil)
    #expect(model.editorRule?.categoryID == salary.id)
  }

  @Test("R-MGMT-11, C32: the page filter lists Expense and Income sections")
  func filterSections() async throws {
    let (model, _) = try await model()
    #expect(model.categoryFilterSections.map(\.kind) == [.expense, .income])
    #expect(model.categoryFilterSections.last?.categories.map(\.name) == ["Cashback", "Refunds", "Salary"])
  }

  @Test("R-MGMT-6, C32: the editor's Update existing transactions respects the kind (income rule changes income only)")
  func editorChangesRespectKind() async throws {
    let (model, _) = try await model()
    let refunds = try #require(model.categories.first { $0.name == "Refunds" })
    model.newRule()
    model.editor?.pattern = "a"
    model.editor?.hasAmountCondition = false
    model.setCategoryKind(.income)
    model.editor?.categoryID = refunds.id
    await model.loadEditorTransactions()
    let changes = try #require(model.editorChanges)
    #expect(!changes.isEmpty && changes.allSatisfy { $0.type == .income })
  }

  // MARK: Debt picker

  @Test("R-DEBT-12, C32: the picker lists existing debts A–Z; picking stores the person's name")
  func debtPicker() async throws {
    let (model, repository) = try await model()
    for name in ["Zoe", "Anna", "Mark"] { try await repository.save(Debt(personName: name)) }
    await model.load()
    #expect(model.debtOptions.map(\.personName) == ["Anna", "Mark", "Zoe"])
    model.newRule()
    model.editor?.pattern = "x"
    model.editor?.action = .debt
    #expect(model.editorValidation == "Choose a debt.")
    model.selectDebt(model.debtOptions[1].id)
    #expect(model.editor?.debtPersonName == "Mark" && model.editorDebt?.personName == "Mark")
    #expect(model.editorValidation == nil)
    #expect(model.editorRule?.debtPersonName == "Mark")
  }

  @Test("R-DEBT-12, C32: + New debt creates the debt by name through the repository and picks it; an existing person is only picked")
  func newDebt() async throws {
    let (model, repository) = try await model()
    model.newRule()
    model.editor?.action = .debt
    await model.createDebt(named: "  Ola ")
    #expect(model.editor?.debtPersonName == "Ola")
    #expect(try await repository.book().debts.map(\.personName) == ["Ola"])
    await model.createDebt(named: "OLA")
    #expect(try await repository.book().debts.count == 1)
    #expect(model.editor?.debtPersonName == "Ola")
    await model.createDebt(named: "   ")
    #expect(model.editor?.debtPersonName == "Ola")
  }

  @Test("R-DEBT-12, C32: a rule whose debt is gone warns in the list and in the editor, and cannot be saved until another debt is chosen")
  func staleDebt() async throws {
    let (model, repository) = try await model()
    try await repository.save(Debt(personName: "Anna"))
    let rule = CategoryRule(id: PreviewDataID.rule, pattern: "anna", action: .debt, debtPersonName: "Anna", position: 99)
    try await model.dependencies.rules.save(rule)
    await model.load()
    #expect(model.rows.first { $0.id == rule.id }?.warning == nil)
    #expect(model.actionText(rule) == "Transfer to debt · Anna")
    // The debt is deleted (a rename leaves the old name unmatched the same way).
    let debt = try #require(try await repository.book().debts.first)
    try await repository.delete(debt.id)
    await model.load()
    let row = try #require(model.rows.first { $0.id == rule.id })
    #expect(row.warning?.contains("no longer exists") == true)
    #expect(model.hasMissingDebt(rule))
    model.edit(rule.id)
    #expect(model.editorDebtIsMissing && model.editorDebt == nil)
    #expect(model.editorValidation == "This debt no longer exists. Choose another debt.")
    await model.createDebt(named: "Hanna")
    #expect(!model.editorDebtIsMissing && model.editorValidation == nil)
    #expect(model.editorRule?.debtPersonName == "Hanna")
  }

  @Test("R-DEBT-12, C32: without a debt repository a debt cannot be created and nothing is picked")
  func noRepository() async throws {
    let (model, _) = try await model(debts: false)
    model.newRule()
    model.editor?.action = .debt
    await model.createDebt(named: "Ola")
    #expect(model.errorMessage != nil && model.editor?.debtPersonName == "")
  }
}

private enum PreviewDataID {
  static let rule = UUID(uuidString: "00000000-0000-0000-0000-00000000C320")!
}
