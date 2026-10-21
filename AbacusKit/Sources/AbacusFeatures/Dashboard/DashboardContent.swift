import AbacusDomain
import Foundation

// Presentation values of the three dashboard widgets (R-HOME-1…5), built by pure functions over
// the A1 calculators. Everything here is display-ready: amounts already in the display currency,
// texts already formatted. Amounts without a rate are never converted at 1: they are left out
// and reported in `DashboardMissingRates` (D27, R-FX-4).

// MARK: - Rates

/// The rates the dashboard converts with, and whether the last fetch failed (R-FX-4).
public struct DashboardRates: Sendable {
  public var converter: any CurrencyConverter
  /// The last fetch failed: amounts use the last known rates (amber warning).
  public var fetchFailed: Bool

  public init(converter: any CurrencyConverter, fetchFailed: Bool = false) {
    self.converter = converter
    self.fetchFailed = fetchFailed
  }

  /// "Rates as of <day>" (R-FX-4).
  public var asOf: Day? { converter.latestDay }
}

// MARK: - Missing rates

/// Amounts left out of the dashboard's figures because no rate was known (D27). Built from the
/// calculators' `Unconverted` and the dashboard's own display conversions.
public struct DashboardMissingRates: Hashable, Sendable {
  public private(set) var count = 0
  public private(set) var rates: Set<MissingRate> = []
  public private(set) var unknownAccounts: Set<Account.ID> = []

  public init() {}

  public var isEmpty: Bool { count == 0 }

  /// Days whose rates are missing (for a lazy fetch, R-FX-1); the latest rate has no day.
  public var days: Set<Day> { Set(rates.compactMap(\.day)) }

  mutating func add(_ unconverted: Unconverted) {
    count += unconverted.count
    rates.formUnion(unconverted.missingRates)
    unknownAccounts.formUnion(unconverted.unknownAccountIDs)
  }

  mutating func add(_ missing: MissingRate) {
    count += 1
    rates.insert(missing)
  }

  mutating func merge(_ other: DashboardMissingRates) {
    count += other.count
    rates.formUnion(other.rates)
    unknownAccounts.formUnion(other.unknownAccounts)
  }

  /// "3 amounts are left out: no rate for EUR→UAH, USD→UAH on 31 Jan 2026 – 31 Aug 2026."
  public func text(_ format: DashboardFormat) -> String? {
    guard !isEmpty else { return nil }
    let lead = count == 1 ? "1 amount is left out" : "\(count) amounts are left out"
    var parts: [String] = []
    let pairs = Set(rates.map { "\($0.from.rawValue)→\($0.to.rawValue)" }).sorted()
    if !pairs.isEmpty {
      var text = "no rate for " + pairs.joined(separator: ", ")
      let days = days.sorted()
      if let first = days.first, let last = days.last {
        text += first == last ? " on \(format.day(first))" : " on \(format.day(first)) – \(format.day(last))"
        if rates.contains(where: { $0.day == nil }) { text += " and today" }
      } else {
        text += " today"
      }
      parts.append(text)
    }
    if !unknownAccounts.isEmpty { parts.append("unknown account") }
    return lead + ": " + parts.joined(separator: "; ") + "."
  }
}

// MARK: - Net worth (R-HOME-1)

public struct DashboardNetWorth: Sendable {
  public struct Point: Hashable, Sendable, Identifiable {
    public let day: Day
    public let isToday: Bool
    /// nil when a non-zero balance had no rate: the point is left off the chart.
    public let value: Money?
    /// "Oct".
    public let axisLabel: String
    /// "September 2026: ₴812,400 · at month end" / "October 2026: ₴830,120 · today".
    public let detail: String

    public var id: Day { day }
  }

  public struct AccountRow: Hashable, Sendable, Identifiable {
    public let id: Account.ID
    public let name: String
    /// "Card", "Credit card", …
    public let kind: String
    public let isLiability: Bool
    /// In the account's currency.
    public let balance: Money
    /// In the display currency; nil without a rate.
    public let converted: Money?
    public let balanceText: String
    /// "—" without a rate.
    public let convertedText: String
  }

  public let currency: Currency
  /// Today's net worth: the headline. Partial when `isComplete` is false.
  public let total: Money
  public let isComplete: Bool
  public let assets: Money
  /// Owed, positive while in debt.
  public let liabilities: Money
  /// Today − the previous month end; nil when either point is incomplete.
  public let change: Money?
  public let changeFraction: Decimal?
  public let points: [Point]
  public let accounts: [AccountRow]
  public let missing: DashboardMissingRates

  public let totalText: String
  public let assetsText: String
  public let liabilitiesText: String
  /// "+₴18,240 (+2.2%) since end of September"; nil without a change.
  public let changeText: String?
  /// "Net worth at the end of each month, November 2025 to October 2026".
  public let chartLabel: String

  /// The plotted points: the ones with a value.
  public var plotted: [Point] { points.filter { $0.value != nil } }

  /// y-axis range with the prototype's padding (15 % below, 10 % above); nil without values.
  public var valueRange: ClosedRange<Decimal>? {
    let values = plotted.compactMap(\.value?.decimal)
    guard let low = values.min(), let high = values.max() else { return nil }
    let spread = high - low
    if spread == 0 {
      let pad = max(abs(low) / 10, 1)
      return (low - pad)...(high + pad)
    }
    return (low - spread * Decimal(string: "0.15")!)...(high + spread / 10)
  }

  static func make(
    accounts: [Account], txns: [TxnWithLines], currency: Currency, converter: any CurrencyConverter,
    today: Day, format: DashboardFormat
  ) -> DashboardNetWorth {
    let calendar = format.calendar
    let series = Calc.netWorthSeries(
      accounts: accounts, txns: txns, currency: currency, converter: converter, today: today, calendar: calendar)
    var missing = DashboardMissingRates()

    // A balance of zero needs no rate: only non-zero balances without one make a point
    // incomplete (the calculator counts zero balances too; see docs/status/B2.md).
    func gaps(_ point: NetWorthPoint) -> [MissingRate] {
      point.netWorth.accounts.compactMap { value in
        guard value.converted == nil, value.balance.minorUnits != 0 else { return nil }
        return MissingRate(from: value.balance.currency, to: currency, day: point.isToday ? nil : point.day)
      }
    }

    let points = series.points.map { point -> Point in
      let pointGaps = gaps(point)
      pointGaps.forEach { missing.add($0) }
      let value = pointGaps.isEmpty ? point.value : nil
      let label = format.month(point.day.yearMonth)
      let detail: String
      if let value {
        detail = "\(label): \(format.money(value))" + (point.isToday ? " · today" : " · at month end")
      } else {
        detail = "\(label): not shown, exchange rates missing"
      }
      return Point(
        day: point.day, isToday: point.isToday, value: value, axisLabel: format.shortMonth(point.day.yearMonth),
        detail: detail)
    }

    let now = series.today?.netWorth
    let total = now?.total ?? .zero(currency)
    let isComplete = points.last?.value != nil

    var change: Money?
    var fraction: Decimal?
    var changeText: String?
    if points.count >= 2, let current = points[points.count - 1].value, let previous = points[points.count - 2].value {
      let delta = current - previous
      change = delta
      if previous.minorUnits != 0 {
        fraction = Decimal(delta.minorUnits) / Decimal(abs(previous.minorUnits))
      }
      let percent = fraction.map { " (\(format.signedPercent($0)))" } ?? ""
      changeText =
        "\(format.signed(delta))\(percent) since end of \(format.monthName(points[points.count - 2].day.yearMonth))"
    }

    let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let rows = (now?.accounts ?? []).compactMap { value -> AccountRow? in
      guard let account = byID[value.accountID] else { return nil }
      return AccountRow(
        id: account.id, name: account.name, kind: kindLabel(account.kind), isLiability: value.isLiability,
        balance: value.balance, converted: value.converted, balanceText: format.money(value.balance),
        convertedText: value.converted.map(format.money) ?? "—")
    }

    let first = series.points.first.map { format.month($0.day.yearMonth) } ?? ""
    let last = series.points.last.map { format.month($0.day.yearMonth) } ?? ""
    let assets = now?.assets ?? .zero(currency)
    let liabilities = now?.liabilities ?? .zero(currency)
    return DashboardNetWorth(
      currency: currency, total: total, isComplete: isComplete, assets: assets, liabilities: liabilities,
      change: change, changeFraction: fraction, points: points, accounts: rows, missing: missing,
      totalText: format.money(total), assetsText: format.money(assets), liabilitiesText: format.owed(liabilities),
      changeText: changeText, chartLabel: "Net worth at the end of each month, \(first) to \(last)")
  }

  static func kindLabel(_ kind: AccountKind) -> String {
    switch kind {
    case .cash: "Cash"
    case .bank: "Bank account"
    case .card: "Card"
    case .savings: "Savings"
    case .investment: "Investment"
    case .creditCard: "Credit card"
    case .loan: "Loan"
    case .debt: "Debt"
    }
  }
}

// MARK: - Budget (R-HOME-2, R-BUD-1…3)

public struct DashboardBudget: Sendable {
  public struct Row: Hashable, Sendable, Identifiable {
    public let id: String
    /// nil for "Unallocated (other categories)".
    public let categoryID: AbacusDomain.Category.ID?
    public let name: String
    public let spent: Money
    public let limit: Money
    public let status: LimitStatus
    /// 0…1 for the bar (full when over).
    public let barFraction: Double
    /// "₴2,040 / ₴1,800".
    public let amountsText: String
    /// "Over by ₴240" / "₴560 left".
    public let noteText: String

    public var isUnallocated: Bool { categoryID == nil }
  }

  public let month: Month
  /// The plan's currency: status (ok / near / over) is decided in it (R-BUD-2).
  public let planCurrency: Currency
  /// The currency the amounts are shown in: the display currency, or the plan's when no rate.
  public let shownCurrency: Currency
  public let spent: Money
  public let limit: Money
  public let status: LimitStatus
  public let barFraction: Double
  /// Category rows over their limit, unallocated included.
  public let overCount: Int
  public let daysLeft: Int
  /// Allocations in category order, then the unallocated row.
  public let rows: [Row]
  public let missing: DashboardMissingRates

  public let spentText: String
  /// "of ₴101,700".
  public let limitText: String
  /// "₴37,820 left · 63% used" / "Over budget by ₴11,300 · 112% used".
  public let remainingText: String
  /// "On track" / "1 category over" / "3 categories over".
  public let badgeText: String
  /// "Budget in PLN, shown in UAH at the rate of 30 Sep 2026"; nil when the currencies match.
  public let currencyNote: String?

  /// nil when no plan is in effect for `month`.
  static func make(
    month: Month, plan: BudgetPlan?, allocations: [BudgetAllocation], accounts: [Account],
    categories: [AbacusDomain.Category], txns: [TxnWithLines], displayCurrency: Currency,
    converter: any CurrencyConverter, refundsReduceSpending: Bool, today: Day, format: DashboardFormat
  ) -> DashboardBudget? {
    guard let plan,
      let status = Calc.budgetStatus(
        month: month, plans: [plan], allocations: allocations, accounts: accounts, categories: categories,
        txns: txns, converter: converter, refundsReduceSpending: refundsReduceSpending, today: today,
        calendar: format.calendar)
    else { return nil }

    var missing = DashboardMissingRates()
    missing.add(status.unconverted)

    // Shown in the display currency at one rate: the latest for the current month, the month's
    // last day for a closed one. Without that rate everything stays in the plan's currency.
    let rateDay: Day? = month >= today.yearMonth ? nil : month.lastDay(calendar: format.calendar)
    let rate: Decimal?
    if plan.currency == displayCurrency {
      rate = 1
    } else if let rateDay {
      rate = converter.rate(from: plan.currency, to: displayCurrency, on: rateDay)
    } else {
      rate = converter.latestRate(from: plan.currency, to: displayCurrency)
    }
    let shown = rate == nil ? plan.currency : displayCurrency
    func show(_ money: Money) -> Money {
      guard let rate, money.currency != shown else { return money }
      return Money(money.decimal * rate, shown)
    }
    var currencyNote: String?
    if plan.currency != displayCurrency {
      if rate == nil {
        missing.add(MissingRate(from: plan.currency, to: displayCurrency, day: rateDay))
        currencyNote = "No \(plan.currency.rawValue)→\(displayCurrency.rawValue) rate: amounts in \(plan.currency.rawValue)"
      } else if let rateDay {
        currencyNote = "Budget in \(plan.currency.rawValue), shown in \(displayCurrency.rawValue) at the rate of \(format.day(rateDay))"
      } else {
        currencyNote = "Budget in \(plan.currency.rawValue), shown in \(displayCurrency.rawValue) at the latest rate"
      }
    }

    let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    func row(_ line: BudgetLine) -> Row {
      let spent = show(line.spent)
      let limit = show(line.limit)
      let note =
        line.status == .over
        ? "Over by \(format.magnitude(show(line.spent - line.limit)))"
        : "\(format.money(show(line.remaining))) left"
      return Row(
        id: line.id, categoryID: line.categoryID,
        name: line.categoryID.map { names[$0] ?? "Unknown category" } ?? "Unallocated (other categories)",
        spent: spent, limit: limit, status: line.status,
        barFraction: barFraction(spent: line.spent, limit: line.limit),
        amountsText: "\(format.money(spent)) / \(format.money(limit))", noteText: note)
    }

    let spent = show(status.spent)
    let limit = show(status.limit)
    let used = status.fractionUsed.map { " · \(format.percent($0)) used" } ?? ""
    let remaining = status.remaining
    let remainingText =
      remaining.minorUnits >= 0
      ? "\(format.money(show(remaining))) left\(used)"
      : "Over budget by \(format.magnitude(show(remaining)))\(used)"
    let over = status.overCount
    let badge = over == 0 ? "On track" : over == 1 ? "1 category over" : "\(over) categories over"

    return DashboardBudget(
      month: month, planCurrency: plan.currency, shownCurrency: shown, spent: spent, limit: limit,
      status: status.status, barFraction: barFraction(spent: status.spent, limit: status.limit), overCount: over,
      daysLeft: status.daysLeft, rows: status.lines.map(row) + [row(status.unallocated)], missing: missing,
      spentText: format.money(spent), limitText: "of \(format.money(limit))", remainingText: remainingText,
      badgeText: badge, currencyNote: currencyNote)
  }

  static func barFraction(spent: Money, limit: Money) -> Double {
    guard let fraction = Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) else {
      return spent.minorUnits > 0 ? 1 : 0
    }
    return min(1, max(0, NSDecimalNumber(decimal: fraction).doubleValue))
  }
}

// MARK: - Expenses donut (R-HOME-3)

public struct DashboardExpenses: Sendable {
  public struct Slice: Hashable, Sendable, Identifiable {
    public let id: CategoryKey
    /// nil for "Uncategorized" (no drill-down target).
    public let categoryID: AbacusDomain.Category.ID?
    public let name: String
    /// "#RRGGBB".
    public let colorHex: String
    public let amount: Money
    /// Of the month's total (1 = 100 %).
    public let share: Decimal?
    public let amountText: String
    /// "38%".
    public let percentText: String
    /// Subcategories with spending, largest first (R-HOME-3 "expandable to subcategories").
    public let children: [Slice]
  }

  public let month: Month
  public let total: Money
  public let totalText: String
  /// Top-level categories with positive spending, largest first.
  public let slices: [Slice]
  public let missing: DashboardMissingRates
  /// "Expenses by category, October 2026".
  public let chartLabel: String

  public var isEmpty: Bool { slices.isEmpty }

  public static let uncategorizedColor = "#9A9AA0"

  static func make(
    month: Month, accounts: [Account], categories: [AbacusDomain.Category], txns: [TxnWithLines],
    currency: Currency, converter: any CurrencyConverter, refundsReduceSpending: Bool, format: DashboardFormat
  ) -> DashboardExpenses {
    let breakdown = Calc.expensesByCategory(
      month: month, accounts: accounts, categories: categories, txns: txns, currency: currency,
      converter: converter, refundsReduceSpending: refundsReduceSpending, calendar: format.calendar)
    let tree = CategoryTree(categories)
    func slice(_ item: CategoryTotal, parentColor: String?) -> Slice {
      let category: AbacusDomain.Category? =
        if case .category(let id) = item.key { tree.category(id) } else { nil }
      let color = category?.colorHex ?? parentColor ?? uncategorizedColor
      let name =
        switch item.key {
        case .category: category?.name ?? "Unknown category"
        case .uncategorized: "Uncategorized"
        case .refunds: "Refunds"
        }
      return Slice(
        id: item.key, categoryID: category?.id, name: name, colorHex: color, amount: item.total, share: item.share,
        amountText: format.money(item.total), percentText: item.share.map(format.percent) ?? "—",
        children: item.children.filter { $0.total.minorUnits > 0 }.map { slice($0, parentColor: color) })
    }
    var missing = DashboardMissingRates()
    missing.add(breakdown.unconverted)
    return DashboardExpenses(
      month: month, total: breakdown.total, totalText: format.money(breakdown.total),
      slices: breakdown.items.filter { $0.total.minorUnits > 0 }.map { slice($0, parentColor: nil) },
      missing: missing, chartLabel: "Expenses by category, \(format.month(month))")
  }
}
