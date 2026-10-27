import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Testing

/// Shared setup of the management screen tests: the sample store (`PreviewData` + rules and
/// event extras) with an en_US format.
@MainActor
enum ManageFixture {
  static let format = ManageFormat(locale: Locale(identifier: "en_US"), calendar: .current)

  static func dependencies(_ store: ManagePreviewStore) -> ManageDependencies {
    .preview(store: store, format: format)
  }

  static func id(_ n: Int) -> UUID { PreviewData.id(n) }
}

@MainActor
@Suite("Manage · Accounts")
struct ManageAccountsTests {
  let store = ManagePreviewStore.sample()

  func model() async -> AccountsModel {
    let model = AccountsModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  func allTxns() async throws -> [TxnWithLines] {
    try await store.txnRepository.transactions(matching: TxnQuery())
  }

  @Test("R-MGMT-1, R-MGMT-9, R-ACC-3: groups as folders with their accounts and balances, custom order")
  func groupedWithBalances() async throws {
    let model = await model()
    #expect(
      model.rows.map(\.name) == [
        "Monobank", "Monobank Black", "PKO", "PKO Personal", "PKO USD", "PKO Credit Card", "Revolut", "Revolut EUR",
        "Cash PLN", "EUR Deposit", "Loan from friend",
      ])
    #expect(model.rows.filter(\.isGroup).map(\.name) == ["Monobank", "PKO", "Revolut"])
    #expect(model.rows.filter(\.isChild).count == 5)
    let expected = Calc.balances(accounts: PreviewData.accounts, txns: try await allTxns(), through: PreviewData.today)
    let pko = try #require(model.rows.first { $0.id == PreviewData.pkoPersonal.id })
    #expect(pko.balanceText == ManageFixture.format.money(expected[PreviewData.pkoPersonal.id]!))
    #expect(pko.detail == "Bank account · PLN")
    #expect(pko.symbol == "zł")
  }

  @Test("R-ACC-2: liabilities are flagged and negative balances marked")
  func liabilities() async throws {
    let model = await model()
    let rows = model.rows
    let card = try #require(rows.first { $0.id == PreviewData.pkoCreditCard.id })
    #expect(card.isLiability)
    #expect(card.isNegative)
    #expect(card.detail == "Credit card · PLN")
    #expect(rows.first { $0.id == PreviewData.loanFromFriend.id }?.detail == "Debt (person) · UAH")
    #expect(ManageText.assetKinds == [.cash, .bank, .card, .savings, .investment])
    #expect(ManageText.liabilityKinds == [.creditCard, .loan, .debt])
    #expect(ManageText.liabilityKinds(offeredFor: .bank) == [.creditCard, .loan])
    #expect(ManageText.liabilityKinds(offeredFor: nil) == [.creditCard, .loan])
    #expect(ManageText.liabilityKinds(offeredFor: .debt) == [.creditCard, .loan, .debt])
  }

  @Test("R-ACC-4: archived accounts are listed only with “Show archived accounts”")
  func showArchived() async {
    let model = await model()
    #expect(!model.rows.contains { $0.id == PreviewData.oldCard.id })
    model.setShowArchived(true)
    let old = model.rows.first { $0.id == PreviewData.oldCard.id }
    #expect(old?.isArchived == true)
  }

  @Test("R-ACC-4: archiving an account whose balance is not zero warns and needs confirmation")
  func archiveWarning() async throws {
    let model = await model()
    model.select(PreviewData.pkoPersonal.id)
    #expect(model.archiveTitle == "Archive…")
    await model.archiveOrUnarchive()
    let dialog = try #require(model.dialog)
    #expect(dialog.title == "Archive “PKO Personal”?")
    #expect(dialog.message.hasPrefix("Its balance is \(model.balanceText!), not zero."))
    #expect(dialog.confirmTitle == "Archive anyway")
    #expect(dialog.isDestructive)
    // Nothing changes before the confirmation.
    #expect(model.account(PreviewData.pkoPersonal.id)?.isArchived == false)
    model.cancelDialog()
    #expect(model.dialog == nil)
    #expect(model.account(PreviewData.pkoPersonal.id)?.isArchived == false)

    await model.archiveOrUnarchive()
    await model.confirmDialog()
    #expect(model.account(PreviewData.pkoPersonal.id)?.isArchived == true)
    #expect(model.showArchived)
    #expect(model.archiveTitle == "Unarchive")

    await model.archiveOrUnarchive()
    #expect(model.dialog == nil)
    #expect(model.account(PreviewData.pkoPersonal.id)?.isArchived == false)
  }

  @Test("R-ACC-4: archiving a zero balance asks without the warning")
  func archiveZero() async throws {
    let model = await model()
    model.newAccount(currency: .EUR)
    model.draft?.name = "Spare card"
    model.draft?.kind = .card
    await model.save()
    let spare = try #require(model.selectedAccount)
    #expect(spare.name == "Spare card")
    await model.archiveOrUnarchive()
    #expect(model.dialog?.confirmTitle == "Archive")
    #expect(model.dialog?.isDestructive == false)
    await model.confirmDialog()
    #expect(model.account(spare.id)?.isArchived == true)
  }

  @Test("R-ACC-5: delete is disabled for an account with transactions")
  func deleteDisabledWhenUsed() async throws {
    let model = await model()
    model.select(PreviewData.pkoPersonal.id)
    #expect(!model.canDelete)
    let count = try await allTxns().filter {
      $0.txn.accountID == PreviewData.pkoPersonal.id || $0.txn.toAccountID == PreviewData.pkoPersonal.id
    }.count
    #expect(model.deleteHint == "Has \(count) transactions — archive it instead.")
    model.requestDelete()
    #expect(model.dialog == nil)
  }

  @Test("R-ACC-5: an account without transactions can be deleted after confirming")
  func deleteUnused() async throws {
    let model = await model()
    model.select(PreviewData.eurDeposit.id)
    #expect(model.canDelete)
    #expect(model.deleteHint == "No transactions yet; it can be deleted.")
    model.requestDelete()
    #expect(model.dialog?.confirmTitle == "Delete")
    await model.confirmDialog()
    #expect(model.account(PreviewData.eurDeposit.id) == nil)
    #expect(try await store.accountRepository.accounts(includeArchived: true).count == PreviewData.accounts.count - 1)
  }

  @Test("R-ACC-1: a new account is created from the inspector with all its fields")
  func createAccount() async throws {
    let model = await model()
    model.newAccount(currency: .PLN)
    #expect(model.inspectorTitle == "New account")
    #expect(!model.isCurrencyLocked)
    model.draft?.name = "  "
    #expect(model.validationMessage == "Enter a name.")
    #expect(!model.canSave)
    model.draft?.name = "mBank"
    model.draft?.kind = .savings
    model.draft?.openingBalance = "1 250,50"
    model.draft?.groupID = PreviewData.pkoGroup.id
    model.draft?.iban = "PL00 1111"
    #expect(model.canSave)
    await model.save()
    let saved = try #require(try await store.accountRepository.accounts(includeArchived: false).first { $0.name == "mBank" })
    #expect(saved.kind == .savings)
    #expect(saved.currency == .PLN)
    #expect(saved.openingBalanceMinor == 1_250_50)
    #expect(saved.groupID == PreviewData.pkoGroup.id)
    #expect(saved.iban == "PL00 1111")
    #expect(model.selection == saved.id)
    // Last in its group (R-MGMT-9).
    let pkoRows = model.rows.drop { $0.id != PreviewData.pkoGroup.id }.dropFirst().prefix { $0.isChild }
    #expect(pkoRows.last?.name == "mBank")
    #expect(!model.isDirty)
  }

  @Test("R-ACC-1, R-ACC-3: editing the opening balance changes the balance; the currency is locked once used")
  func editAccount() async throws {
    let model = await model()
    model.select(PreviewData.pkoPersonal.id)
    #expect(model.isCurrencyLocked)
    model.select(PreviewData.eurDeposit.id)
    #expect(!model.isCurrencyLocked)
    #expect(!model.isDirty)
    model.draft?.openingBalance = "6,000.00"
    #expect(model.isDirty)
    await model.save()
    #expect(model.balanceText == "€6,000.00")
    model.draft?.openingBalance = "abc"
    #expect(model.validationMessage == "The opening balance is not a number.")
    model.revert()
    #expect(model.draft?.openingBalance == "6000.00")
  }
}

@MainActor
@Suite("Manage · Format")
struct ManageFormatTests {
  let format = ManageFixture.format

  @Test("R-CUR-2: amount fields parse to exact minor units in the common notations")
  func parseAmounts() {
    #expect(format.parseAmount("4000") == 4_000_00)
    #expect(format.parseAmount("4000.5") == 4_000_50)
    #expect(format.parseAmount("1,234.56") == 1_234_56)
    #expect(format.parseAmount("1 234,56") == 1_234_56)
    #expect(format.parseAmount("1.234,56") == 1_234_56)
    #expect(format.parseAmount("1,234") == 1_234_00)
    #expect(format.parseAmount("12,5") == 12_50)
    #expect(format.parseAmount("−8 000") == -8_000_00)
    #expect(format.parseAmount("-zł1,240.00") == -1_240_00)
    #expect(format.parseAmount("") == nil)
    #expect(format.parseAmount("abc") == nil)
    #expect(format.amountInput(4_000_00) == "4000.00")
  }

  @Test("R-EVT-1: event dates read as in the prototype")
  func dates() {
    #expect(format.dateRange(start: Day("2026-10-01"), end: Day("2026-10-19")) == "01.10 – 19.10.2026")
    #expect(format.dateRange(start: Day("2025-12-28"), end: Day("2026-01-03")) == "28.12.2025 – 03.01.2026")
    #expect(format.dateRange(start: nil, end: nil) == "No dates (ongoing)")
    #expect(format.dateRange(start: Day("2026-10-01"), end: nil) == "From 01.10.2026")
    #expect(format.money(Money(minorUnits: 48_250_00, currency: .UAH)) == "₴48,250.00")
  }
}
