import AbacusDomain
import Foundation

/// Money text of the transaction list: narrow symbol, two decimals, a real minus sign
/// ("−zł23.40", "+₴440.00", "€10.00").
public struct TransactionMoneyFormat: Sendable {
  public enum Sign: Sendable {
    /// No sign: footer income / expenses, original amounts.
    case none
    /// "+" or "−" (U+2212); zero is "+".
    case always
  }

  public var locale: Locale

  public init(locale: Locale = Locale(identifier: "en_US")) {
    self.locale = locale
  }

  /// `minor` units of `code` (any ISO 4217 code, R-CUR-4).
  public func string(minor: Int64, code: String, sign: Sign = .none) -> String {
    let digits = CurrencyDigits.minorUnits(code)
    var value = Decimal(minor.magnitude)
    for _ in 0..<digits { value /= 10 }
    let text = value.formatted(
      .currency(code: code).presentation(.narrow).precision(.fractionLength(digits)).locale(locale))
    switch sign {
    case .none: return minor < 0 ? "−" + text : text
    case .always: return (minor < 0 ? "−" : "+") + text
    }
  }

  public func string(_ money: Money, sign: Sign = .none) -> String {
    string(minor: money.minorUnits, code: money.currency.rawValue, sign: sign)
  }
}

/// How one transaction counts in the list totals (R-LIST-5), in its account currency.
///
/// - Expense → expense; income → income; transfers count as neither (R-TX-5).
/// - Expense refund (R-TX-4, R-SET-3): income ("Refunds") by default; with "refunds reduce
///   spending" on it is subtracted from expenses instead. An income reversal subtracts from
///   income.
/// - Attached records count by their own kind (R-TX-6); an `.income` record in an expense
///   category is a refund line and follows the refund rule (D22).
/// - With a category filter only the matching parts count: the main amount when its category
///   matches (or it has none and "Uncategorised" is ticked), each attached record whose
///   category matches.
public struct TransactionTotalsRule: Sendable {
  public var refundsReduceSpending: Bool
  /// Expanded category filter (parents with their children), or nil for "any".
  public var categoryFilter: Set<AbacusDomain.Category.ID>?
  /// "Uncategorised" ticked: a main amount without a category matches (the filter is on even
  /// when `categoryFilter` is nil).
  public var includeUncategorised: Bool
  public var categoryKinds: [AbacusDomain.Category.ID: CategoryKind]

  public init(
    refundsReduceSpending: Bool = false, categoryFilter: Set<AbacusDomain.Category.ID>? = nil,
    categoryKinds: [AbacusDomain.Category.ID: CategoryKind] = [:], includeUncategorised: Bool = false
  ) {
    self.refundsReduceSpending = refundsReduceSpending
    self.categoryFilter = categoryFilter
    self.includeUncategorised = includeUncategorised
    self.categoryKinds = categoryKinds
  }

  /// Income and expense parts in minor units of the account currency (either may be negative
  /// after refunds and reversals).
  public func parts(of row: TxnWithLines) -> (income: Int64, expense: Int64) {
    var income: Int64 = 0
    var expense: Int64 = 0
    let txn = row.txn
    let main = parts(type: txn.type, isRefund: txn.isRefund, categoryID: txn.categoryID, amountMinor: txn.amountMinor)
    income += main.income
    expense += main.expense
    for line in row.lines {
      let part = parts(lineKind: line.kind, categoryID: line.categoryID, amountMinor: line.amountMinor)
      income += part.income
      expense += part.expense
    }
    return (income, expense)
  }

  /// A transaction's main amount (also applied to the store's grouped flows, C28).
  public func parts(
    type: TxnType, isRefund: Bool, categoryID: AbacusDomain.Category.ID?, amountMinor: Int64
  ) -> (income: Int64, expense: Int64) {
    var income: Int64 = 0
    var expense: Int64 = 0
    if includeUncategorised && categoryID == nil || matches(categoryID) {
      switch (type, isRefund) {
      case (.expense, false): expense += amountMinor
      case (.expense, true): addRefund(amountMinor, &income, &expense)
      case (.income, false): income += amountMinor
      case (.income, true): income -= amountMinor
      case (.transfer, _): break
      }
    }
    return (income, expense)
  }

  /// An attached record's amount.
  public func parts(
    lineKind: CategoryKind, categoryID: AbacusDomain.Category.ID?, amountMinor: Int64
  ) -> (income: Int64, expense: Int64) {
    var income: Int64 = 0
    var expense: Int64 = 0
    guard matches(categoryID) else { return (0, 0) }
    switch lineKind {
    case .expense:
      expense += amountMinor
    case .income:
      if let category = categoryID, categoryKinds[category] == .expense {
        addRefund(amountMinor, &income, &expense)
      } else {
        income += amountMinor
      }
    }
    return (income, expense)
  }

  private func addRefund(_ amount: Int64, _ income: inout Int64, _ expense: inout Int64) {
    if refundsReduceSpending { expense -= amount } else { income += amount }
  }

  private func matches(_ id: AbacusDomain.Category.ID?) -> Bool {
    guard let categoryFilter else { return !includeUncategorised }
    return id.map(categoryFilter.contains) ?? false
  }
}
