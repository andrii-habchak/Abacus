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
///   matches, each attached record whose category matches.
public struct TransactionTotalsRule: Sendable {
  public var refundsReduceSpending: Bool
  /// Expanded category filter (parents with their children), or nil for "any".
  public var categoryFilter: Set<AbacusDomain.Category.ID>?
  public var categoryKinds: [AbacusDomain.Category.ID: CategoryKind]

  public init(
    refundsReduceSpending: Bool = false, categoryFilter: Set<AbacusDomain.Category.ID>? = nil,
    categoryKinds: [AbacusDomain.Category.ID: CategoryKind] = [:]
  ) {
    self.refundsReduceSpending = refundsReduceSpending
    self.categoryFilter = categoryFilter
    self.categoryKinds = categoryKinds
  }

  /// Income and expense parts in minor units of the account currency (either may be negative
  /// after refunds and reversals).
  public func parts(of row: TxnWithLines) -> (income: Int64, expense: Int64) {
    var income: Int64 = 0
    var expense: Int64 = 0
    let txn = row.txn
    if matches(txn.categoryID) {
      switch (txn.type, txn.isRefund) {
      case (.expense, false): expense += txn.amountMinor
      case (.expense, true): addRefund(txn.amountMinor, &income, &expense)
      case (.income, false): income += txn.amountMinor
      case (.income, true): income -= txn.amountMinor
      case (.transfer, _): break
      }
    }
    for line in row.lines where matches(line.categoryID) {
      switch line.kind {
      case .expense:
        expense += line.amountMinor
      case .income:
        if let category = line.categoryID, categoryKinds[category] == .expense {
          addRefund(line.amountMinor, &income, &expense)
        } else {
          income += line.amountMinor
        }
      }
    }
    return (income, expense)
  }

  private func addRefund(_ amount: Int64, _ income: inout Int64, _ expense: inout Int64) {
    if refundsReduceSpending { expense -= amount } else { income += amount }
  }

  private func matches(_ id: AbacusDomain.Category.ID?) -> Bool {
    guard let categoryFilter else { return true }
    return id.map(categoryFilter.contains) ?? false
  }
}
