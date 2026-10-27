import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

/// A fresh editor over its own copy of the preview data, with handles on the fakes.
@MainActor
struct EditorHarness {
  let store = TransactionsPreviewStore.preview()
  let settings: EditorPreviewSettings
  let rules: EditorPreviewRules
  let model: TransactionEditorModel

  init(
    _ mode: TransactionEditorMode = .new,
    settings values: [SettingKey: String] = TransactionEditorDependencies.previewSettings,
    rules ruleList: [CategoryRule] = EditorPreviewRules.sample,
    now: Date = TransactionEditorDependencies.previewNow
  ) {
    settings = EditorPreviewSettings(values)
    rules = EditorPreviewRules(ruleList)
    var dependencies = TransactionEditorDependencies.preview(now: now, store: store)
    dependencies.settings = settings
    dependencies.rules = rules
    model = TransactionEditorModel(mode: mode, dependencies: dependencies)
  }

  static func loaded(
    _ mode: TransactionEditorMode = .new,
    settings: [SettingKey: String] = TransactionEditorDependencies.previewSettings,
    rules: [CategoryRule] = EditorPreviewRules.sample,
    now: Date = TransactionEditorDependencies.previewNow
  ) async -> EditorHarness {
    let harness = EditorHarness(mode, settings: settings, rules: rules, now: now)
    await harness.model.load()
    return harness
  }

  func stored(_ id: Txn.ID) async throws -> TxnWithLines? {
    try await store.transactions.transactions(matching: TxnQuery()).first { $0.txn.id == id }
  }

  func count() async throws -> Int {
    try await store.transactions.transactions(matching: TxnQuery()).count
  }
}

private func at(_ day: String, _ time: String = "12:00") -> Date {
  let d = Day(day)!
  let hm = time.split(separator: ":").compactMap { Int($0) }
  return Calendar.current.date(
    from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hm[0], minute: hm[1]))!
}

private let groceries = PreviewData.id(202)
private let eatingOut = PreviewData.id(203)
private let taxi = PreviewData.id(207)
private let fees = PreviewData.id(213)
private let salary = PreviewData.id(251)
private let cashback = PreviewData.id(252)

// MARK: - Amount text

@Suite("Editor · amount text")
struct EditorAmountTests {
  @Test("R-CUR-2: typed amounts become exact minor units with either separator")
  func parsing() {
    #expect(EditorAmount.minor("86.40", code: "PLN") == 86_40)
    #expect(EditorAmount.minor("86,40", code: "PLN") == 86_40)
    #expect(EditorAmount.minor("1 234,56", code: "UAH") == 1_234_56)
    #expect(EditorAmount.minor("1,234.56", code: "USD") == 1_234_56)
    #expect(EditorAmount.minor("1.234.567", code: "UAH") == 1_234_567_00)
    #expect(EditorAmount.minor(" 12 ", code: "EUR") == 12_00)
    #expect(EditorAmount.minor("", code: "EUR") == nil)
    #expect(EditorAmount.minor("abc", code: "EUR") == nil)
    #expect(EditorAmount.minor("-5", code: "EUR") == nil)
    #expect(EditorAmount.minor(".", code: "EUR") == nil)
  }

  @Test("R-CUR-4: other currencies use their own minor digits (CurrencyDigits)")
  func otherCurrencies() {
    #expect(EditorAmount.minor("1500", code: "JPY") == 1500)
    #expect(EditorAmount.minor("1.250", code: "KWD") == 1250)
    #expect(EditorAmount.minor("3990", code: "HUF") == 3990_00)
    #expect(EditorAmount.text(minor: 1500, code: "JPY") == "1500")
    #expect(EditorAmount.text(minor: 1_234_56, code: "PLN") == "1234.56")
    #expect(EditorAmount.text(minor: 5, code: "EUR") == "0.05")
  }
}

// MARK: - Defaults

@MainActor
@Suite("Editor · last-used defaults")
struct EditorDefaultsTests {
  @Test("R-EDIT-4: a new transaction starts with the last currency and account, with a hint")
  func lastTransaction() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    #expect(model.title == "New transaction")
    #expect(model.type == .expense)
    #expect(model.currencyCode == "EUR")
    #expect(model.accountID == PreviewData.revolutEUR.id)
    #expect(model.defaultsHint == "Currency and account from your last transaction")
    #expect(model.occurredAt == TransactionEditorDependencies.previewNow)
    model.accountID = PreviewData.pkoPersonal.id
    #expect(model.defaultsHint == nil)
  }

  @Test("R-EDIT-4: without remembered values the first active account and its currency, no hint")
  func noSettings() async {
    let h = await EditorHarness.loaded(settings: [:])
    #expect(h.model.accountID == PreviewData.monobank.id)
    #expect(h.model.currencyCode == "UAH")
    #expect(h.model.defaultsHint == nil)
    #expect(h.model.fromID == PreviewData.monobank.id)
    #expect(h.model.toID == PreviewData.pkoPersonal.id)
  }

  @Test("R-EDIT-4: an archived or unknown remembered account is not used")
  func archivedAccount() async {
    let h = await EditorHarness.loaded(settings: [
      .lastAccountID: PreviewData.oldCard.id.uuidString, .lastTxnCurrency: "usd",
    ])
    #expect(h.model.accountID == PreviewData.monobank.id)
    #expect(h.model.currencyCode == "USD")
  }

  @Test("R-EDIT-5: a new transfer starts with From and To of the last transfer, with a hint")
  func lastTransfer() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    #expect(model.fromID == PreviewData.monobank.id)
    #expect(model.toID == PreviewData.revolutEUR.id)
    #expect(model.defaultsHint == "From and To are the accounts of your last transfer")
    model.toID = PreviewData.cashPLN.id
    #expect(model.defaultsHint == nil)
  }

  @Test("R-EDIT-4: saving a new expense remembers its currency and account")
  func remembersTransaction() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "HUF"
    model.amountText = "3990"
    model.chargedText = "41.20"
    model.categoryID = eatingOut
    #expect(await model.save() != nil)
    let values = await h.settings.values
    #expect(values[.lastTxnCurrency] == "HUF")
    #expect(values[.lastAccountID] == PreviewData.pkoPersonal.id.uuidString)
    #expect(values[.lastTransferFromID] == PreviewData.monobank.id.uuidString)
  }

  @Test("R-EDIT-5: saving a new transfer remembers From and To")
  func remembersTransfer() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    model.fromID = PreviewData.pkoPersonal.id
    model.toID = PreviewData.cashPLN.id
    model.amountText = "200"
    #expect(await model.save() != nil)
    let values = await h.settings.values
    #expect(values[.lastTransferFromID] == PreviewData.pkoPersonal.id.uuidString)
    #expect(values[.lastTransferToID] == PreviewData.cashPLN.id.uuidString)
    #expect(values[.lastAccountID] == PreviewData.revolutEUR.id.uuidString)
  }

  @Test("R-EDIT-4: editing does not change the remembered defaults")
  func editKeepsDefaults() async throws {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(411)))
    h.model.note = "Weekly shop"
    #expect(await h.model.save() == .saved(PreviewData.id(411)))
    #expect(await h.settings.values == TransactionEditorDependencies.previewSettings)
  }
}

// MARK: - Form

@MainActor
@Suite("Editor · form")
struct EditorFormTests {
  @Test("R-EDIT-1, R-TX-1: one form for the three types; Save is disabled until valid")
  func oneForm() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    #expect(!model.canSave)
    #expect(model.issues.contains(.amount))
    model.payee = "Market"
    model.amountText = "12.50"
    #expect(model.issues == [.category])
    model.categoryID = groceries
    #expect(model.canSave)
    model.type = .income
    #expect(model.issues == [.category])
    #expect(model.payee == "Market")
    #expect(model.amountText == "12.50")
    #expect(model.categoryOptions.allSatisfy { $0.kind == .income })
    model.type = .transfer
    #expect(model.issues.isEmpty == false)  // Monobank UAH → Revolut EUR needs the amount received
    #expect(model.issues == [.receivedAmount])
    #expect(model.amountCode == "UAH")
    #expect(model.amountLabel == "Amount sent")
    #expect(model.sign == "⇄")
  }

  @Test("R-TX-4: refund and reversal flip the sign; changing the type clears the flag")
  func refunds() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    #expect(model.sign == "−")
    #expect(model.refundLabel == "Refund (money came back)")
    model.isRefund = true
    #expect(model.sign == "+")
    #expect(model.isInflow)
    model.type = .income
    #expect(!model.isRefund)
    #expect(model.sign == "+")
    #expect(model.refundLabel == "Reversal (money went back out)")
    model.isRefund = true
    #expect(model.sign == "−")
    model.type = .transfer
    #expect(!model.showsRefund)
    model.isRefund = true
    #expect(!model.isRefund)
  }

  @Test("R-TX-4: a refund is saved as an expense with the flag, in its expense category")
  func refundMapping() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "PLN"
    model.amountText = "59.99"
    model.payee = "Zalando"
    model.categoryID = PreviewData.id(212)
    model.isRefund = true
    let row = try #require(model.makeTransaction())
    #expect(row.txn.type == .expense)
    #expect(row.txn.isRefund)
    #expect(row.txn.categoryID == PreviewData.id(212))
    #expect(row.txn.amountMinor == 59_99)
    #expect(model.effectText == "+zł\u{00A0}59.99")
  }

  @Test("R-ACC-1, R-ACC-4: account pickers show active accounts with their currency")
  func accounts() async {
    let h = await EditorHarness.loaded()
    let options = h.model.accountOptions
    #expect(!options.contains { $0.id == PreviewData.oldCard.id })
    #expect(options.first.map(EditorReference.accountLabel) == "Monobank Black · UAH")
    #expect(options.count == 8)
  }

  @Test("R-CAT-2, R-MGMT-8: the category picker lists parents A–Z with their children A–Z indented")
  func categories() async {
    let h = await EditorHarness.loaded()
    let options = h.model.categoryOptions
    #expect(options.prefix(4).map(\.name) == ["Bills", "Mobile", "Clothing", "Fees"])
    #expect(options.prefix(4).map(\.isChild) == [false, true, false, false])
    #expect(h.model.reference.categoryPath(groceries) == "Food › Groceries")
  }
}

// MARK: - Currency

@MainActor
@Suite("Editor · transaction currency")
struct EditorCurrencyTests {
  @Test("R-CUR-4, R-EDIT-4: a foreign amount shows Charged to account, pre-filled at the day's rate")
  func chargedEstimate() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "EUR"
    #expect(model.isForeign)
    model.amountText = "10"
    // 1 EUR = 48.50 / 11.30 PLN = 4.2920 PLN
    #expect(model.chargedText == "42.92")
    #expect(model.chargedHint == "Estimated at the NBU rate 1 EUR = 4.2920 PLN. Change it to match your statement.")
    #expect(model.effectLabel == "Effect on PKO Personal in PLN")
    #expect(model.effectText == "−zł\u{00A0}42.92")
    model.chargedText = "43.10"
    model.categoryID = eatingOut
    let row = try #require(model.makeTransaction())
    #expect(row.txn.accountID == PreviewData.pkoPersonal.id)
    #expect(row.txn.amountMinor == 43_10)
    #expect(row.txn.originalAmountMinor == 10_00)
    #expect(row.txn.originalCurrencyCode == "EUR")
    // Changing the amount brings the estimate back.
    model.amountText = "20"
    #expect(model.chargedText == "85.84")
  }

  @Test("R-CUR-4: the account currency needs no charged amount and keeps no original")
  func sameCurrency() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.amountText = "14.20"
    model.categoryID = taxi
    #expect(!model.isForeign)
    let row = try #require(model.makeTransaction())
    #expect(row.txn.amountMinor == 14_20)
    #expect(row.txn.originalAmountMinor == nil)
    #expect(row.txn.originalCurrencyCode == nil)
  }

  @Test("D24: a currency without rates is not pre-filled; the charged amount must be typed")
  func noRateCurrency() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "HUF"
    model.amountText = "3990"
    model.categoryID = eatingOut
    #expect(model.chargedText == "")
    #expect(model.chargedHint == "No rates for HUF in Abacus. Enter the amount from your statement.")
    #expect(model.issues == [.charged])
    model.chargedText = "41,20"
    let row = try #require(model.makeTransaction())
    #expect(row.txn.amountMinor == 41_20)
    #expect(row.txn.originalAmountMinor == 3990_00)
    #expect(row.txn.originalCurrencyCode == "HUF")
  }

  @Test("R-CUR-4: before the first known rate the amount must be typed too")
  func noRateYet() async {
    let h = await EditorHarness.loaded(now: at("2026-01-05", "10:00"))
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.amountText = "10"
    #expect(model.chargedText == "")
    #expect(model.chargedHint == "No NBU rate for this date yet. Enter the amount from your statement.")
  }
}

// MARK: - Transfers

@MainActor
@Suite("Editor · transfers")
struct EditorTransferTests {
  @Test("R-TX-5: From and To must differ")
  func sameAccount() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    model.amountText = "100"
    model.toID = PreviewData.monobank.id
    #expect(model.sameAccounts)
    #expect(model.issues.contains(.sameAccounts))
    #expect(!model.canSave)
  }

  @Test("R-TX-5: same currency → one amount; the received amount equals the sent one")
  func sameCurrency() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    model.fromID = PreviewData.pkoPersonal.id
    model.toID = PreviewData.cashPLN.id
    model.amountText = "500"
    #expect(!model.crossCurrency)
    #expect(model.impliedRateText == nil)
    let row = try #require(model.makeTransaction())
    #expect(row.txn.type == .transfer)
    #expect(row.txn.amountMinor == 500_00)
    #expect(row.txn.toAccountID == PreviewData.cashPLN.id)
    #expect(row.txn.toAmountMinor == 500_00)
    #expect(row.txn.categoryID == nil)
    #expect(row.txn.eventID == nil)
    #expect(model.effectText == "−zł\u{00A0}500.00")
  }

  @Test("R-TX-5: different currencies need the amount received; the implied rate is shown")
  func crossCurrency() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    model.amountText = "4400"
    #expect(model.crossCurrency)
    #expect(model.impliedRateText == "Enter both amounts; the rate is calculated, not stored.")
    #expect(model.issues == [.receivedAmount])
    model.toAmountText = "100"
    #expect(model.impliedRateText == "Implied rate: 1 EUR = 44.0000 UAH")
    let row = try #require(model.makeTransaction())
    #expect(row.txn.amountMinor == 4_400_00)
    #expect(row.txn.toAmountMinor == 100_00)
    model.fromID = PreviewData.revolutEUR.id
    model.toID = PreviewData.monobank.id
    model.amountText = "100"
    model.toAmountText = "4400"
    #expect(model.impliedRateText == "Implied rate: 1 EUR = 44.0000 UAH")
  }
}

// MARK: - Rules and events

@MainActor
@Suite("Editor · suggestions")
struct EditorSuggestionTests {
  @Test("R-EDIT-3, R-IMP-8: the category is suggested from the description by the first matching rule")
  func suggestion() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    #expect(model.suggestion == nil)
    model.payee = "LIDL sp. z o.o. Warszawa"
    #expect(model.categoryID == groceries)
    #expect(model.suggestionText == "Suggested by rule “lidl” → Groceries")
    model.payee = "Bolt.eu ride"
    #expect(model.categoryID == taxi)
    model.categoryID = eatingOut
    #expect(model.suggestion == nil)
    #expect(model.categoryID == eatingOut)
    model.payee = "Lidl"
    #expect(model.categoryID == eatingOut)
  }

  @Test("R-EDIT-3: disabled rules, other accounts and the wrong kind are skipped")
  func ruleFilters() async {
    let rules = [
      CategoryRule(pattern: "shop", categoryID: fees, position: 0, isEnabled: false),
      CategoryRule(pattern: "shop", accountID: PreviewData.monobank.id, categoryID: taxi, position: 1),
      CategoryRule(pattern: "shop", categoryID: salary, position: 2),
      CategoryRule(pattern: "shop", categoryID: groceries, position: 3),
    ]
    let h = await EditorHarness.loaded(rules: rules)
    let model = h.model
    model.payee = "Corner shop"
    #expect(model.accountID == PreviewData.revolutEUR.id)
    #expect(model.categoryID == groceries)
    model.accountID = PreviewData.monobank.id
    #expect(model.categoryID == taxi)
    model.type = .income
    #expect(model.categoryID == salary)
  }

  @Test("R-EDIT-3, D44: amount and exact-match conditions apply; transfer rules never suggest")
  func saldoLikeConditions() async {
    let rules = [
      CategoryRule(pattern: "shop", action: .transfer, transferAccountID: PreviewData.loanFromFriend.id, position: 0),
      CategoryRule(pattern: "shop", amountComparison: .biggerThan, amountMinor: 100_00, categoryID: fees, position: 1),
      CategoryRule(pattern: "corner shop", matchKind: .exactly, categoryID: taxi, position: 2),
    ]
    let h = await EditorHarness.loaded(rules: rules)
    let model = h.model
    model.payee = "Corner  SHOP"
    #expect(model.categoryID == taxi)
    model.amountText = "150"
    #expect(model.categoryID == fees)
    model.amountText = "50"
    #expect(model.categoryID == taxi)
    model.payee = "Corner shop 12"
    #expect(model.suggestion == nil)
    #expect(model.type == .expense)
  }

  @Test("R-IMP-8: saving with a suggested category counts a rule hit")
  func recordsHit() async {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.payee = "Uber trip"
    model.amountText = "9.80"
    #expect(await model.save() != nil)
    #expect(await h.rules.hits[PreviewData.id(904)] == 1)
  }

  @Test("R-EVT-2: an active event is pre-selected for a new expense, with a hint; it can be cleared")
  func eventPreselection() async {
    let h = await EditorHarness.loaded(now: at("2026-10-12", "09:00"))
    let model = h.model
    #expect(model.eventID == PreviewData.lyonTrip.id)
    #expect(model.eventHint == "Pre-selected: “Lyon trip” is active on this date")
    model.occurredAt = at("2026-10-20")
    #expect(model.eventID == nil)
    #expect(model.eventHint == nil)
    model.occurredAt = at("2026-10-19", "23:00")
    #expect(model.eventID == PreviewData.lyonTrip.id)
    model.eventID = nil
    #expect(model.eventID == nil)
    #expect(model.eventHint == nil)
    model.occurredAt = at("2026-10-10")
    #expect(model.eventID == nil)
  }

  @Test("R-EVT-2: no pre-selection for transfers or when editing")
  func noPreselection() async {
    let h = await EditorHarness.loaded(now: at("2026-10-12", "09:00"))
    h.model.type = .transfer
    #expect(h.model.eventID == nil)
    let edit = await EditorHarness.loaded(.edit(PreviewData.id(409)))
    #expect(edit.model.occurredAt < at("2026-10-19"))
    #expect(edit.model.eventID == nil)
    #expect(edit.model.eventHint == nil)
  }

  @Test("R-EVT-2: the event is saved on the transaction")
  func eventSaved() async throws {
    let h = await EditorHarness.loaded(now: at("2026-10-12", "09:00"))
    h.model.amountText = "18"
    h.model.categoryID = eatingOut
    let row = try #require(h.model.makeTransaction())
    #expect(row.txn.eventID == PreviewData.lyonTrip.id)
  }

  @Test("R-EVT-1: event labels show the date range")
  func eventLabels() {
    #expect(EditorReference.eventLabel(PreviewData.lyonTrip) == "Lyon trip · 1–19 Oct")
    #expect(EditorReference.eventLabel(PreviewData.relocation) == "Relocation")
    #expect(
      EditorReference.eventLabel(Event(name: "Move", startDay: "2026-09-28", endDay: "2026-10-03"))
        == "Move · 28 Sep – 3 Oct")
    #expect(EditorReference.eventLabel(Event(name: "Car", startDay: "2026-10-01")) == "Car · from 1 Oct")
  }
}

// MARK: - Lines

@MainActor
@Suite("Editor · fees, cashback and split lines")
struct EditorLineTests {
  @Test("R-EDIT-2, R-TX-6: Add fee / Add line add attached records; the effect is main ± lines")
  func lines() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "PLN"
    model.amountText = "86.40"
    model.payee = "Lidl"
    model.addFee()
    #expect(model.lines.first?.categoryID == fees)
    #expect(model.lines.first?.note == "Fee")
    #expect(model.issues == [.line(model.lines[0].id)])
    model.lines[0].amountText = "1.50"
    model.addLine()
    #expect(model.lines[1].categoryID == groceries)
    model.lines[1].amountText = "2"
    model.setLineKind(model.lines[1].id, .income)
    #expect(model.lines[1].categoryID == cashback)
    #expect(model.effectLabel == "Effect on PKO Personal (with 2 lines)")
    #expect(model.effectMinor == -86_40 - 1_50 + 2_00)
    #expect(model.effectText == "−zł\u{00A0}85.90")
    let row = try #require(model.makeTransaction())
    #expect(row.lines.count == 2)
    #expect(row.lines.map(\.kind) == [.expense, .income])
    #expect(row.lines.map(\.amountMinor) == [1_50, 2_00])
    #expect(row.lines.map(\.position) == [0, 1])
    #expect(row.lines.allSatisfy { $0.txnID == row.txn.id })
    model.removeLine(model.lines[0].id)
    #expect(model.effectText == "−zł\u{00A0}84.40")
  }

  @Test("R-TX-6: a transfer may carry a fee charged to the From account")
  func transferFee() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.type = .transfer
    model.amountText = "4400"
    model.toAmountText = "100"
    model.addFee()
    model.lines[0].amountText = "22"
    #expect(model.effectLabel == "Effect on Monobank Black (with 1 line)")
    #expect(model.effectText == "−₴4,422.00")
    let row = try #require(model.makeTransaction())
    #expect(row.lines.first?.categoryID == fees)
  }

  @Test("D22: an income line may use an expense category (a refund line)")
  func refundLine() async throws {
    let h = await EditorHarness.loaded()
    let model = h.model
    model.amountText = "40"
    model.categoryID = PreviewData.id(212)
    model.addLine()
    model.setLineKind(model.lines[0].id, .income)
    let options = model.lineCategoryOptions(model.lines[0])
    #expect(options.primary.allSatisfy { $0.kind == .income })
    #expect(options.refund.contains { $0.id == PreviewData.id(212) })
    model.lines[0].categoryID = PreviewData.id(212)
    model.lines[0].amountText = "10"
    let row = try #require(model.makeTransaction())
    #expect(row.lines.first?.kind == .income)
    #expect(row.lines.first?.categoryID == PreviewData.id(212))
    #expect(model.effectMinor == -30_00)
  }
}

// MARK: - Edit, delete, duplicate

@MainActor
@Suite("Editor · edit, delete, duplicate")
struct EditorEditTests {
  @Test(
    "R-TX-1…6: every stored transaction round-trips through the form unchanged",
    arguments: PreviewData.txns.map(\.id))
  func roundTrip(id: Txn.ID) async throws {
    let h = await EditorHarness.loaded(.edit(id))
    let stored = try #require(try await h.stored(id))
    let row = try #require(h.model.makeTransaction())
    #expect(row.txn == stored.txn)
    #expect(row.lines == stored.lines)
  }

  @Test("R-CUR-4: a stored foreign purchase opens with its original amount and the charged one")
  func editForeign() async {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(405)))
    let model = h.model
    #expect(model.title == "Edit transaction")
    #expect(model.currencyCode == "EUR")
    #expect(model.amountText == "10.00")
    #expect(model.chargedText == "440.00")
    #expect(model.accountID == PreviewData.monobank.id)
    #expect(model.eventID == PreviewData.lyonTrip.id)
    #expect(model.defaultsHint == nil)
  }

  @Test("R-TX-7: edit shows the source and saves changes in place")
  func edit() async throws {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(404)))
    let model = h.model
    #expect(model.sourceText == "Imported from PKO · 19 Oct 2026")
    #expect(model.categoryID == groceries)
    model.amountText = "18.35"
    model.note = "Bread too"
    #expect(await model.save() == .saved(PreviewData.id(404)))
    let saved = try #require(try await h.stored(PreviewData.id(404)))
    #expect(saved.txn.amountMinor == 18_35)
    #expect(saved.txn.note == "Bread too")
    #expect(saved.txn.source == .pko)
    #expect(try await h.count() == PreviewData.txns.count)
  }

  @Test("R-TX-7: delete removes the transaction with its lines")
  func delete() async throws {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(411)))
    #expect(h.model.deleteMessage == "“Lidl” · −zł\u{00A0}86.40 · 5 Oct 2026. Its fees and split lines are deleted with it.")
    #expect(await h.model.delete() == .deleted(PreviewData.id(411)))
    #expect(try await h.stored(PreviewData.id(411)) == nil)
    let fresh = await EditorHarness.loaded()
    #expect(await fresh.model.delete() == nil)
  }

  @Test("R-TX-7: deleting an imported transaction warns that re-importing brings it back")
  func deleteImported() async {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(404)))
    #expect(h.model.deleteMessage.hasSuffix("Importing the same file again would add it back."))
  }

  @Test("R-TX-7: duplicate makes a new manual transaction with the same values, dated now")
  func duplicate() async throws {
    let h = await EditorHarness.loaded(.edit(PreviewData.id(411)))
    let model = h.model
    model.duplicate()
    #expect(model.isNew)
    #expect(model.title == "New transaction")
    #expect(model.defaultsHint == nil)
    let result = await model.save()
    guard case .saved(let id) = result else {
      Issue.record("not saved")
      return
    }
    #expect(id != PreviewData.id(411))
    let copy = try #require(try await h.stored(id))
    #expect(copy.txn.payee == "Lidl")
    #expect(copy.txn.amountMinor == 86_40)
    #expect(copy.txn.categoryID == groceries)
    #expect(copy.txn.source == .manual)
    #expect(copy.txn.occurredAt == TransactionEditorDependencies.previewNow)
    #expect(copy.lines.count == 1)
    #expect(copy.lines.first?.id != PreviewData.id(502))
    #expect(copy.lines.first?.categoryID == cashback)
    #expect(try await h.stored(PreviewData.id(411)) != nil)
    #expect(try await h.count() == PreviewData.txns.count + 1)
  }

  @Test("R-TX-7: a missing transaction cannot be edited")
  func missing() async {
    let h = await EditorHarness.loaded(.edit(UUID()))
    #expect(!h.model.isLoaded)
    #expect(h.model.errorMessage == "This transaction no longer exists.")
    #expect(!h.model.canSave)
  }
}
