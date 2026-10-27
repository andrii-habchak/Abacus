import AbacusDomain
import Foundation

/// Income vs expenses (R-HOME-6): the twelve months ending at the selected month, a pair of bars
/// per month and the net, in the display currency with each amount at its day's rate — the same
/// totals as the month's donuts (`Calc.incomeExpenseSeries`).
public struct DashboardIncomeExpenses: Sendable {
  public struct Bar: Hashable, Sendable, Identifiable {
    public let month: Month
    public let income: Money
    public let expense: Money
    /// income − expense.
    public let net: Money
    /// The month the selector shows.
    public let isSelected: Bool
    /// "Oct".
    public let axisLabel: String
    /// "October 2026".
    public let title: String
    public let incomeText: String
    public let expenseText: String
    /// "+₴12,400" / "−₴3,100".
    public let netText: String

    public var id: Month { month }
  }

  public let currency: Currency
  /// The selected month (the last bar).
  public let month: Month
  /// Oldest first, twelve of them.
  public let bars: [Bar]
  public let income: Money
  public let expense: Money
  public let missing: DashboardMissingRates

  public let incomeText: String
  public let expenseText: String
  /// "+₴40,200" over the twelve months.
  public let netText: String
  /// "November 2025 – October 2026".
  public let rangeText: String
  /// "Income and expenses by month, November 2025 to October 2026".
  public let chartLabel: String

  public var net: Money { income - expense }
  /// No income and no expenses in any of the months.
  public var isEmpty: Bool { bars.allSatisfy { $0.income.minorUnits == 0 && $0.expense.minorUnits == 0 } }

  public static let monthCount = 12

  static func make(
    month: Month, accounts: [Account], categories: [AbacusDomain.Category], txns: [TxnWithLines],
    currency: Currency, converter: any CurrencyConverter, refundsReduceSpending: Bool, format: DashboardFormat
  ) -> DashboardIncomeExpenses {
    let series = Calc.incomeExpenseSeries(
      endingAt: month, count: monthCount, accounts: accounts, categories: categories, txns: txns,
      currency: currency, converter: converter, refundsReduceSpending: refundsReduceSpending,
      calendar: format.calendar)
    var missing = DashboardMissingRates()
    missing.add(series.unconverted)
    let bars = series.months.map { item in
      Bar(
        month: item.month, income: item.income, expense: item.expense, net: item.net,
        isSelected: item.month == month, axisLabel: format.shortMonth(item.month), title: format.month(item.month),
        incomeText: format.money(item.income), expenseText: format.money(item.expense),
        netText: format.signed(item.net))
    }
    let income = Money(minorUnits: series.months.reduce(0) { $0 + $1.income.minorUnits }, currency: currency)
    let expense = Money(minorUnits: series.months.reduce(0) { $0 + $1.expense.minorUnits }, currency: currency)
    let first = series.months.first.map { format.month($0.month) } ?? ""
    let last = format.month(month)
    return DashboardIncomeExpenses(
      currency: currency, month: month, bars: bars, income: income, expense: expense, missing: missing,
      incomeText: format.money(income), expenseText: format.money(expense), netText: format.signed(income - expense),
      rangeText: "\(first) – \(last)", chartLabel: "Income and expenses by month, \(first) to \(last)")
  }
}
