import AbacusDomain
import Foundation

/// The "Transfer to debt account" sheet shared by the import wizard (R-DEBT-10) and "Transfer to
/// debt account…" in the transaction list (R-DEBT-11, R-DEBT-19), docs/status/C22.md: the person
/// (an existing name or a new one), the person's account the money goes to or comes from (a
/// linked account of their debt, or a new virtual account) and, when that account's currency is
/// not the transaction's, the amount on the person's side, pre-filled at the day's rate.
///
/// Pure value: no store, no rates lookups after it is made (`convertedAmounts` holds the day's
/// conversions).
public struct DebtLinkDraft: Equatable, Sendable {
  /// The person's account.
  public enum AccountOption: Hashable, Sendable {
    /// A linked account of the person's debt (external or virtual).
    case existing(Account.ID)
    /// A virtual account in `newAccountCurrency`, created on save when the debt has none.
    case newVirtual
  }

  public struct AccountChoice: Identifiable, Hashable, Sendable {
    public var option: AccountOption
    /// "Anna (PLN) · virtual" / "New virtual account".
    public var label: String
    public var id: AccountOption { option }
  }

  /// "Transfer “ANNA NOWAK” to a debt account": the transaction the transfer is made from.
  public let title: String
  /// "−200.00 PLN on PKO Personal · 12 Jan 2026".
  public let subtitle: String
  public let inflow: Bool
  public let accountCurrency: Currency
  /// The transaction's amount on its account (positive).
  public let accountAmountMinor: Int64
  /// Debts and their accounts before this transaction.
  public let book: DebtBook
  /// The transaction's amount at the day's rate in other currencies (nil entries left out).
  public let convertedAmounts: [Currency: Int64]

  public var personName: String {
    didSet { if Debt.personKey(personName) != Debt.personKey(oldValue) { personChanged() } }
  }
  public var account: AccountOption {
    didSet { if account != oldValue { accountChanged() } }
  }
  /// The currency of the virtual account to create (only with `.newVirtual`).
  public var newAccountCurrency: Currency {
    didSet { if newAccountCurrency != oldValue { accountChanged() } }
  }
  /// The amount on the person's side (only when its currency differs from the transaction's).
  public var amountText: String

  let format: ManageFormat
  let money = TransactionMoneyFormat()

  public init(
    title: String, subtitle: String, inflow: Bool, accountCurrency: Currency, accountAmountMinor: Int64,
    book: DebtBook, convertedAmounts: [Currency: Int64] = [:], personName: String = "",
    account: AccountOption? = nil, newAccountCurrency: Currency? = nil, amountMinor: Int64? = nil,
    format: ManageFormat = ManageFormat()
  ) {
    self.title = title
    self.subtitle = subtitle
    self.inflow = inflow
    self.accountCurrency = accountCurrency
    self.accountAmountMinor = accountAmountMinor
    self.book = book
    self.convertedAmounts = convertedAmounts
    self.format = format
    self.personName = personName
    self.account = .newVirtual
    self.newAccountCurrency = newAccountCurrency ?? accountCurrency
    self.amountText = ""
    if let account {
      self.account = account
    } else {
      self.account = defaultAccount
    }
    amountText = amountMinor.map(format.amountInput) ?? prefilledAmount
  }

  public static func == (a: DebtLinkDraft, b: DebtLinkDraft) -> Bool {
    a.title == b.title && a.subtitle == b.subtitle && a.inflow == b.inflow && a.accountCurrency == b.accountCurrency
      && a.accountAmountMinor == b.accountAmountMinor && a.book == b.book && a.convertedAmounts == b.convertedAmounts
      && a.personName == b.personName && a.account == b.account && a.newAccountCurrency == b.newAccountCurrency
      && a.amountText == b.amountText
  }

  // MARK: Options

  /// Existing people A–Z, narrowed by what is typed (R-DEBT-16 autocomplete); the field also
  /// takes a new name.
  public var personOptions: [String] { book.personNames(matching: personName) }

  public var trimmedPerson: String { personName.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The person's debt, when they have one (R-DEBT-16: one per person).
  public var debt: Debt? { book.debt(person: trimmedPerson) }

  /// "Creates the debt" for a new person.
  public var createsDebt: Bool { !trimmedPerson.isEmpty && debt == nil }

  /// The person's linked accounts, virtual first, then "New virtual account".
  public var accountChoices: [AccountChoice] {
    var choices: [AccountChoice] = []
    if let debt {
      let accounts = book.accounts(of: debt.id)
      let roles = Dictionary(uniqueKeysWithValues: book.links(of: debt.id).map { ($0.accountID, $0.role) })
      for account in accounts.sorted(by: { (roles[$0.id] == .virtual ? 0 : 1, $0.name) < (roles[$1.id] == .virtual ? 0 : 1, $1.name) }) {
        let role = roles[account.id] == .external ? "their account" : "virtual"
        let code = account.currency.rawValue
        let name = account.name.contains("(\(code))") ? account.name : "\(account.name) (\(code))"
        choices.append(AccountChoice(option: .existing(account.id), label: "\(name) · \(role)"))
      }
    }
    choices.append(AccountChoice(option: .newVirtual, label: "New virtual account"))
    return choices
  }

  /// The currency of the person's side.
  public var personCurrency: Currency {
    switch account {
    case .existing(let id): book.accounts.first { $0.id == id }?.currency ?? accountCurrency
    case .newVirtual: newAccountCurrency
    }
  }

  /// The currency picker is shown for a new virtual account.
  public var choosesCurrency: Bool { account == .newVirtual }

  /// The amount field is shown only across currencies.
  public var needsAmount: Bool { personCurrency != accountCurrency }

  /// "Amount in EUR (at the day's rate: 46.50)".
  public var amountCaption: String {
    var text = "Amount in \(personCurrency.rawValue)"
    if let converted = convertedAmounts[personCurrency] {
      text += " (at the day's rate: \(format.amountInput(converted)))"
    }
    return text
  }

  /// The amount on the person's side; nil while the field is empty or invalid.
  public var amountMinor: Int64? {
    guard needsAmount else { return accountAmountMinor }
    guard let value = format.parseAmount(amountText), value > 0 else { return nil }
    return value
  }

  public var validation: String? {
    if trimmedPerson.isEmpty { return "Enter the person's name." }
    if needsAmount, amountMinor == nil { return "Enter the amount in \(personCurrency.rawValue)." }
    return nil
  }

  public var canSave: Bool { validation == nil }

  /// What the store does with it (`transferToDebt`).
  public var link: DebtLink? {
    guard canSave else { return nil }
    let accountID: Account.ID? = if case .existing(let id) = account { id } else { nil }
    return DebtLink(
      personName: trimmedPerson, debtID: debt?.id, accountID: accountID, currency: personCurrency,
      amountMinor: needsAmount ? amountMinor : nil)
  }

  // MARK: Defaults

  /// The debt's virtual account in the transaction's currency, else a new virtual account.
  var defaultAccount: AccountOption {
    guard let debt, let match = Self.virtualAccount(in: book, debtID: debt.id, currency: accountCurrency) else {
      return .newVirtual
    }
    return .existing(match.id)
  }

  /// The debt's virtual account in `currency`, if it has one.
  public static func virtualAccount(in book: DebtBook, debtID: Debt.ID, currency: Currency) -> Account? {
    let virtual = Set(book.links(of: debtID).filter { $0.role == .virtual }.map(\.accountID))
    return book.accounts(of: debtID).first { virtual.contains($0.id) && $0.currency == currency }
  }

  var prefilledAmount: String {
    guard needsAmount, let converted = convertedAmounts[personCurrency] else { return "" }
    return format.amountInput(converted)
  }

  private mutating func personChanged() {
    newAccountCurrency = accountCurrency
    let fallback = defaultAccount
    if account != fallback { account = fallback } else { accountChanged() }
  }

  private mutating func accountChanged() {
    amountText = prefilledAmount
  }
}
