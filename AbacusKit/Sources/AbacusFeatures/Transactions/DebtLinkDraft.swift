import AbacusDomain
import Foundation

/// The "Debt record" sheet shared by the import wizard (R-DEBT-10) and "Convert to debt
/// record…" in the transaction list (R-DEBT-11), docs/status/C17.md: person (existing or a new
/// name), debt (the person's debts, or a new one in the account's currency), kind (suggested
/// from the money's direction and the debt's balance), the expense/income flag where C14 offers
/// it and — when the debt's currency is not the account's — the amount in the debt's currency,
/// pre-filled at the day's rate.
///
/// Pure value: no store, no rates lookups after it is made (`convertedAmounts` holds the day's
/// conversions).
public struct DebtLinkDraft: Equatable, Sendable {
  public enum DebtOption: Hashable, Sendable {
    case existing(Debt.ID)
    /// The person's debt in that currency, created on save.
    case new(Currency)
  }

  public struct DebtChoice: Identifiable, Hashable, Sendable {
    public var option: DebtOption
    /// "EUR · they owe you €120.00" / "New debt in PLN".
    public var label: String
    public var id: DebtOption { option }
  }

  /// "Lent to Ann": the transaction the record is made from.
  public let title: String
  /// "−200.00 PLN on PKO Personal · 12 Jan 2026".
  public let subtitle: String
  public let inflow: Bool
  public let accountCurrency: Currency
  /// The transaction's amount on its account (positive).
  public let accountAmountMinor: Int64
  /// Debts and records before this transaction.
  public let book: DebtBook
  /// Balance changes not in `book` yet (this import's earlier debt rows), by `key(…)`.
  public let pendingEffects: [String: Int64]
  /// The transaction's amount at the day's rate in other currencies (nil entries left out).
  public let convertedAmounts: [Currency: Int64]

  public var personName: String {
    didSet { if Debt.personKey(personName) != Debt.personKey(oldValue) { personChanged() } }
  }
  public var debt: DebtOption {
    didSet { if debt != oldValue { debtChanged() } }
  }
  public var kind: DebtRecordKind
  public var countsInReports: Bool
  /// The record's amount in the debt's currency (only when it differs from the account's).
  public var amountText: String

  let format: ManageFormat
  let money = TransactionMoneyFormat()

  public init(
    title: String, subtitle: String, inflow: Bool, accountCurrency: Currency, accountAmountMinor: Int64,
    book: DebtBook, pendingEffects: [String: Int64] = [:], convertedAmounts: [Currency: Int64] = [:],
    personName: String = "", debt: DebtOption? = nil, kind: DebtRecordKind? = nil, countsInReports: Bool = false,
    amountMinor: Int64? = nil, format: ManageFormat = ManageFormat()
  ) {
    self.title = title
    self.subtitle = subtitle
    self.inflow = inflow
    self.accountCurrency = accountCurrency
    self.accountAmountMinor = accountAmountMinor
    self.book = book
    self.pendingEffects = pendingEffects
    self.convertedAmounts = convertedAmounts
    self.format = format
    self.personName = personName
    self.debt = debt ?? .new(accountCurrency)
    self.kind = kind ?? .suggested(inflow: inflow, balance: 0)
    self.countsInReports = countsInReports
    self.amountText = ""
    if debt == nil { self.debt = defaultDebt }
    if kind == nil { self.kind = suggestedKind }
    amountText = amountMinor.map(format.amountInput) ?? prefilledAmount
  }

  public static func == (a: DebtLinkDraft, b: DebtLinkDraft) -> Bool {
    a.title == b.title && a.subtitle == b.subtitle && a.inflow == b.inflow && a.accountCurrency == b.accountCurrency
      && a.accountAmountMinor == b.accountAmountMinor && a.book == b.book && a.pendingEffects == b.pendingEffects
      && a.convertedAmounts == b.convertedAmounts && a.personName == b.personName && a.debt == b.debt
      && a.kind == b.kind && a.countsInReports == b.countsInReports && a.amountText == b.amountText
  }

  /// The balance key of a debt: its id, or person + currency for one not created yet.
  public static func key(person: String, currency: Currency, debtID: Debt.ID?) -> String {
    debtID.map(\.uuidString) ?? "new|\(Debt.personKey(person))|\(currency.rawValue)"
  }

  // MARK: Options

  /// Existing people A–Z (the name field also takes a new one).
  public var personOptions: [String] { book.personNames }

  public var trimmedPerson: String { personName.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The person's debts, plus "New debt in <account currency>" when they have none in it.
  public var debtChoices: [DebtChoice] {
    let debts = book.debts(person: trimmedPerson)
    var choices = debts.map { debt in
      DebtChoice(option: .existing(debt.id), label: label(debt))
    }
    if !debts.contains(where: { $0.currency == accountCurrency }) {
      choices.append(DebtChoice(option: .new(accountCurrency), label: "New debt in \(accountCurrency.rawValue)"))
    }
    if case .new(let currency) = debt, currency != accountCurrency {
      choices.append(DebtChoice(option: debt, label: "New debt in \(currency.rawValue)"))
    }
    return choices
  }

  private func label(_ debt: Debt) -> String {
    let balance = balance(debt.id, person: debt.personName, currency: debt.currency)
    let amount = money.string(minor: abs(balance), code: debt.currency.rawValue)
    let state: String =
      if balance > 0 { "owes you \(amount)" } else if balance < 0 { "you owe \(amount)" } else { "settled up" }
    return "\(debt.currency.rawValue) · \(state)" + (debt.isSettled ? " (settled)" : "")
  }

  public var kindOptions: [DebtRecordKind] { DebtRecordKind.linkable(inflow: inflow) }

  /// "Count as expense" / "Count as income", or nil when the kind offers no flag.
  public var flagTitle: String? {
    switch kind.offeredReportKind {
    case .expense: "Count as expense"
    case .income: "Count as income"
    case nil: nil
    }
  }

  public var debtCurrency: Currency {
    switch debt {
    case .existing(let id): book.debts.first { $0.id == id }?.currency ?? accountCurrency
    case .new(let currency): currency
    }
  }

  /// The amount field is shown only across currencies.
  public var needsAmount: Bool { debtCurrency != accountCurrency }

  /// "Amount in EUR (at the day's rate: 46.50)".
  public var amountCaption: String {
    var text = "Amount in \(debtCurrency.rawValue)"
    if let converted = convertedAmounts[debtCurrency] {
      text += " (at the day's rate: \(format.amountInput(converted)))"
    }
    return text
  }

  /// The record's amount in the debt's currency; nil while the field is empty or invalid.
  public var amountMinor: Int64? {
    guard needsAmount else { return accountAmountMinor }
    guard let value = format.parseAmount(amountText), value > 0 else { return nil }
    return value
  }

  public var validation: String? {
    if trimmedPerson.isEmpty { return "Enter the person's name." }
    if needsAmount, amountMinor == nil { return "Enter the amount in \(debtCurrency.rawValue)." }
    return nil
  }

  public var canSave: Bool { validation == nil }

  /// What the store does with it ("Convert to debt record").
  public var link: DebtLink? {
    guard canSave else { return nil }
    let debtID: Debt.ID? = if case .existing(let id) = debt { id } else { nil }
    return DebtLink(
      personName: trimmedPerson, debtID: debtID, currency: debtCurrency, kind: kind,
      amountMinor: needsAmount ? amountMinor : nil, countsInReports: countsInReports && flagTitle != nil)
  }

  /// The debt's balance before this transaction (positive = they owe me).
  public var balanceBefore: Int64 {
    let id: Debt.ID? = if case .existing(let id) = debt { id } else { nil }
    return balance(id, person: trimmedPerson, currency: debtCurrency)
  }

  private func balance(_ debtID: Debt.ID?, person: String, currency: Currency) -> Int64 {
    (debtID.map { book.balance(of: $0) } ?? 0) + (pendingEffects[Self.key(person: person, currency: currency, debtID: debtID)] ?? 0)
  }

  // MARK: Defaults

  /// The person's debt in the account's currency (an unsettled one first), else a new one.
  var defaultDebt: DebtOption {
    book.debt(person: trimmedPerson, currency: accountCurrency).map { .existing($0.id) } ?? .new(accountCurrency)
  }

  var suggestedKind: DebtRecordKind { .suggested(inflow: inflow, balance: balanceBefore) }

  var prefilledAmount: String {
    guard needsAmount, let converted = convertedAmounts[debtCurrency] else { return "" }
    return format.amountInput(converted)
  }

  private mutating func personChanged() {
    let fallback = defaultDebt
    if debt != fallback { debt = fallback } else { debtChanged() }
  }

  private mutating func debtChanged() {
    kind = suggestedKind
    if flagTitle == nil { countsInReports = false }
    amountText = prefilledAmount
  }
}
