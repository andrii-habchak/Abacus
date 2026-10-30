import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

@MainActor
@Suite("Debts tab and widget (C14, C19)")
struct DebtsModelTests {
  nonisolated static let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)

  static func model() throws -> (DebtsModel, any DatabaseWriter) {
    let database = try DebtSample.database()
    let dependencies = DebtsDependencies(
      debts: SQLiteDebtRepository(database: database), accounts: SQLiteAccountRepository(database: database),
      converter: { rates }, today: { PreviewData.today })
    return (DebtsModel(dependencies: dependencies), database)
  }

  @Test("R-DEBT-5: people with per-currency balances, Active/Settled filter, search")
  func peopleList() async throws {
    let (model, _) = try Self.model()
    await model.load()
    #expect(model.phase == .loaded)
    let names = model.people.map(\.name)
    #expect(names.contains("Alex Example") && names.contains("Maria Sample") && !names.contains("Kim Settled"))
    // The sample debt-kind account got its debt, a person too (R-DEBT-17).
    #expect(names.contains(PreviewData.loanFromFriend.name))
    let alex = try #require(model.people.first { $0.name == "Alex Example" })
    #expect(alex.balances.map(\.money.currency) == [.EUR, .PLN])
    #expect(alex.balances.first?.directionText == "you lent")
    #expect(alex.balances.last?.directionText == "you borrowed")
    model.search = "mar"
    #expect(model.people.map(\.name) == ["Maria Sample"])
    model.search = ""
    model.filter = .settled
    #expect(model.people.map(\.name) == ["Kim Settled"])
  }

  @Test("R-DEBT-18, R-DEBT-4: a manual record added in the form changes the balance in its currency; forgive counts as expense by default")
  func addRecord() async throws {
    let (model, database) = try Self.model()
    await model.load()
    let maria = DebtSample.maria
    func uah() -> Int64 {
      Calc.debtBalance(model.book, debtID: maria.id, currency: .UAH).minorUnits
    }
    let before = uah()
    let accountsBefore = try await SQLiteAccountRepository(database: database).balances(asOf: Day("2100-01-01")!)

    model.newRecord(debtID: maria.id)
    #expect(model.recordDraft?.kind == .forgaveThem && model.recordDraft?.currency == .UAH)
    #expect(model.recordDraft?.countsInReports == true)
    model.setRecordKind(.theyRepaid)
    #expect(model.recordDraft?.countsInReports == false)
    #expect(model.recordReportKind == .income)
    model.recordDraft?.amount = "100"
    #expect(model.recordDraftIssue == nil)
    await model.saveRecordDraft()
    #expect(model.recordDraft == nil)
    #expect(uah() == before - 100_00)
    // A manual record moves no money on my accounts.
    let accountsAfter = try await SQLiteAccountRepository(database: database).balances(asOf: Day("2100-01-01")!)
    #expect(accountsAfter == accountsBefore)

    model.newRecord(debtID: maria.id)
    model.setRecordKind(.forgaveThem)
    #expect(model.recordDraft?.countsInReports == true)
    model.recordDraft?.amount = "0"
    #expect(model.recordDraftIssue == "Enter an amount above zero.")
  }

  @Test("R-DEBT-5: only a zero balance can be marked settled; it moves to Settled")
  func settle() async throws {
    let (model, _) = try Self.model()
    await model.load()
    await model.setSettled(DebtSample.maria.id, true)
    #expect(model.book.debts.first { $0.id == DebtSample.maria.id }?.isSettled == false)
    let debt = DebtSample.sam
    let balance = Calc.debtBalance(model.book, debtID: debt.id, currency: .PLN).minorUnits
    model.newRecord(debtID: debt.id)
    model.setRecordKind(.forgaveThem)
    model.recordDraft?.amount = ManageFormat().amountInput(balance)
    await model.saveRecordDraft()
    await model.setSettled(debt.id, true)
    #expect(model.book.debts.first { $0.id == debt.id }?.isSettled == true)
    model.filter = .settled
    #expect(model.people.contains { $0.name == debt.personName })
  }

  @Test("R-DEBT-6, R-DEBT-7: the dashboard's widget and net-worth debts line")
  func dashboard() async throws {
    let database = try DebtSample.database()
    let calendar = Calendar.current
    let dependencies = DashboardDependencies(
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      txns: SQLiteTxnRepository(database: database, calendar: calendar), budget: SQLiteBudgetRepository(database: database),
      settings: SQLiteSettingsRepository(database: database), rates: { DashboardRates(converter: Self.rates) },
      today: { PreviewData.today }, debts: SQLiteDebtRepository(database: database, calendar: calendar))
    let model = DashboardModel(dependencies: dependencies, displayCurrency: .UAH)
    await model.load()
    let widget = try #require(model.debts)
    #expect(!widget.isEmpty)
    #expect(!widget.people.contains { $0.name == "Kim Settled" })
    #expect(widget.owedToMe.minorUnits > 0 && widget.iOwe.minorUnits > 0)
    #expect(model.netWorth?.debtsText != nil)

    // The forgiven debt (Count as expense, a manual record) is in October's expenses under Debts.
    let debtsCategory = try await SQLiteCategoryRepository(database: database).categories(kind: .expense, includeArchived: false)
      .first { $0.name == "Debts" }
    let slice = model.expenses?.slices.first { $0.categoryID == debtsCategory?.id }
    #expect(slice != nil)
  }
}
