import AbacusDomain
import Foundation
import Observation

/// Why Save is disabled (approved prototype 3: "Save disabled until valid").
public enum EditorIssue: Hashable, Sendable {
  /// No amount, or not a positive number.
  case amount
  /// Expense/income without an account, or a transfer without a From account.
  case account
  /// A foreign-currency amount needs the amount charged to the account (R-CUR-4).
  case charged
  /// Expense/income need a category of the matching kind (R-TX-3).
  case category
  /// Transfer without a To account.
  case toAccount
  /// "From and To must be different accounts." (R-TX-5)
  case sameAccounts
  /// A cross-currency transfer needs the amount received (R-TX-5).
  case receivedAmount
  /// A fee / split line without an amount or a category (R-TX-6).
  case line(EditorLine.ID)
}

/// The transaction editor (approved prototype 3; R-EDIT-1…5, R-TX-1…7, R-CUR-4, R-EVT-2):
/// one form for expense, income and transfer, last-used defaults, the charged amount of a
/// foreign purchase, rule suggestions, event pre-selection, fee and split lines, validation,
/// save, delete and duplicate. Works against the repository protocols; `preview(_:)` runs it on
/// `PreviewData`.
@MainActor
@Observable
public final class TransactionEditorModel {
  public private(set) var mode: TransactionEditorMode
  public private(set) var draft: EditorDraft
  public private(set) var reference = EditorReference()
  public private(set) var isLoaded = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  /// The new form started with the last transaction's currency/account (R-EDIT-4) or the last
  /// transfer's accounts (R-EDIT-5); the hint shows until the user changes them.
  public private(set) var usedTransactionDefaults = false
  public private(set) var usedTransferDefaults = false
  public private(set) var defaultsTouched = false
  /// Rates for the charged-amount estimate; replace it when rates change.
  public var converter: any CurrencyConverter

  @ObservationIgnored private let dependencies: TransactionEditorDependencies
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let moneyFormat = TransactionMoneyFormat()
  /// Days whose rates were asked for (R-EDIT-4, R-FX-1), and the request in flight.
  @ObservationIgnored private var requestedRateDays: Set<Day> = []
  @ObservationIgnored private var ratesTask: Task<Void, Never>?

  public init(mode: TransactionEditorMode, dependencies: TransactionEditorDependencies) {
    self.mode = mode
    self.dependencies = dependencies
    calendar = dependencies.calendar
    converter = dependencies.converter
    draft = EditorDraft(occurredAt: dependencies.now())
  }

  /// The editor on the synthetic preview data (`TransactionEditorDependencies.preview()`).
  public static func preview(
    _ mode: TransactionEditorMode = .new, dependencies: TransactionEditorDependencies = .preview()
  ) -> TransactionEditorModel {
    TransactionEditorModel(mode: mode, dependencies: dependencies)
  }

  // MARK: Loading

  /// Loads accounts, categories, events and rules, then the stored transaction (edit) or the
  /// last-used defaults (new).
  public func load() async {
    do {
      let accounts = try await dependencies.accounts.accounts(includeArchived: true)
      let categories = try await dependencies.categories.categories(kind: nil, includeArchived: true)
      let events = try await dependencies.events.events(includeArchived: true)
      let rules = (try? await dependencies.rules.rules()) ?? []
      reference = EditorReference(accounts: accounts, categories: categories, events: events, rules: rules)
    } catch {
      errorMessage = "Couldn't load accounts and categories."
      return
    }
    switch mode {
    case .new:
      await applyDefaults()
    case .edit(let id):
      do {
        guard let row = try await dependencies.transaction(id) else {
          errorMessage = "This transaction no longer exists."
          return
        }
        draft = EditorDraft(editing: row, accounts: reference.accountsByID)
      } catch {
        errorMessage = "Couldn't load the transaction."
        return
      }
    }
    isLoaded = true
    requestRatesIfNeeded()
  }

  /// R-EDIT-4/5: currency and account of the last transaction, From/To of the last transfer.
  /// Unknown or archived accounts fall back to the first active account.
  private func applyDefaults() async {
    let active = reference.accountOptions()
    let lastAccount = await defaultAccount(.lastAccountID)
    let lastCode = (try? await dependencies.settings.value(.lastTxnCurrency))
      .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
      .flatMap { $0.count == 3 && $0.allSatisfy(\.isLetter) ? $0 : nil }
    let start = lastAccount ?? active.first
    draft.accountID = start?.id
    draft.currencyCode = lastCode ?? start?.currency.rawValue ?? Currency.UAH.rawValue
    usedTransactionDefaults = lastAccount != nil || lastCode != nil

    let from = await defaultAccount(.lastTransferFromID)
    var to = await defaultAccount(.lastTransferToID)
    if to?.id == from?.id { to = nil }
    draft.fromID = from?.id ?? start?.id
    draft.toID = to?.id ?? active.first { $0.id != draft.fromID }?.id
    usedTransferDefaults = from != nil && to != nil
  }

  /// An active account stored under `key`.
  private func defaultAccount(_ key: SettingKey) async -> Account? {
    guard let text = try? await dependencies.settings.value(key), let id = UUID(uuidString: text),
      let account = reference.account(id), !account.isArchived
    else { return nil }
    return account
  }

  // MARK: Fields (bindings)

  public var type: TxnType {
    get { draft.type }
    set {
      guard newValue != draft.type else { return }
      draft.type = newValue
      draft.isRefund = false
      draft.categoryChosen = false
      if let category = reference.category(draft.categoryID), category.kind != categoryKind {
        draft.categoryID = nil
      }
      requestRatesIfNeeded()
    }
  }

  /// The big amount: in the transaction currency, or the From currency for a transfer.
  public var amountText: String {
    get { draft.amountText }
    set {
      draft.amountText = newValue
      draft.chargedEdited = false
    }
  }

  /// Transaction currency (R-EDIT-4).
  public var currencyCode: String {
    get { draft.currencyCode }
    set {
      guard newValue != draft.currencyCode else { return }
      draft.currencyCode = newValue
      draft.chargedEdited = false
      defaultsTouched = true
      requestRatesIfNeeded()
    }
  }

  public var accountID: Account.ID? {
    get { draft.accountID }
    set {
      guard newValue != draft.accountID else { return }
      draft.accountID = newValue
      draft.chargedEdited = false
      defaultsTouched = true
      requestRatesIfNeeded()
    }
  }

  /// "Charged to account": the estimate at the day's rate until the user types one.
  public var chargedText: String {
    get { draft.chargedEdited ? draft.chargedText : estimatedChargedMinor.map { accountText($0) } ?? "" }
    set {
      draft.chargedText = newValue
      draft.chargedEdited = true
    }
  }

  /// The category shown: the user's pick, else the rule suggestion (R-EDIT-3).
  public var categoryID: AbacusDomain.Category.ID? {
    get { effectiveCategoryID }
    set {
      draft.categoryID = newValue
      draft.categoryChosen = true
    }
  }

  public var isRefund: Bool {
    get { draft.isRefund }
    set { draft.isRefund = newValue && !isTransfer }
  }

  public var fromID: Account.ID? {
    get { draft.fromID }
    set {
      guard newValue != draft.fromID else { return }
      draft.fromID = newValue
      defaultsTouched = true
    }
  }

  public var toID: Account.ID? {
    get { draft.toID }
    set {
      guard newValue != draft.toID else { return }
      draft.toID = newValue
      defaultsTouched = true
    }
  }

  public var toAmountText: String {
    get { draft.toAmountText }
    set { draft.toAmountText = newValue }
  }

  public var payee: String {
    get { draft.payee }
    set { draft.payee = newValue }
  }

  public var occurredAt: Date {
    get { draft.occurredAt }
    set {
      draft.occurredAt = newValue
      requestRatesIfNeeded()
    }
  }

  /// The event shown: the user's pick, else the event active on the date (R-EVT-2).
  public var eventID: Event.ID? {
    get { effectiveEventID }
    set {
      draft.eventID = newValue
      draft.eventChosen = true
    }
  }

  public var note: String {
    get { draft.note }
    set { draft.note = newValue }
  }

  public var lines: [EditorLine] {
    get { draft.lines }
    set { draft.lines = newValue }
  }

  // MARK: Lines (R-EDIT-2, R-TX-6)

  /// "Add fee": an expense line in Fees, note "Fee".
  public func addFee() {
    draft.lines.append(EditorLine(kind: .expense, categoryID: reference.feesCategoryID, note: "Fee"))
  }

  /// "Add line": an expense line, in the main category for an expense (a split).
  public func addLine() {
    draft.lines.append(EditorLine(kind: .expense, categoryID: type == .expense ? effectiveCategoryID : nil))
  }

  public func removeLine(_ id: EditorLine.ID) {
    draft.lines.removeAll { $0.id == id }
  }

  /// Switching a line's kind resets its category: Fees for an expense, Cashback for income.
  public func setLineKind(_ id: EditorLine.ID, _ kind: CategoryKind) {
    guard let index = draft.lines.firstIndex(where: { $0.id == id }), draft.lines[index].kind != kind else { return }
    draft.lines[index].kind = kind
    draft.lines[index].categoryID =
      kind == .expense ? reference.feesCategoryID : reference.categories.first {
        $0.kind == .income && !$0.isArchived && $0.name.lowercased() == "cashback"
      }?.id
  }

  /// Categories a line offers: expense lines expense categories; income lines income
  /// categories, then expense ones as refund lines (D22).
  public func lineCategoryOptions(_ line: EditorLine) -> (primary: [EditorReference.CategoryOption], refund: [EditorReference.CategoryOption]) {
    switch line.kind {
    case .expense:
      return (reference.categoryOptions(kind: .expense, including: line.categoryID), [])
    case .income:
      return (
        reference.categoryOptions(kind: .income, including: line.categoryID),
        reference.categoryOptions(kind: .expense, including: line.categoryID)
      )
    }
  }

  // MARK: Derived state

  public var isTransfer: Bool { draft.type == .transfer }
  public var isNew: Bool { mode == .new }
  public var title: String { isNew ? "New transaction" : "Edit transaction" }

  /// "Imported from PKO · 5 Oct 2026" / "Entered manually · 5 Oct 2026" (edit only).
  public var sourceText: String? {
    guard !isNew, let stored = draft.stored else { return nil }
    let date = stored.createdAt.formatted(Self.dayFormat)
    let origin: String
    switch stored.source {
    case .manual: origin = "Entered manually"
    case .pko: origin = "Imported from PKO"
    case .saldo: origin = "Imported from Saldo"
    }
    return "\(origin) · \(date)" + (stored.isPendingAtBank ? " · Pending at the bank" : "")
  }

  /// The account the amounts hit: the account, or From for a transfer.
  public var account: Account? { reference.account(isTransfer ? draft.fromID : draft.accountID) }
  public var toAccount: Account? { isTransfer ? reference.account(draft.toID) : nil }

  /// Currency of the big amount.
  public var amountCode: String { isTransfer ? account?.currency.rawValue ?? draft.currencyCode : draft.currencyCode }
  public var amountLabel: String { isTransfer ? "Amount sent" : "Amount" }

  /// The big amount in minor units of `amountCode`; nil unless positive.
  public var amountMinor: Int64? { positive(EditorAmount.minor(draft.amountText, code: amountCode)) }

  public var day: Day { Day(draft.occurredAt, calendar: calendar) }

  // Sign and refund (R-TX-4)

  /// Money comes into the account: income, or an expense refund.
  public var isInflow: Bool { !isTransfer && (draft.type == .income) != draft.isRefund }
  /// "−", "+" or "⇄".
  public var sign: String { isTransfer ? "⇄" : isInflow ? "+" : "−" }
  public var showsRefund: Bool { !isTransfer }
  public var refundLabel: String {
    draft.type == .income ? "Reversal (money went back out)" : "Refund (money came back)"
  }

  // Defaults hint (R-EDIT-4/5)

  public var defaultsHint: String? {
    guard isNew, !defaultsTouched else { return nil }
    if isTransfer {
      return usedTransferDefaults ? "From and To are the accounts of your last transfer" : nil
    }
    return usedTransactionDefaults ? "Currency and account from your last transaction" : nil
  }

  /// Picker currencies: the approved list plus the current code when it is another one.
  public var currencyOptions: [String] {
    EditorReference.currencyCodes.contains(draft.currencyCode)
      ? EditorReference.currencyCodes : EditorReference.currencyCodes + [draft.currencyCode]
  }

  public var accountOptions: [Account] {
    reference.accountOptions(including: [draft.accountID, draft.fromID, draft.toID])
  }

  // Foreign currency (R-CUR-4, R-EDIT-4, D24)

  /// The transaction currency differs from the account's: "Charged to account" is shown.
  public var isForeign: Bool {
    guard !isTransfer, let account else { return false }
    return draft.currencyCode != account.currency.rawValue
  }

  /// `1 <currency> = rate <account currency>` on the transaction's day; nil for currencies
  /// without rates (D24) or days before the first known rate.
  public var chargedRate: Decimal? {
    guard isForeign, let account, let currency = Currency(rawValue: draft.currencyCode) else { return nil }
    return converter.rate(from: currency, to: account.currency, on: day)
  }

  /// A foreign amount in one of the rate currencies (D24: UAH, PLN, EUR, USD; others stay
  /// manual) asks the rate service for the transaction's day, once per day; when the answer
  /// arrives the converter is replaced, so an untouched "Charged to account" pre-fills
  /// (R-EDIT-4, R-FX-1). With auto-refresh off the refresher only remembers the day.
  private func requestRatesIfNeeded() {
    guard isLoaded, let request = dependencies.requestRates, isForeign,
      Currency(rawValue: draft.currencyCode) != nil
    else { return }
    let day = day
    guard requestedRateDays.insert(day).inserted else { return }
    let previous = ratesTask
    ratesTask = Task { [weak self] in
      await previous?.value
      guard let converter = await request([day]) else { return }
      self?.converter = converter
    }
  }

  /// Waits for the rate requests started so far (tests).
  public func waitForRates() async {
    await ratesTask?.value
  }

  /// The amount converted at the day's rate, in the account's minor units.
  public var estimatedChargedMinor: Int64? {
    guard let rate = chargedRate, let account, let minor = amountMinor else { return nil }
    let amount = Money(minorUnits: minor, currency: Currency(rawValue: draft.currencyCode) ?? account.currency).decimal
    return Money(amount * rate, account.currency).minorUnits
  }

  /// The amount the account sees, in its minor units: the charged amount when foreign.
  public var chargedMinor: Int64? {
    guard isForeign, let account else { return amountMinor }
    return positive(EditorAmount.minor(chargedText, code: account.currency.rawValue))
  }

  public var chargedHint: String {
    guard let account else { return "" }
    let accountCode = account.currency.rawValue
    if let rate = chargedRate {
      return "Estimated at the NBU rate 1 \(draft.currencyCode) = \(EditorAmount.rateText(rate)) \(accountCode). "
        + "Change it to match your statement."
    }
    if Currency(rawValue: draft.currencyCode) == nil {
      return "No rates for \(draft.currencyCode) in Abacus. Enter the amount from your statement."
    }
    return "No NBU rate for this date yet. Enter the amount from your statement."
  }

  // Transfer (R-TX-5)

  public var sameAccounts: Bool { isTransfer && draft.fromID != nil && draft.fromID == draft.toID }

  public var crossCurrency: Bool {
    guard isTransfer, let from = account, let to = toAccount else { return false }
    return from.currency != to.currency
  }

  /// What the To account receives, in its minor units.
  public var toAmountMinor: Int64? {
    guard isTransfer else { return nil }
    guard crossCurrency, let to = toAccount else { return amountMinor }
    return positive(EditorAmount.minor(draft.toAmountText, code: to.currency.rawValue))
  }

  public var impliedRateText: String? {
    guard crossCurrency, let from = account, let to = toAccount else { return nil }
    guard let sent = EditorAmount.decimal(draft.amountText), sent > 0,
      let received = EditorAmount.decimal(draft.toAmountText), received > 0
    else { return "Enter both amounts; the rate is calculated, not stored." }
    return sent >= received
      ? "Implied rate: 1 \(to.currency.rawValue) = \(EditorAmount.rateText(sent / received)) \(from.currency.rawValue)"
      : "Implied rate: 1 \(from.currency.rawValue) = \(EditorAmount.rateText(received / sent)) \(to.currency.rawValue)"
  }

  // Category (R-TX-3, R-EDIT-3)

  public var categoryKind: CategoryKind { draft.type == .income ? .income : .expense }

  /// The matching rule while the user has not picked a category.
  public var suggestion: EditorReference.Suggestion? {
    guard !isTransfer, !draft.categoryChosen else { return nil }
    return reference.suggestion(for: draft.payee, accountID: draft.accountID, kind: categoryKind, amountMinor: chargedMinor)
  }

  /// "Suggested by rule “lidl” → Groceries".
  public var suggestionText: String? {
    suggestion.map { "Suggested by rule “\($0.rule.label)” → \($0.category.name)" }
  }

  public var effectiveCategoryID: AbacusDomain.Category.ID? {
    guard !isTransfer else { return nil }
    if let suggestion { return suggestion.category.id }
    guard let category = reference.category(draft.categoryID), category.kind == categoryKind else { return nil }
    return category.id
  }

  public var categoryOptions: [EditorReference.CategoryOption] {
    reference.categoryOptions(kind: categoryKind, including: effectiveCategoryID)
  }

  // Event (R-EVT-2)

  /// The event active on the date, pre-selected for a new expense or income until the user
  /// picks one.
  public var preselectedEvent: Event? {
    guard isNew, !isTransfer, !draft.eventChosen else { return nil }
    return reference.activeEvent(on: day)
  }

  public var effectiveEventID: Event.ID? { preselectedEvent?.id ?? draft.eventID }

  public var eventHint: String? {
    preselectedEvent.map { "Pre-selected: “\($0.name)” is active on this date" }
  }

  public var eventOptions: [Event] { reference.eventOptions(including: effectiveEventID) }

  public func eventLabel(_ event: Event) -> String { EditorReference.eventLabel(event, calendar: calendar) }

  // Effect on the account (R-TX-6, R-ACC-3)

  /// Main amount ± lines in the account's minor units (lines without a valid amount count 0).
  public var effectMinor: Int64 {
    guard let account else { return 0 }
    let code = account.currency.rawValue
    var effect: Int64
    if isTransfer {
      effect = -(amountMinor ?? 0)
    } else {
      let main = chargedMinor ?? 0
      effect = isInflow ? main : -main
    }
    for line in draft.lines {
      let amount = positive(EditorAmount.minor(line.amountText, code: code)) ?? 0
      effect += line.kind == .income ? amount : -amount
    }
    return effect
  }

  /// "−zł84.40".
  public var effectText: String {
    guard let account else { return "" }
    return moneyFormat.string(minor: effectMinor, code: account.currency.rawValue, sign: .always)
  }

  /// "Effect on PKO Personal (with 1 line)", "Effect on Revolut EUR in EUR" when foreign.
  public var effectLabel: String {
    guard let account else { return "Effect on the account" }
    var label = "Effect on \(account.name)"
    if isForeign { label += " in \(account.currency.rawValue)" }
    switch draft.lines.count {
    case 0: break
    case 1: label += " (with 1 line)"
    case let n: label += " (with \(n) lines)"
    }
    return label
  }

  // MARK: Validation

  public var issues: [EditorIssue] {
    var issues: [EditorIssue] = []
    if amountMinor == nil { issues.append(.amount) }
    if account == nil { issues.append(.account) }
    if isTransfer {
      if toAccount == nil { issues.append(.toAccount) }
      if sameAccounts { issues.append(.sameAccounts) }
      if crossCurrency, toAmountMinor == nil { issues.append(.receivedAmount) }
    } else {
      if isForeign, chargedMinor == nil { issues.append(.charged) }
      if effectiveCategoryID == nil { issues.append(.category) }
    }
    if let account {
      for line in draft.lines {
        let amount = positive(EditorAmount.minor(line.amountText, code: account.currency.rawValue))
        if amount == nil || reference.category(line.categoryID) == nil { issues.append(.line(line.id)) }
      }
    }
    return issues
  }

  public var canSave: Bool { isLoaded && !isWorking && issues.isEmpty }

  // MARK: Mapping

  /// The transaction and its attached records as they would be saved; nil while invalid.
  /// Amounts are positive minor units of the account currency (R-CUR-2); a foreign purchase
  /// keeps the typed amount as the original (R-CUR-4).
  public func makeTransaction() -> TxnWithLines? {
    guard isLoaded, issues.isEmpty, let account, let amountMinor else { return nil }
    let accountCode = account.currency.rawValue
    var txn =
      draft.stored
      ?? Txn(
        id: draft.id, type: draft.type, occurredAt: draft.occurredAt, accountID: account.id,
        amountMinor: amountMinor, source: .manual, createdAt: dependencies.now())
    txn.type = draft.type
    txn.occurredAt = draft.occurredAt
    txn.accountID = account.id
    txn.payee = draft.payee.trimmingCharacters(in: .whitespacesAndNewlines)
    txn.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    txn.eventID = effectiveEventID
    switch draft.type {
    case .transfer:
      txn.amountMinor = amountMinor
      txn.toAccountID = toAccount?.id
      txn.toAmountMinor = toAmountMinor
      txn.categoryID = nil
      txn.isRefund = false
      txn.originalAmountMinor = nil
      txn.originalCurrencyCode = nil
    case .expense, .income:
      txn.categoryID = effectiveCategoryID
      txn.toAccountID = nil
      txn.toAmountMinor = nil
      txn.isRefund = draft.isRefund
      if isForeign, let charged = chargedMinor {
        txn.amountMinor = charged
        txn.originalAmountMinor = amountMinor
        txn.originalCurrencyCode = draft.currencyCode
      } else {
        txn.amountMinor = amountMinor
        txn.originalAmountMinor = nil
        txn.originalCurrencyCode = nil
      }
    }
    let records = draft.lines.enumerated().map { index, line in
      let amount = positive(EditorAmount.minor(line.amountText, code: accountCode)) ?? 0
      let keepOriginal = line.stored?.amountMinor == amount
      return AttachedRecord(
        id: line.id, txnID: txn.id, kind: line.kind, categoryID: line.categoryID, amountMinor: amount,
        originalAmountMinor: keepOriginal ? line.stored?.originalAmountMinor : nil,
        originalCurrencyCode: keepOriginal ? line.stored?.originalCurrencyCode : nil,
        note: line.note.trimmingCharacters(in: .whitespacesAndNewlines), position: index)
    }
    return TxnWithLines(txn: txn, lines: records)
  }

  // MARK: Actions

  /// Saves (⏎). A new transaction also becomes the last-used defaults (R-EDIT-4/5); a used
  /// rule suggestion counts a hit (R-IMP-8). Returns nil when invalid or the save failed.
  @discardableResult
  public func save() async -> TransactionEditorResult? {
    guard canSave, let row = makeTransaction() else { return nil }
    let usedRule = suggestion.flatMap { row.txn.categoryID == $0.category.id ? $0.rule.id : nil }
    isWorking = true
    defer { isWorking = false }
    do {
      try await dependencies.transactions.save(row.txn, lines: row.lines)
    } catch {
      errorMessage = "Couldn't save the transaction."
      return nil
    }
    errorMessage = nil
    if isNew { await rememberDefaults(row.txn) }
    if let usedRule { try? await dependencies.rules.recordHit(usedRule) }
    return .saved(row.txn.id)
  }

  private func rememberDefaults(_ txn: Txn) async {
    let settings = dependencies.settings
    switch txn.type {
    case .transfer:
      try? await settings.set(.lastTransferFromID, txn.accountID.uuidString)
      if let to = txn.toAccountID { try? await settings.set(.lastTransferToID, to.uuidString) }
    case .expense, .income:
      try? await settings.set(.lastAccountID, txn.accountID.uuidString)
      if let code = txn.originalCurrencyCode ?? reference.account(txn.accountID)?.currency.rawValue {
        try? await settings.set(.lastTxnCurrency, code)
      }
    }
  }

  /// "Delete…" after confirmation (R-TX-7). Attached records go with it.
  @discardableResult
  public func delete() async -> TransactionEditorResult? {
    guard case .edit(let id) = mode else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      try await dependencies.transactions.delete(id)
      return .deleted(id)
    } catch {
      errorMessage = "Couldn't delete the transaction."
      return nil
    }
  }

  /// The confirmation text: "“Lidl” · −zł86.40 · 5 Oct 2026. …".
  public var deleteMessage: String {
    var parts: [String] = []
    let payee = draft.payee.trimmingCharacters(in: .whitespacesAndNewlines)
    if !payee.isEmpty { parts.append("“\(payee)”") }
    if let stored = draft.stored, let account = reference.account(stored.accountID) {
      let signed: Int64 =
        stored.type == .transfer
        ? -stored.amountMinor : (stored.type == .income) != stored.isRefund ? stored.amountMinor : -stored.amountMinor
      parts.append(moneyFormat.string(minor: signed, code: account.currency.rawValue, sign: .always))
      parts.append(stored.occurredAt.formatted(Self.dayFormat))
    }
    var message = parts.isEmpty ? "" : parts.joined(separator: " · ") + ". "
    message += draft.lines.isEmpty ? "This can't be undone." : "Its fees and split lines are deleted with it."
    if let stored = draft.stored, stored.source != .manual {
      message += " Importing the same file again would add it back."
    }
    return message
  }

  /// "Duplicate" (R-TX-7): the form becomes a new transaction with the same values, dated now,
  /// entered manually.
  public func duplicate() {
    guard case .edit = mode else { return }
    mode = .new
    draft.id = UUID()
    draft.stored = nil
    draft.occurredAt = dependencies.now()
    draft.eventChosen = true
    draft.lines = draft.lines.map { line in
      var copy = line
      copy.id = UUID()
      copy.stored = nil
      return copy
    }
    defaultsTouched = true
  }

  // MARK: Helpers

  private func positive(_ minor: Int64?) -> Int64? { minor.flatMap { $0 > 0 ? $0 : nil } }

  private func accountText(_ minor: Int64) -> String {
    EditorAmount.text(minor: minor, code: account?.currency.rawValue ?? draft.currencyCode)
  }

  static let dayFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
    .locale(Locale(identifier: "en_GB"))
}
