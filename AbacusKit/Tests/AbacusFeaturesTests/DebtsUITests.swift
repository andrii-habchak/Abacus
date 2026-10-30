import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C20 on the C19 core (R-DEBT-21, D61): the display sign, the edit dialog with linked accounts,
/// hints, menu actions and the dashboard widget. Synthetic data only (`DebtSample`, `PreviewData`).
@MainActor
@Suite("Debts UI (C20, R-DEBT-21)")
struct DebtsUITests {
  nonisolated static let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)

  static func loadedModel(_ currency: Currency = .UAH) async throws -> (DebtsModel, any DatabaseWriter) {
    let database = try DebtSample.database()
    let dependencies = DebtsDependencies(
      debts: SQLiteDebtRepository(database: database), accounts: SQLiteAccountRepository(database: database),
      converter: { rates }, today: { PreviewData.today })
    let model = DebtsModel(dependencies: dependencies)
    model.displayCurrency = currency
    await model.load()
    return (model, database)
  }

  static func select(_ name: String, in model: DebtsModel) throws {
    model.selectedPerson = try #require(model.people.first { $0.name == name }).id
  }

  // MARK: Sign (D61)

  @Test("R-DEBT-21: the sign helper flips the display only — they owe me is negative/lent, I owe is positive/borrowed")
  func signHelper() {
    let format = ManageFormat(locale: Locale(identifier: "en_US"))
    let lent = Money(minorUnits: 260_00, currency: .EUR)
    let borrowed = Money(minorUnits: -50_00, currency: .EUR)
    #expect(DebtSign.tone(lent) == .lent && DebtSign.tone(borrowed) == .borrowed)
    #expect(DebtSign.tone(.zero(.EUR)) == .settled)
    #expect(DebtSign.label(stored: 1) == "you lent" && DebtSign.label(stored: -1) == "you borrowed")
    #expect(DebtSign.label(stored: 0) == "settled up")
    #expect(DebtSign.text(stored: lent, magnitude: format.money) == "−€260.00")
    #expect(DebtSign.text(stored: borrowed, magnitude: format.money) == "+€50.00")
    #expect(DebtSign.text(stored: .zero(.EUR), magnitude: format.money) == "€0.00")
    #expect(DebtSign.display(lent).minorUnits == -260_00 && DebtSign.display(borrowed).minorUnits == 50_00)
    #expect(DebtSign.stored(display: DebtSign.display(stored: 123)) == 123)
    #expect(DebtSign.lentTotalText(lent, magnitude: format.money) == "−€260.00")
    #expect(DebtSign.borrowedTotalText(.init(minorUnits: 50_00, currency: .EUR), magnitude: format.money) == "+€50.00")
    #expect(DebtSign.lentTotalText(.zero(.EUR), magnitude: format.money) == "€0.00")
  }

  @Test("R-DEBT-21: list rows, header totals, blocks and the ≈ total show the display sign; stored balances are untouched")
  func signInTheTab() async throws {
    let (model, _) = try await Self.loadedModel()
    let alex = try #require(model.people.first { $0.name == "Alex Example" })
    // Alex owes me €310 (stored +) and I owe zł250 (stored −).
    #expect(alex.balances[0].money.minorUnits == 310_00 && alex.balances[0].amountText.hasPrefix("−"))
    #expect(alex.balances[0].directionText == "you lent" && alex.balances[0].tone == .lent)
    #expect(alex.balances[1].money.minorUnits == -250_00 && alex.balances[1].amountText.hasPrefix("+"))
    #expect(alex.balances[1].directionText == "you borrowed")
    #expect(alex.isApproximate)
    #expect(model.lentTotalText.hasPrefix("−") && model.borrowedTotalText.hasPrefix("+"))

    try Self.select("Alex Example", in: model)
    let blocks = model.selectedDetails
    #expect(blocks[0].balance.amountText.hasPrefix("−") && blocks[1].balance.amountText.hasPrefix("+"))
    let total = try #require(model.selectedTotal)
    #expect(total.caption == "≈ total in UAH" && total.isApproximate)

    // A forgiven part lowers what they owe me: shown positive; stored the other way round.
    try Self.select("Maria Sample", in: model)
    let record = try #require(model.selectedDetails.flatMap(\.records).first)
    #expect(record.amountText.hasPrefix("+") && !record.increasesBalance)
    #expect(Calc.debtBalance(model.book, debtID: DebtSample.maria.id, currency: .UAH).minorUnits == 3_000_00)
  }

  @Test("R-DEBT-21: the dashboard widget shows 'You lent' negative and 'You borrowed' positive, with each person's debt id")
  func widgetSign() async throws {
    let (model, _) = try await Self.loadedModel()
    let format = DashboardFormat(locale: Locale(identifier: "en_US"))
    let widget = DashboardDebts.make(book: model.book, currency: .UAH, converter: Self.rates, format: format)
    #expect(widget.totalText != nil)
    let alex = try #require(widget.people.first { $0.name == "Alex Example" })
    #expect(alex.debtID == DebtSample.alex.id)
    #expect(alex.balances.map(\.directionText) == ["you lent", "you borrowed"])
    #expect(alex.balances[0].amountText.hasPrefix("−") && alex.balances[1].amountText.hasPrefix("+"))
    #expect(alex.balances[0].owesMe && !alex.balances[1].owesMe)
    #expect(!widget.people.contains { $0.name == "Kim Settled" })
  }

  // MARK: One total (C25)

  @Test("R-DEBT-21: the widget header is ONE total in the display currency, the sum of the people, signed by D61")
  func widgetOneTotal() async throws {
    let (model, _) = try await Self.loadedModel()
    let format = DashboardFormat(locale: Locale(identifier: "en_US"))
    let widget = DashboardDebts.make(book: model.book, currency: .UAH, converter: Self.rates, format: format)
    let sum = widget.people.compactMap { $0.total?.minorUnits }.reduce(0, +)
    #expect(widget.total == Money(minorUnits: sum, currency: .UAH))
    #expect(widget.total?.minorUnits == widget.owedToMe.minorUnits - widget.iOwe.minorUnits)
    let expected = DebtSign.text(stored: Money(minorUnits: sum, currency: .UAH), magnitude: format.money)
    #expect(widget.totalText == expected && widget.isApproximate)
    #expect(widget.totalOwesMe == (sum > 0))
    // No rate for a currency: the total falls back to nil ("No rate"), never a partial sum.
    let none = DashboardDebts.make(book: model.book, currency: .UAH, converter: NoRates(), format: format)
    #expect(none.total == nil && none.totalText == nil)
  }

  @Test("R-DEBT-21: a row shows ONE total in the display currency; per-currency amounts only as a label-free caption for several currencies")
  func rowTotalAndCaption() async throws {
    let (model, _) = try await Self.loadedModel(.UAH)
    let format = DashboardFormat(locale: Locale(identifier: "en_US"))
    let widget = DashboardDebts.make(book: model.book, currency: .UAH, converter: Self.rates, format: format)
    let alex = try #require(model.people.first { $0.name == "Alex Example" })
    let widgetAlex = try #require(widget.people.first { $0.name == "Alex Example" })
    // Alex: +€310 and −zł250 → one total, the same on the list row and on the widget.
    #expect(alex.total?.money == widgetAlex.total && alex.total?.money.currency == .UAH)
    let secondary = try #require(alex.secondaryText)
    #expect(secondary.contains("−") && secondary.contains("+") && secondary.contains(" · "))
    #expect(!secondary.contains("lent") && !secondary.contains("borrowed"))
    #expect(widgetAlex.secondaryText != nil && !(widgetAlex.secondaryText ?? "").contains("lent"))
    // One currency: no caption, even when it is not the display currency.
    let maria = try #require(model.people.first { $0.name == "Maria Sample" })
    #expect(maria.secondaryText == nil)
    model.displayCurrency = .EUR
    let mariaEUR = try #require(model.people.first { $0.name == "Maria Sample" })
    #expect(mariaEUR.secondaryText == nil && mariaEUR.total?.money.currency == .EUR && mariaEUR.isApproximate)
    #expect(DebtSign.caption([Money(minorUnits: 5_00, currency: .EUR)], magnitude: { "\($0.minorUnits)" }) == nil)
  }

  @Test("R-DEBT-21: the Edit debt dialog lists the linked accounts and every free account; accounts of another debt stay disabled")
  func dialogAccountLists() async throws {
    let (model, _) = try await Self.loadedModel()
    model.editDebt(DebtSample.maria.id)
    let linked = model.linkedAccountRows
    #expect(Set(linked.map(\.id)) == [DebtSample.mariaUAH.id, DebtSample.mariaBank.id])
    #expect(linked.allSatisfy { $0.roleTitle == "external" || $0.roleTitle == "virtual" })
    #expect(linked.first { $0.id == DebtSample.mariaUAH.id }?.currency == .UAH)
    #expect(model.debtDraft?.openings[DebtSample.mariaUAH.id] != nil)

    // The picker holds every non-archived account not yet linked: nothing is capped or dropped.
    let addable = model.addableAccountChoices()
    let expected = model.accounts.filter { !$0.isArchived && !linked.map(\.id).contains($0.id) }
    #expect(Set(addable.map(\.id)) == Set(expected.map(\.id)))
    #expect(!addable.contains { linked.map(\.id).contains($0.id) })
    let elsewhere = addable.filter(\.isDisabled)
    #expect(elsewhere.allSatisfy { $0.disabledReason?.hasPrefix("In ") == true })
    #expect(elsewhere.first { $0.id == DebtSample.samPLN.id }?.disabledReason == "In Sam Placeholder")
    #expect(model.addableAccountChoices(search: "zzz-nothing").isEmpty)

    // Unlinking moves an account from "Linked" to "Add accounts"; the sheet's data stay in the draft.
    model.toggleAccount(DebtSample.mariaBank.id)
    #expect(!model.linkedAccountRows.contains { $0.id == DebtSample.mariaBank.id })
    #expect(model.addableAccountChoices().contains { $0.id == DebtSample.mariaBank.id })
  }

  // MARK: Edit, rename, duplicates

  @Test("R-DEBT-21: Edit debt fills the dialog (linked accounts, openings); rename keeps the links; a duplicate name is refused with a clear message")
  func editAndRename() async throws {
    let (model, _) = try await Self.loadedModel()
    model.editDebt(DebtSample.maria.id)
    let draft = try #require(model.debtDraft)
    #expect(draft.accountIDs == [DebtSample.mariaUAH.id, DebtSample.mariaBank.id])
    #expect(draft.countsInNetWorth)

    model.debtDraft?.personName = "alex EXAMPLE "
    let issue = try #require(model.debtDraftIssue)
    #expect(issue.contains("Alex Example") && issue.contains("already"))
    model.debtDraft?.personName = ""
    #expect(model.debtDraftIssue == "Enter the person's name.")

    model.debtDraft?.personName = "Maria Renamed"
    model.debtDraft?.note = "Paid in parts"
    model.debtDraft?.countsInNetWorth = false
    #expect(model.debtDraftIssue == nil)
    await model.saveDebtDraft()
    #expect(model.debtDraft == nil)
    let saved = try #require(model.book.debt(DebtSample.maria.id))
    #expect(saved.personName == "Maria Renamed" && saved.note == "Paid in parts" && !saved.countsInNetWorth)
    #expect(Set(model.book.links(of: saved.id).map(\.accountID)) == [DebtSample.mariaUAH.id, DebtSample.mariaBank.id])
    #expect(model.selectedPersonName == "Maria Renamed")
    // The balance did not move with the name.
    #expect(Calc.debtBalance(model.book, debtID: saved.id, currency: .UAH).minorUnits == 3_000_00)
  }

  @Test("R-DEBT-21: a new debt does not count in net worth by default")
  func newDebtDefaults() async throws {
    let (model, _) = try await Self.loadedModel()
    model.newDebt()
    #expect(model.debtDraft?.countsInNetWorth == false && model.debtDraft?.accountIDs.isEmpty == true)
    model.debtDraft?.personName = "Nora New"
    await model.saveDebtDraft()
    let debt = try #require(model.book.debts.first { $0.personName == "Nora New" })
    #expect(!debt.countsInNetWorth)
  }

  // MARK: Linking

  @Test("R-DEBT-21, R-DEBT-17: the account picker searches, disables accounts of another debt with that debt's name, and refuses them")
  func accountChoices() async throws {
    let (model, _) = try await Self.loadedModel()
    model.editDebt(DebtSample.sam.id)
    let all = model.accountChoices()
    let maria = try #require(all.first { $0.id == DebtSample.mariaBank.id })
    #expect(maria.isDisabled && maria.disabledReason == "In Maria Sample")
    let samAccount = try #require(all.first { $0.id == DebtSample.samPLN.id })
    #expect(samAccount.isSelected && !samAccount.isDisabled)
    #expect(model.accountChoices(search: "maria BANK").map(\.id) == [DebtSample.mariaBank.id])
    #expect(model.accountChoices(search: "zzz-nothing").isEmpty)

    model.toggleAccount(DebtSample.mariaBank.id)
    #expect(model.debtDraft?.accountIDs == [DebtSample.samPLN.id])
  }

  @Test("R-DEBT-21, R-DEBT-18: link an external account with an opening balance, then unlink it; the account and its transactions stay")
  func linkAndUnlink() async throws {
    let (model, database) = try await Self.loadedModel()
    let bank = Account(
      id: PreviewData.id(1800), name: "Sam bank", currency: .PLN, kind: .bank, openingDate: PreviewData.at("2026-01-01"), position: 90)
    try await SQLiteAccountRepository(database: database).save(bank)
    await model.load()
    let before = Calc.debtBalance(model.book, debtID: DebtSample.sam.id, currency: .PLN).minorUnits
    #expect(before == 140_00)

    model.editDebt(DebtSample.sam.id)
    model.toggleAccount(bank.id)
    // The form uses the display sign: +20 = I owe 20 (stored −20).
    model.debtDraft?.openings[bank.id] = "20"
    await model.saveDebtDraft()
    #expect(model.errorMessage == nil)
    let link = try #require(model.book.links(of: DebtSample.sam.id).first { $0.accountID == bank.id })
    #expect(link.role == .external)
    #expect(Calc.debtBalance(model.book, debtID: DebtSample.sam.id, currency: .PLN).minorUnits == 120_00)
    #expect(model.accounts.first { $0.id == bank.id }?.openingBalanceMinor == -20_00)
    let row = try #require(model.selectedBreakdown.first { $0.id == bank.id })
    #expect(row.roleTitle == "external" && row.currency == .PLN)
    #expect(row.openingText.hasPrefix("+") && row.balance.amountText.hasPrefix("+"))

    model.editDebt(DebtSample.sam.id)
    model.toggleAccount(bank.id)
    await model.saveDebtDraft()
    #expect(model.book.links(of: DebtSample.sam.id).map(\.accountID) == [DebtSample.samPLN.id])
    #expect(model.accounts.contains { $0.id == bank.id })
    #expect(Calc.debtBalance(model.book, debtID: DebtSample.sam.id, currency: .PLN).minorUnits == 140_00)
  }

  @Test("R-DEBT-21, R-DEBT-17: 'Create account' makes a virtual account in the chosen currency with an opening balance")
  func createVirtualAccount() async throws {
    let (model, _) = try await Self.loadedModel()
    model.editDebt(DebtSample.sam.id)
    model.addNewAccount(currency: .USD)
    let id = try #require(model.debtDraft?.newAccounts.first?.id)
    model.debtDraft?.newAccounts[0].name = "Sam dollars"
    model.debtDraft?.newAccounts[0].opening = "abc"
    #expect(model.debtDraftIssue?.contains("not a number") == true)
    model.debtDraft?.newAccounts[0].opening = "-100"  // display: I lent 100
    #expect(model.debtDraftIssue == nil)
    await model.saveDebtDraft()
    #expect(model.debtDraft == nil)
    let account = try #require(model.accounts.first { $0.name == "Sam dollars" })
    #expect(account.kind == .debt && account.currency == .USD && account.openingBalanceMinor == 100_00)
    let link = try #require(model.book.links(of: DebtSample.sam.id).first { $0.accountID == account.id })
    #expect(link.role == .virtual)
    #expect(Calc.debtBalance(model.book, debtID: DebtSample.sam.id, currency: .USD).minorUnits == 100_00)
    _ = id
  }

  // MARK: Hints

  @Test("R-DEBT-21: an idle linked account and a possible duplicate show as non-blocking notices of the detail")
  func hints() async throws {
    let (model, database) = try await Self.loadedModel()
    try Self.select("Maria Sample", in: model)
    // Maria's external account has no transaction at all: idle.
    let idle = model.selectedNotices.filter { $0.kind == .idle }
    #expect(idle.count == 1 && idle[0].text.contains("Maria bank") && idle[0].text.contains("never had one"))
    #expect(model.selectedNotices.allSatisfy { $0.kind != .duplicate })

    // The same payment entered on the virtual account and imported on the external one.
    let mono = PreviewData.monobank
    try await database.write { db in
      try db.seed {
        Txn(
          id: PreviewData.id(1810), type: .transfer, occurredAt: PreviewData.at("2026-10-15"), accountID: mono.id,
          amountMinor: 700_00, toAccountID: DebtSample.mariaUAH.id, payee: "To Maria", createdAt: PreviewData.at("2026-10-15"))
        Txn(
          id: PreviewData.id(1811), type: .transfer, occurredAt: PreviewData.at("2026-10-16"), accountID: mono.id,
          amountMinor: 700_00, toAccountID: DebtSample.mariaBank.id, payee: "To Maria", createdAt: PreviewData.at("2026-10-16"))
      }
    }
    await model.load()
    let duplicate = try #require(model.selectedNotices.first { $0.kind == .duplicate })
    #expect(duplicate.text.contains("Maria bank") && duplicate.txnIDs.count == 2)
    // The bank account now has a transaction: no idle notice for it any more.
    #expect(model.selectedNotices.allSatisfy { $0.kind != .idle })
    // Hints never change the balance.
    #expect(Calc.debtBalance(model.book, debtID: DebtSample.maria.id, currency: .UAH).minorUnits == 3_000_00 + 1_400_00)

    // Another person's notices stay out of this detail.
    try Self.select("Alex Example", in: model)
    #expect(model.selectedNotices.allSatisfy { !$0.text.contains("Maria bank") })
  }

  @Test("R-DEBT-21: the breakdown lists each linked account with role, currency, balance and opening balance")
  func breakdown() async throws {
    let (model, _) = try await Self.loadedModel()
    try Self.select("Alex Example", in: model)
    let rows = model.selectedBreakdown
    #expect(Set(rows.map(\.id)) == [DebtSample.alexEUR.id, DebtSample.alexPLN.id])
    #expect(rows.allSatisfy { $0.role == .virtual && $0.openingText == "—" })
    let eur = try #require(rows.first { $0.id == DebtSample.alexEUR.id })
    #expect(eur.currency == .EUR && eur.balance.money.minorUnits == 310_00 && eur.balance.amountText.hasPrefix("−"))
    #expect(eur.transactionsText == "4 transactions")
    try Self.select("Maria Sample", in: model)
    #expect(Set(model.selectedBreakdown.map(\.roleTitle)) == ["virtual", "external"])
  }

  // MARK: Menu actions

  @Test("R-DEBT-21: the right-click menu — Show transactions hands the debt over; Mark settled needs a zero balance; Reopen")
  func menuActions() async throws {
    let (model, _) = try await Self.loadedModel()
    var shown: [Debt.ID] = []
    model.onShowTransactions = { shown.append($0) }
    model.showTransactions(DebtSample.alex.id)
    #expect(shown == [DebtSample.alex.id])

    let open = try #require(model.rowActions(for: DebtSample.maria.id))
    #expect(open.settledTitle == "Mark settled" && !open.canToggleSettled && !open.isSettled)
    let settled = try #require(model.rowActions(for: DebtSample.kim.id))
    #expect(settled.settledTitle == "Reopen" && settled.canToggleSettled && settled.isSettled)

    await model.setSettled(DebtSample.kim.id, false)
    #expect(model.book.debt(DebtSample.kim.id)?.isSettled == false)
    let kim = try #require(model.rowActions(for: DebtSample.kim.id))
    #expect(kim.settledTitle == "Mark settled" && kim.canToggleSettled)
    #expect(model.rowActions(for: UUID()) == nil)
  }

  @Test("R-DEBT-21: Delete removes the debt; its accounts and their transactions stay")
  func deleteKeepsAccounts() async throws {
    let (model, _) = try await Self.loadedModel()
    let txnsBefore = model.book.txns.count
    #expect(txnsBefore > 0)
    await model.deleteDebt(DebtSample.sam.id)
    #expect(model.book.debt(DebtSample.sam.id) == nil)
    #expect(model.accounts.contains { $0.id == DebtSample.samPLN.id })
    #expect(model.book.links(of: DebtSample.sam.id).isEmpty)
  }

  @Test("R-DEBT-21: widget actions work before the Debts tab was ever opened (edit and settle load the model first)")
  func widgetActionsOnUnloadedModel() async throws {
    let database = try DebtSample.database()
    let dependencies = DebtsDependencies(
      debts: SQLiteDebtRepository(database: database), accounts: SQLiteAccountRepository(database: database),
      converter: { Self.rates }, today: { PreviewData.today })
    let model = DebtsModel(dependencies: dependencies)
    #expect(model.phase == .idle)
    await model.edit(debtID: DebtSample.alex.id)
    #expect(model.phase == .loaded)
    #expect(model.debtDraft?.id == DebtSample.alex.id && model.debtDraft?.personName == "Alex Example")
    #expect(model.selectedPerson == DebtSample.alex.personKey)

    let fresh = DebtsModel(dependencies: dependencies)
    await fresh.setSettled(DebtSample.kim.id, false)
    #expect(fresh.book.debt(DebtSample.kim.id)?.isSettled == false)
  }

  @Test("R-DEBT-21: the display-currency switch keeps working with no currency on the debt (converted total follows)")
  func currencySwitch() async throws {
    let (model, _) = try await Self.loadedModel(.UAH)
    try Self.select("Alex Example", in: model)
    let inUAH = model.selectedTotal?.balance?.money
    model.displayCurrency = .EUR
    let inEUR = model.selectedTotal?.balance?.money
    #expect(inUAH?.currency == .UAH && inEUR?.currency == .EUR && model.selectedTotal?.caption == "≈ total in EUR")
    #expect(model.summary.currency == .EUR)
  }
}
