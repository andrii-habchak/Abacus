import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C29: marking a debt settled asks "Archive the related accounts?" (R-DEBT-5, R-DEBT-17,
/// R-DEBT-21). Synthetic debts over an in-memory database (`PreviewData` + `DebtSample`).
@MainActor
@Suite("Debts · settle prompt (C29)")
struct DebtSettlePromptTests {
  let database: any DatabaseWriter
  let debts: SQLiteDebtRepository
  let accounts: SQLiteAccountRepository
  let model: DebtsModel

  /// A debt that nets to zero in PLN: a virtual account holding +100.00 and an external bank
  /// account holding −100.00 (both opening balances, so no transactions are involved).
  var zero: (debt: Debt, virtual: Account, external: Account)

  init() async throws {
    let database = try DebtSample.database()
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    let debts = SQLiteDebtRepository(database: database)
    let accounts = SQLiteAccountRepository(database: database)
    let dependencies = DebtsDependencies(
      debts: debts, accounts: accounts, converter: { rates }, today: { PreviewData.today },
      format: ManageFixture.format)
    let debt = Debt(id: PreviewData.id(1900), personName: "Zed Settle", countsInNetWorth: true)
    try await debts.save(debt)
    var virtual = try await debts.createVirtualAccount(
      for: debt.id, currency: .PLN, name: "Zed virtual", openingBalanceMinor: 100_00)
    virtual.openingDate = PreviewData.at("2026-01-01")
    try await accounts.save(virtual)
    let external = Account(
      id: PreviewData.id(1901), name: "Zed bank", currency: .PLN, kind: .bank, openingBalanceMinor: -100_00,
      openingDate: PreviewData.at("2026-01-01"), position: 90)
    try await accounts.save(external)
    try await debts.link(external.id, to: debt.id, role: .external)
    self.database = database
    self.debts = debts
    self.accounts = accounts
    self.model = DebtsModel(dependencies: dependencies)
    self.zero = (debt, virtual, external)
    await model.load()
  }

  func archived(_ id: Account.ID) async throws -> Bool {
    try await accounts.accounts(includeArchived: true).first { $0.id == id }?.isArchived ?? false
  }

  @Test("R-DEBT-5, R-DEBT-17: Mark settled with open linked accounts asks first and changes nothing until Settle")
  func promptAppears() async throws {
    #expect(model.canSettle(zero.debt.id))
    await model.requestSettle(zero.debt.id)
    let prompt = try #require(model.settlePrompt)
    #expect(prompt.debtID == zero.debt.id && prompt.personName == "Zed Settle")
    #expect(Set(prompt.accounts.map(\.id)) == [zero.virtual.id, zero.external.id])
    #expect(model.book.debt(zero.debt.id)?.isSettled == false)
    model.cancelSettlePrompt()
    #expect(model.settlePrompt == nil)
    #expect(model.book.debt(zero.debt.id)?.isSettled == false)
    #expect(try await archived(zero.virtual.id) == false)
  }

  @Test("R-DEBT-17: virtual accounts are ticked by default, external ones are not")
  func defaults() async throws {
    await model.requestSettle(zero.debt.id)
    let prompt = try #require(model.settlePrompt)
    #expect(prompt.accounts.first { $0.id == zero.virtual.id }?.archive == true)
    #expect(prompt.accounts.first { $0.id == zero.external.id }?.archive == false)
    #expect(prompt.accounts.first { $0.id == zero.virtual.id }?.role == .virtual)
    #expect(prompt.accounts.first { $0.id == zero.virtual.id }?.balanceText.contains("100") == true)
  }

  @Test("R-DEBT-5, R-DEBT-17: Settle with the defaults archives the virtual account only; balances stay (archived as is)")
  func settleWithDefaults() async throws {
    await model.requestSettle(zero.debt.id)
    await model.confirmSettle()
    #expect(model.settlePrompt == nil)
    #expect(model.book.debt(zero.debt.id)?.isSettled == true)
    #expect(try await archived(zero.virtual.id) == true)
    #expect(try await archived(zero.external.id) == false)
    // No compensation, no forgive: the transactions and records are exactly as before, the
    // archived account keeps its own balance and its link.
    let book = try await debts.book()
    #expect(book.records(of: zero.debt.id).isEmpty)
    #expect(book.txns.allSatisfy { !$0.txn.isBalanceCorrection })
    #expect(book.debtID(ofAccount: zero.virtual.id) == zero.debt.id)
    let balances = Calc.balances(
      accounts: book.accounts(of: zero.debt.id), txns: book.txns, through: PreviewData.today,
      calendar: ManageFixture.format.calendar)
    #expect(balances[zero.virtual.id]?.minorUnits == 100_00)
    #expect(Calc.debtBalance(book, debtID: zero.debt.id, currency: .PLN).minorUnits == 0)
  }

  @Test("R-DEBT-5: the owner may tick the external account too, or untick the virtual one")
  func custom() async throws {
    await model.requestSettle(zero.debt.id)
    model.setArchiveOnSettle(zero.external.id, true)
    model.setArchiveOnSettle(zero.virtual.id, false)
    await model.confirmSettle()
    #expect(try await archived(zero.external.id) == true)
    #expect(try await archived(zero.virtual.id) == false)
    #expect(model.book.debt(zero.debt.id)?.isSettled == true)
  }

  @Test("R-DEBT-5: Cancel leaves the debt open and every account as it was")
  func cancelKeepsEverything() async throws {
    await model.requestSettle(zero.debt.id)
    model.setArchiveOnSettle(zero.external.id, true)
    model.cancelSettlePrompt()
    await model.confirmSettle()  // nothing pending: a no-op
    #expect(model.book.debt(zero.debt.id)?.isSettled == false)
    #expect(try await archived(zero.external.id) == false)
  }

  @Test("R-DEBT-5: a debt whose accounts are all archived already is settled without the prompt")
  func noOpenAccounts() async throws {
    try await accounts.setArchived(zero.virtual.id, true)
    try await accounts.setArchived(zero.external.id, true)
    await model.load()
    await model.requestSettle(zero.debt.id)
    #expect(model.settlePrompt == nil)
    #expect(model.book.debt(zero.debt.id)?.isSettled == true)
  }

  @Test("R-DEBT-5: a debt without accounts is settled without the prompt")
  func noAccounts() async throws {
    let bare = Debt(id: PreviewData.id(1902), personName: "Bare Debt")
    try await debts.save(bare)
    await model.load()
    await model.requestSettle(bare.id)
    #expect(model.settlePrompt == nil)
    #expect(model.book.debt(bare.id)?.isSettled == true)
  }

  @Test("R-DEBT-5: a debt with a balance cannot be settled, no prompt")
  func nonZeroRefused() async {
    await model.requestSettle(DebtSample.sam.id)
    #expect(model.settlePrompt == nil)
    #expect(model.book.debt(DebtSample.sam.id)?.isSettled == false)
  }

  @Test("R-DEBT-21: reopening a settled debt does not unarchive its accounts")
  func reopenKeepsArchived() async throws {
    await model.requestSettle(zero.debt.id)
    await model.confirmSettle()
    #expect(try await archived(zero.virtual.id) == true)
    await model.setSettled(zero.debt.id, false)
    #expect(model.book.debt(zero.debt.id)?.isSettled == false)
    #expect(try await archived(zero.virtual.id) == true)
  }

  @Test("R-DEBT-21: the row and widget menu entry is Mark settled; an already settled debt offers Reopen and no prompt")
  func menuActions() async throws {
    let actions = try #require(model.rowActions(for: zero.debt.id))
    #expect(actions.settledTitle == "Mark settled" && actions.canToggleSettled)
    await model.requestSettle(DebtSample.kim.id)  // settled already: nothing to ask
    #expect(model.settlePrompt == nil)
  }
}
