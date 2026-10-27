import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

/// S1 (D54): the model-side invariants behind the 1.2.0 crashes and hangs.
@MainActor
@Suite("Stability (S1)")
struct StabilityTests {
  @Test("Saving a debt record closes its form once and saves one record, even when Save is pressed twice")
  func debtRecordSavedOnce() async throws {
    let model = DebtsModel(dependencies: .preview())
    await model.load()
    let debt = try #require(model.selectedDetails.first?.debt)
    let before = model.book.entries(of: debt.id).count
    model.newRecord(debtID: debt.id, kind: .forgaveThem)
    model.recordDraft?.amount = "5"
    async let first: Void = model.saveRecordDraft()
    async let second: Void = model.saveRecordDraft()
    _ = await (first, second)
    #expect(model.recordDraft == nil)
    #expect(model.book.entries(of: debt.id).count == before + 1)
    #expect(!model.isSaving)
  }

  @Test("A form cancelled (draft set to nil) leaves every form-derived value safe to read")
  func draftClearedWhileShown() async throws {
    let model = DebtsModel(dependencies: .preview())
    await model.load()
    let debt = try #require(model.selectedDetails.first?.debt)
    model.newRecord(debtID: debt.id)
    model.recordDraft = nil
    #expect(model.recordDraftIssue == nil)
    #expect(model.recordReportKind == nil)
    #expect(model.recordAccount == nil)
    #expect(!model.recordNeedsAccountAmount)
    model.editDebt(debt.id)
    model.debtDraft = nil
    #expect(model.debtDraftIssue == nil)
    #expect(!model.debtCurrencyLocked)
    await model.saveRecordDraft()
    await model.saveDebtDraft()
    #expect(model.errorMessage == nil)
  }

  @Test("Reloading a screen twice gives the same rows (no drift, no duplicates)")
  func reloadIsIdempotent() async throws {
    let database = try LargeSampleData.database(
      size: .init(transactions: 400, accounts: 20, groups: 4, debts: 4), today: Day(year: 2026, month: 10, day: 21))
    let session = AppSession.live(database: database, source: StubSource(rates: []))
    await session.start()
    await session.accounts.load()
    await session.categories.load()
    await session.debts.load()
    let accounts = session.accounts.rows
    let categories = session.categories.rows
    let people = session.debts.people
    await session.reloadManageScreens(all: true)
    await session.reloadManageScreens()
    #expect(session.accounts.rows == accounts)
    #expect(session.categories.rows == categories)
    #expect(session.debts.people == people)
    #expect(Set(accounts.map(\.id)).count == accounts.count)
    session.stop()
  }

  @Test("A drop re-reads the order (cached drop answers refreshed), balances and counts stay")
  func dropRefreshesOrderOnly() async throws {
    let model = AccountsModel(dependencies: .preview())
    await model.load()
    let cash = PreviewData.cashPLN.id
    let group = PreviewData.monobankGroup.id
    let balances = model.balances
    let counts = model.txnCounts
    #expect(model.canDrop(cash, on: group, position: .onto))
    await model.drop(cash, on: group, position: .onto)
    #expect(model.account(cash)?.groupID == group)
    #expect(!model.canDrop(cash, on: group, position: .onto))
    #expect(model.balances == balances)
    #expect(model.txnCounts == counts)

    let categories = CategoriesModel(dependencies: .preview())
    await categories.load()
    let rows = categories.rows.filter { !$0.isChild }
    try #require(rows.count >= 3)
    #expect(categories.canDrop(rows[2].id, on: rows[0].id, position: .before))
    await categories.drop(rows[2].id, on: rows[0].id, position: .before)
    #expect(categories.rows.first?.id == rows[2].id)
  }

  @Test("Days and months order by their numbers exactly as their strings do")
  func dayOrderMatchesStrings() {
    let days = [
      Day(year: 2024, month: 2, day: 29), Day(year: 2024, month: 10, day: 1), Day(year: 2024, month: 9, day: 30),
      Day(year: 2026, month: 1, day: 1), Day(year: 2025, month: 12, day: 31), Day(year: 2024, month: 10, day: 10),
    ]
    for a in days {
      for b in days {
        #expect((a < b) == (a.string < b.string))
        #expect((a.yearMonth < b.yearMonth) == (a.yearMonth.string < b.yearMonth.string))
      }
    }
  }
}
