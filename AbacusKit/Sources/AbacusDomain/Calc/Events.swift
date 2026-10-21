import Foundation

/// What an event cost (R-EVT-3).
public struct EventTotals: Hashable, Sendable {
  public let eventID: Event.ID
  /// The display currency.
  public let currency: Currency
  /// Expenses of the event's transactions (attached expense records included, refunds by the
  /// setting), each at its day's rate.
  public let spent: Money
  /// The same expenses by top-level category with subcategories (R-EVT-4, R-CAT-2).
  public let byCategory: [CategoryTotal]
  /// Transactions tagged with the event.
  public let txnCount: Int
  /// The event's optional budget, in its own currency.
  public let budget: Money?
  /// Spent converted to the budget's currency (each amount at its day's rate); nil without a budget.
  public let spentInBudgetCurrency: Money?
  public let budgetStatus: LimitStatus?
  /// Amounts left out of `spent` (or of `spentInBudgetCurrency`).
  public let unconverted: Unconverted
}

extension Calc {
  /// Totals of `event` in `currency` (R-EVT-3). `txns` may be every transaction: only those
  /// with `eventID == event.id` count; their attached records belong to the event too.
  public static func eventTotals(
    event: Event, accounts: [Account], categories: [Category], txns: [TxnWithLines],
    currency: Currency, converter: some CurrencyConverter, refundsReduceSpending: Bool,
    calendar: Calendar = .current
  ) -> EventTotals {
    let tagged = txns.filter { $0.txn.eventID == event.id }
    var gaps = Unconverted()
    let tree = CategoryTree(categories)
    let entries = convertedEntries(
      tagged, accounts: accounts, categories: tree, currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, calendar: calendar, gaps: &gaps)
    let breakdown = breakdown(entries, kind: .expense, currency: currency, tree: tree, unconverted: gaps)

    var budget: Money?
    var spentInBudgetCurrency: Money?
    var status: LimitStatus?
    if let limit = event.budgetMinor {
      let budgetCurrency = event.budgetCurrency ?? currency
      budget = Money(minorUnits: limit, currency: budgetCurrency)
      let inBudget: [ReportEntry]
      if budgetCurrency == currency {
        inBudget = entries
      } else {
        inBudget = convertedEntries(
          tagged, accounts: accounts, categories: tree, currency: budgetCurrency, converter: converter,
          refundsReduceSpending: refundsReduceSpending, calendar: calendar, gaps: &gaps)
      }
      let spent = inBudget.filter { $0.kind == .expense }.reduce(Int64(0)) { $0 + $1.amount.minorUnits }
      spentInBudgetCurrency = Money(minorUnits: spent, currency: budgetCurrency)
      status = limitStatus(spentMinor: spent, limitMinor: limit)
    }

    return EventTotals(
      eventID: event.id, currency: currency, spent: breakdown.total, byCategory: breakdown.items,
      txnCount: tagged.count, budget: budget, spentInBudgetCurrency: spentInBudgetCurrency,
      budgetStatus: status, unconverted: gaps)
  }
}
