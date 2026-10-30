import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C17 screens on the C19 core: the shared debt sheet, the import wizard's "Debt…", "Convert to
/// debt record…" in the transaction list and the rule editor's debt action (R-DEBT-10…12,
/// R-DEBT-19): a payment ends as a transfer to the person's virtual account. Synthetic data only.
@MainActor
@Suite("Debt linking screens (C17, C19)")
struct DebtLinkFeatureTests {
  static let calendar = ImportHarness.calendar
  static let account = Account(
    id: PreviewData.id(9101), name: "Bank PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")

  /// One debt per person; each (person, currency, balance) is a virtual account of that person
  /// opened with the balance (positive = they owe me).
  static func book(_ balances: [(String, Currency, Int64)]) -> DebtBook {
    var book = DebtBook()
    for (person, currency, balance) in balances {
      let debt: Debt
      if let known = book.debt(person: person) {
        debt = known
      } else {
        debt = Debt(personName: person)
        book.debts.append(debt)
      }
      let account = Account(
        name: "\(person) (\(currency.rawValue))", currency: currency, kind: .debt, openingBalanceMinor: balance,
        openingDate: Date(timeIntervalSince1970: 1_700_000_000))
      book.accounts.append(account)
      book.links.append(DebtAccountLink(accountID: account.id, debtID: debt.id, role: .virtual))
    }
    return book
  }

  // MARK: Shared sheet

  @Test("R-DEBT-10/11, R-DEBT-16, R-DEBT-19: the sheet completes names, offers the person's accounts (virtual first) and defaults to the virtual account in the row's currency")
  func draftDefaults() {
    var book = Self.book([("Ann", .PLN, 100_00), ("Bob", .EUR, -20_00)])
    let external = Account(name: "Ann Revolut", currency: .PLN, kind: .bank, openingDate: Date(timeIntervalSince1970: 1_700_000_000))
    book.accounts.append(external)
    book.links.append(DebtAccountLink(accountID: external.id, debtID: book.debts[0].id, role: .external))
    var draft = DebtLinkDraft(
      title: "t", subtitle: "s", inflow: true, accountCurrency: .PLN, accountAmountMinor: 40_00, book: book,
      convertedAmounts: [.EUR: 9_30], format: ManageFormat(locale: Locale(identifier: "en_US")))
    #expect(draft.validation == "Enter the person's name.")
    #expect(draft.personOptions == ["Ann", "Bob"])
    draft.personName = "an"
    #expect(draft.personOptions == ["Ann"])
    draft.personName = "ann "
    #expect(draft.debt?.id == book.debts[0].id && !draft.createsDebt)
    #expect(draft.account == .existing(book.accounts[0].id))
    #expect(draft.accountChoices.map(\.label) == ["Ann (PLN) · virtual", "Ann Revolut (PLN) · their account", "New virtual account"])
    #expect(!draft.needsAmount && !draft.choosesCurrency)
    #expect(draft.link == DebtLink(personName: "ann", debtID: book.debts[0].id, accountID: book.accounts[0].id, currency: .PLN))
    // The person's own account can be picked instead.
    draft.account = .existing(external.id)
    #expect(draft.link?.accountID == external.id)

    // Bob has only a EUR account: a new virtual account in the row's currency is the default.
    draft.personName = "Bob"
    #expect(draft.account == .newVirtual && draft.choosesCurrency)
    #expect(draft.personCurrency == .PLN && !draft.needsAmount)
    // Another currency for the new account pre-fills the amount at the day's rate.
    draft.newAccountCurrency = .EUR
    #expect(draft.needsAmount && draft.amountText == "9.30")
    #expect(draft.link?.amountMinor == 9_30 && draft.link?.currency == .EUR)
    draft.amountText = ""
    #expect(draft.validation == "Enter the amount in EUR.")
    // A new person: a new debt and a new virtual account.
    draft.personName = "Cleo"
    #expect(draft.createsDebt && draft.debt == nil && draft.account == .newVirtual)
    #expect(draft.accountChoices.map(\.label) == ["New virtual account"])
    #expect(draft.link?.debtID == nil && draft.link?.currency == .PLN)
  }

  // MARK: Import wizard

  @Test("R-DEBT-10, R-DEBT-19: Debt… on a new row and on a Needs review row; the commit makes one transfer each")
  func wizardDebtSheet() async throws {
    let harness = try await ImportHarness.empty(accounts: [Self.account])
    await harness.model.open(data: try ImportHarness.fixture("pko", "all-types"), fileName: "pko.csv")
    if harness.model.needsTargetAccount { await harness.model.chooseTargetAccount(Self.account.id) }
    let model = harness.model
    let rent = try #require(model.rowItems.first { $0.payee.contains("ANNA NOWAK") })
    #expect(rent.canRecordDebt)
    await model.openDebt(forRow: rent.id)
    var draft = try #require(model.debtDraft)
    #expect(draft.inflow == false)
    draft.personName = "Anna"
    #expect(draft.account == .newVirtual)
    model.saveDebt(draft)
    #expect(model.debtDraft == nil)
    let recorded = try #require(model.rowItems.first { $0.id == rent.id })
    #expect(recorded.statusLabel == "Transfer to debt")
    #expect(recorded.debt?.hasPrefix("Transfer to debt · Anna") == true)
    #expect(recorded.category == .none)

    let fee = try #require(model.reviewItems.first { $0.title == "Unknown operation type" })
    await model.openDebt(forRow: fee.id)
    var feeDraft = try #require(model.debtDraft)
    feeDraft.personName = "Anna"
    model.saveDebt(feeDraft)
    let decided = try #require(model.reviewItems.first { $0.id == fee.id })
    #expect(decided.selected == .debt)
    #expect(decided.debtLabel?.hasPrefix("Transfer to debt · Anna") == true)

    model.acceptSuggestions()
    await model.commit()
    #expect(model.step == .done)
    #expect(model.doneLines.contains("2 transferred to debt accounts"))
    let book = try await SQLiteDebtRepository(database: harness.database, calendar: Self.calendar).book()
    #expect(book.debts.count == 1 && book.links.count == 1 && book.records.isEmpty)
    let debtAccount = try #require(book.links.first?.accountID)
    let transfers = try await harness.txns().filter {
      $0.txn.type == .transfer && ($0.txn.toAccountID == debtAccount || $0.txn.accountID == debtAccount)
    }
    #expect(transfers.count == 2)
    #expect(book.balance(of: book.debts[0].id, currency: .PLN, calendar: Self.calendar) == 1_500_00 + 5_00)
    // One person, one virtual account, whichever row came first.
    #expect(book.accounts.filter { $0.kind == .debt }.count == 1)
  }

  @Test("R-DEBT-10: Not a debt puts the row back to a category pick")
  func wizardRemoveDebt() async throws {
    let harness = try await ImportHarness.empty(accounts: [Self.account])
    await harness.model.open(data: try ImportHarness.fixture("pko", "all-types"), fileName: "pko.csv")
    if harness.model.needsTargetAccount { await harness.model.chooseTargetAccount(Self.account.id) }
    let model = harness.model
    let rent = try #require(model.rowItems.first { $0.payee.contains("ANNA NOWAK") })
    await model.openDebt(forRow: rent.id)
    var draft = try #require(model.debtDraft)
    draft.personName = "Anna"
    model.saveDebt(draft)
    model.removeDebt(forRow: rent.id)
    let back = try #require(model.rowItems.first { $0.id == rent.id })
    #expect(back.debt == nil)
    if case .picker = back.category {} else { Issue.record("expected a category picker") }
  }

  // MARK: Transaction list

  @Test("R-DEBT-11, R-DEBT-19: Transfer to debt account in the list keeps the transaction and makes it a transfer to the person's account; Undo turns it back")
  func listConvert() async throws {
    let database = try AbacusDatabase.open(at: nil)
    try await SQLiteAccountRepository(database: database, calendar: Self.calendar).save(Self.account)
    let txns = SQLiteTxnRepository(database: database, calendar: Self.calendar)
    let txn = Txn(
      type: .expense, occurredAt: Date(timeIntervalSince1970: 1_768_478_400), accountID: Self.account.id,
      amountMinor: 60_00, payee: "Dinner for Ann", note: "split later")
    try await txns.save(txn, lines: [])
    let model = TransactionsViewModel(
      transactions: txns, accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      converter: RateTable(), filters: TransactionFilters(dateRange: .custom(from: Day("2026-01-01")!, to: Day("2026-01-31")!)), calendar: Self.calendar,
      today: { Day("2026-02-01")! }, debts: SQLiteDebtRepository(database: database, calendar: Self.calendar))
    var changed = 0
    model.onDataChange = { changed += 1 }
    await model.load()
    #expect(model.rows.count == 1, "\(model.errorMessage ?? "")")
    #expect(model.canConvertToDebt(txn.id))
    await model.beginConvertToDebt(txn.id)
    var draft = try #require(model.debtDraft)
    draft.personName = "Ann"
    await model.saveConvertToDebt(draft)
    #expect(changed == 1)
    #expect(model.debtDraft == nil)
    let moved = try #require(try await txns.transaction(txn.id)?.txn)
    #expect(moved.type == .transfer && moved.accountID == Self.account.id && moved.toAccountID != nil)
    #expect(moved.payee == "Dinner for Ann" && moved.note == "split later")
    #expect(!model.canConvertToDebt(txn.id))
    let book = try await SQLiteDebtRepository(database: database, calendar: Self.calendar).book()
    #expect(book.debts.map(\.personName) == ["Ann"] && book.records.isEmpty)
    #expect(book.balance(of: book.debts[0].id, currency: .PLN, calendar: Self.calendar) == 60_00)
    #expect(try await txns.transactions(matching: TxnQuery()).count == 1)

    // Undo: an expense on my account again; the debt and its account stay, empty.
    #expect(model.canUnlinkTransfer(txn.id))
    await model.unlinkTransfer(txn.id)
    #expect(changed == 2)
    let back = try #require(try await txns.transaction(txn.id)?.txn)
    #expect(back.type == .expense && back.toAccountID == nil && back.accountID == Self.account.id)
    #expect(!model.canUnlinkTransfer(txn.id) && model.canConvertToDebt(txn.id))
    let after = try await SQLiteDebtRepository(database: database, calendar: Self.calendar).book()
    #expect(after.balance(of: after.debts[0].id, currency: .PLN, calendar: Self.calendar) == 0)
  }

  // MARK: Rules

  @Test("R-DEBT-12, C32: the rule editor's debt action needs a picked debt and reads as Transfer to debt · <person>")
  func ruleEditorDebtAction() async throws {
    let database = try AbacusDatabase.open(at: nil)
    var dependencies = ManageFixture.dependencies(ManagePreviewStore.sample())
    dependencies.debts = SQLiteDebtRepository(database: database, calendar: Self.calendar)
    let model = RulesModel(dependencies: dependencies)
    await model.load()
    model.newRule()
    model.editor?.pattern = "salary"
    model.editor?.action = .debt
    #expect(model.editorValidation == "Choose a debt.")
    await model.createDebt(named: "  Ann ")
    #expect(model.editorValidation == nil)
    let rule = try #require(model.editorRule)
    #expect(rule.action == .debt)
    #expect(rule.debtPersonName == "Ann")
    #expect(rule.categoryID == nil && rule.transferAccountID == nil)
    #expect(model.actionText(rule) == "Transfer to debt · Ann")
    await model.loadEditorTransactions()
    let changes = try #require(model.editorChanges)
    #expect(!changes.isEmpty)
    #expect(changes.allSatisfy { $0.type == .transfer && $0.toAccountID == nil && $0.isRefund })
  }

  @Test("R-DEBT-12: migration v12 stores the rule's person")
  func ruleRoundTrip() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let rules = SQLiteRuleRepository(database: database)
    try await rules.save(CategoryRule(pattern: "ann", action: .debt, debtPersonName: "Ann"))
    let saved = try #require(try await rules.rules().first)
    #expect(saved.action == .debt)
    #expect(saved.debtPerson == "Ann")
    let columns = try await database.read { db in try db.columns(in: "categoryRules").map(\.name) }
    #expect(columns.contains("debtPersonName"))
  }
}
