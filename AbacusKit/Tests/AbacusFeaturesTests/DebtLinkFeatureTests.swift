import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C17 screens: the shared debt sheet, the import wizard's "Debt…", "Convert to debt record…" in
/// the transaction list and the rule editor's debt action (R-DEBT-10…12). Synthetic data only.
@MainActor
@Suite("Debt linking screens (C17)")
struct DebtLinkFeatureTests {
  static let calendar = ImportHarness.calendar
  static let account = Account(
    id: PreviewData.id(9101), name: "Bank PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")

  static func book(_ records: [(String, Currency, DebtRecordKind, Int64)]) -> DebtBook {
    var debts: [Debt] = []
    var entries: [DebtRecordEntry] = []
    for (person, currency, kind, amount) in records {
      let debt = debts.first { $0.personName == person && $0.currency == currency } ?? {
        let debt = Debt(personName: person, currency: currency)
        debts.append(debt)
        return debt
      }()
      entries.append(DebtRecordEntry(record: DebtRecord(debtID: debt.id, kind: kind, day: "2026-01-01", amountMinor: amount)))
    }
    return DebtBook(debts: debts, entries: entries)
  }

  // MARK: Shared sheet

  @Test("R-DEBT-10/11: the sheet suggests the person's debt in the account's currency and the kind from the balance")
  func draftDefaults() {
    let book = Self.book([("Ann", .PLN, .lent, 100_00), ("Bob", .EUR, .borrowed, 20_00)])
    var draft = DebtLinkDraft(
      title: "t", subtitle: "s", inflow: true, accountCurrency: .PLN, accountAmountMinor: 40_00, book: book,
      convertedAmounts: [.EUR: 9_30], format: ManageFormat(locale: Locale(identifier: "en_US")))
    #expect(draft.validation == "Enter the person's name.")
    #expect(draft.personOptions == ["Ann", "Bob"])
    draft.personName = "ann "
    #expect(draft.debt == .existing(book.debts[0].id))
    #expect(draft.kind == .theyRepaid)
    #expect(draft.kindOptions == [.theyRepaid, .borrowed])
    #expect(draft.flagTitle == "Count as income")
    #expect(!draft.needsAmount)
    #expect(draft.link == DebtLink(personName: "ann", debtID: book.debts[0].id, currency: .PLN, kind: .theyRepaid))

    // Bob owes nothing in PLN: a new PLN debt, money in = I borrowed; his EUR debt pre-fills the
    // amount at the day's rate.
    draft.personName = "Bob"
    #expect(draft.debt == .new(.PLN))
    #expect(draft.kind == .borrowed)
    #expect(draft.debtChoices.map(\.label) == ["EUR · you owe €20.00", "New debt in PLN"])
    draft.debt = .existing(book.debts[1].id)
    #expect(draft.needsAmount)
    #expect(draft.amountText == "9.30")
    #expect(draft.kind == .borrowed)
    #expect(draft.link?.amountMinor == 9_30)
    draft.amountText = ""
    #expect(draft.validation == "Enter the amount in EUR.")
  }

  @Test("R-DEBT-10: money out while I owe them suggests I repaid; pending rows of the same import count")
  func draftPendingEffects() {
    let book = Self.book([("Ann", .PLN, .borrowed, 50_00)])
    var draft = DebtLinkDraft(title: "t", subtitle: "s", inflow: false, accountCurrency: .PLN, accountAmountMinor: 50_00, book: book)
    draft.personName = "Ann"
    #expect(draft.kind == .iRepaid)
    let key = DebtLinkDraft.key(person: "Ann", currency: .PLN, debtID: book.debts[0].id)
    var later = DebtLinkDraft(
      title: "t", subtitle: "s", inflow: false, accountCurrency: .PLN, accountAmountMinor: 50_00, book: book,
      pendingEffects: [key: 50_00])
    later.personName = "Ann"
    #expect(later.kind == .lent)
  }

  // MARK: Import wizard

  @Test("R-DEBT-10: Debt… on a new row and on a Needs review row; the commit makes one leg each")
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
    #expect(draft.kind == .lent)
    model.saveDebt(draft)
    #expect(model.debtDraft == nil)
    let recorded = try #require(model.rowItems.first { $0.id == rent.id })
    #expect(recorded.statusLabel == "Debt record")
    #expect(recorded.debt?.hasPrefix("I lent · Anna") == true)
    #expect(recorded.category == .none)

    let fee = try #require(model.reviewItems.first { $0.title == "Unknown operation type" })
    await model.openDebt(forRow: fee.id)
    var feeDraft = try #require(model.debtDraft)
    feeDraft.personName = "Anna"
    feeDraft.kind = .paidOnTheirBehalf
    model.saveDebt(feeDraft)
    let decided = try #require(model.reviewItems.first { $0.id == fee.id })
    #expect(decided.selected == .debt)
    #expect(decided.debtLabel?.hasPrefix("Paid on their behalf · Anna") == true)

    model.acceptSuggestions()
    await model.commit()
    #expect(model.step == .done)
    #expect(model.doneLines.contains("2 recorded as debt records"))
    let legs = try await harness.txns().filter { $0.txn.debtRecordID != nil }
    #expect(legs.count == 2)
    let book = try await SQLiteDebtRepository(database: harness.database, calendar: Self.calendar).book()
    #expect(book.debts.count == 1)
    #expect(book.balance(of: book.debts[0].id) == 1_500_00 + 5_00)
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

  @Test("R-DEBT-11: Convert to debt record in the list keeps the transaction and makes it the leg")
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
    #expect(draft.kindOptions == [.lent, .iRepaid, .paidOnTheirBehalf])
    draft.personName = "Ann"
    draft.kind = .paidOnTheirBehalf
    await model.saveConvertToDebt(draft)
    #expect(changed == 1)
    #expect(model.debtDraft == nil)
    let leg = try #require(try await txns.transaction(txn.id)?.txn)
    #expect(leg.debtRecordID != nil)
    #expect(leg.payee == "Dinner for Ann")
    #expect(!model.canConvertToDebt(txn.id))
    let book = try await SQLiteDebtRepository(database: database, calendar: Self.calendar).book()
    #expect(book.entries.first?.record.kind == .paidOnTheirBehalf)
    #expect(book.entries.first?.record.note == "split later")
    #expect(try await txns.transactions(matching: TxnQuery()).count == 1)
  }

  // MARK: Rules

  @Test("R-DEBT-12: the rule editor's debt action needs a person and reads as Debt record for <person>")
  func ruleEditorDebtAction() async throws {
    let model = RulesModel(dependencies: ManageFixture.dependencies(ManagePreviewStore.sample()))
    await model.load()
    model.newRule()
    model.editor?.pattern = "salary"
    model.editor?.action = .debt
    #expect(model.editorValidation == "Enter the person's name.")
    model.editor?.debtPersonName = "  Ann "
    #expect(model.editorValidation == nil)
    let rule = try #require(model.editorRule)
    #expect(rule.action == .debt)
    #expect(rule.debtPersonName == "Ann")
    #expect(rule.categoryID == nil && rule.transferAccountID == nil)
    #expect(model.actionText(rule) == "Debt record for Ann")
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
