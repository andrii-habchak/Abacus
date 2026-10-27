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
  /// Debts counted in net worth (R-DEBT-7): owed to me − I owe, in `currency`; nil without such
  /// debts. Already part of `assets` / `liabilities` and the total.
  public internal(set) var debtsTotal: Money?
  /// "+₴1,200"; nil without debts in net worth.
  public internal(set) var debtsText: String?

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
    today: Day, format: DashboardFormat, debts: DebtBook = .empty
  ) -> DashboardNetWorth {
    let calendar = format.calendar
    let series = Calc.netWorthSeries(
      accounts: accounts, txns: txns, currency: currency, converter: converter, today: today, debts: debts,
      calendar: calendar)
    var missing = DashboardMissingRates()

    // A balance of zero needs no rate: only non-zero balances without one make a point
    // incomplete (the calculator counts zero balances too; see docs/status/B2.md).
    func gaps(_ point: NetWorthPoint) -> [MissingRate] {
      let balances =
        point.netWorth.accounts.filter { $0.converted == nil }.map(\.balance)
        + point.netWorth.debts.filter { $0.converted == nil }.map(\.balance)
      return balances.compactMap { balance in
        guard balance.minorUnits != 0 else { return nil }
        return MissingRate(from: balance.currency, to: currency, day: point.isToday ? nil : point.day)
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
    var result = DashboardNetWorth(
      currency: currency, total: total, isComplete: isComplete, assets: assets, liabilities: liabilities,
      change: change, changeFraction: fraction, points: points, accounts: rows, missing: missing,
      totalText: format.money(total), assetsText: format.money(assets), liabilitiesText: format.owed(liabilities),
      changeText: changeText, chartLabel: "Net worth at the end of each month, \(first) to \(last)")
    // R-DEBT-7: debts counted in net worth, one separate line (already inside assets/liabilities).
    if let now, !now.debts.isEmpty {
      result.debtsTotal = now.debtsTotal
      result.debtsText = format.signed(now.debtsTotal)
    }
    return result
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

/// The month's budget for the dashboard (R-HOME-2, D43, D46): the headline in the display
/// currency; each category bar in its limit's own currency (the amounts the owner typed; the
/// status is decided in that currency, so switching the display currency never changes it);
/// with a total, the unallocated row and the total row in the total's own currency.
public struct DashboardBudget: Sendable {
  public struct Row: Hashable, Sendable, Identifiable {
    public let id: String
    /// nil for the unallocated and total rows.
    public let categoryID: AbacusDomain.Category.ID?
    public let name: String
    /// In the limit's currency.
    public let spent: Money
    /// In the limit's currency.
    public let limit: Money
    public let status: LimitStatus
    /// 0…1 for the bar (full when over).
    public let barFraction: Double
    /// "€320 / €400".
    public let amountsText: String
    /// "Over by €40" / "€80 left".
    public let noteText: String
  }

  public let month: Month
  /// The currency of the headline (the display currency; the total's when it has no rate).
  public let currency: Currency
  /// The total's spending in `currency` (without a total: the categories' spending).
  public let spent: Money
  /// The total in `currency` (without a total: the sum of the category limits).
  public let limit: Money
  /// The total's status, decided in the total's own currency (D46).
  public let status: LimitStatus
  public let barFraction: Double
  /// Category rows over their limit (and the unallocated row when it is over).
  public let overCount: Int
  public let daysLeft: Int
  /// Category limits in category order.
  public let rows: [Row]
  /// "Unallocated": total − limits, the spending no limit covers (total's currency); nil
  /// without a total.
  public let unallocated: Row?
  /// "Total": the total limit in its own currency; nil without a total.
  public let total: Row?
  public let missing: DashboardMissingRates

  public let spentText: String
  /// "of ₴101,700".
  public let limitText: String
  /// "₴37,820 left · 63% used" / "Over budget by ₴11,300 · 112% used".
  public let remainingText: String
  /// "On track" / "1 category over" / "3 categories over".
  public let badgeText: String
  /// "Total in PLN · shown in UAH at the latest rate", "No total set · limits in PLN, EUR summed
  /// in UAH at the latest rate"; nil when everything is in the display currency and nothing is
  /// missing.
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
        txns: txns, converter: converter, refundsReduceSpending: refundsReduceSpending, currency: displayCurrency,
        today: today, calendar: format.calendar)
    else { return nil }

    var missing = DashboardMissingRates()
    missing.add(status.unconverted)
    missing.add(status.totalUnconverted)

    // Every amount of the headline at one rate: the latest for the current month, the month's
    // last day for a closed one (D30).
    let rate =
      switch status.totalRate {
      case .latest: "the latest rate"
      case .day(let day): "the rate of \(format.day(day))"
      }
    let missingPairs = status.totalUnconverted.missingRates.map { "\($0.from.rawValue)→\($0.to.rawValue)" }.sorted()
    var currencyNote: String?
    if let total = status.total {
      if !missingPairs.isEmpty {
        currencyNote = "No \(Set(missingPairs).sorted().joined(separator: ", ")) rate: those amounts are left out"
      } else if total.currency != status.currency {
        currencyNote = "Total in \(total.currency.rawValue) · shown in \(status.currency.rawValue) at \(rate)"
      }
    } else if !status.totalUnconverted.isEmpty {
      let codes = Set(status.totalUnconverted.missingRates.map(\.from.rawValue)).sorted()
      currencyNote = "No \(codes.joined(separator: ", "))→\(displayCurrency.rawValue) rate: those limits are left out of the total"
    } else if status.limitCurrencies.contains(where: { $0 != displayCurrency }) {
      let currencies = status.limitCurrencies.map(\.rawValue).joined(separator: ", ")
      currencyNote = "No total set · limits in \(currencies) summed in \(displayCurrency.rawValue) at \(rate)"
    } else {
      currencyNote = "No total set · the sum of the limits"
    }

    let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    func row(id: String, categoryID: AbacusDomain.Category.ID?, name: String, spent: Money, limit: Money, status: LimitStatus) -> Row {
      let note =
        status == .over
        ? "Over by \(format.magnitude(spent - limit))"
        : "\(format.money(limit - spent)) left"
      return Row(
        id: id, categoryID: categoryID, name: name, spent: spent, limit: limit, status: status,
        barFraction: barFraction(spent: spent, limit: limit),
        amountsText: "\(format.money(spent)) / \(format.money(limit))", noteText: note)
    }
    let rows = status.lines.map { line in
      row(
        id: line.allocationID.uuidString, categoryID: line.categoryID,
        name: names[line.categoryID] ?? "Unknown category", spent: line.spent, limit: line.limit, status: line.status)
    }
    let unallocated = status.unallocated.map {
      row(id: "unallocated", categoryID: nil, name: "Unallocated", spent: $0.spent, limit: $0.limit, status: $0.status)
    }
    let totalRow = status.total.map {
      row(id: "total", categoryID: nil, name: "Total", spent: $0.spent, limit: $0.limit, status: $0.status)
    }

    let used = status.fractionUsed.map { " · \(format.percent($0)) used" } ?? ""
    let remaining = status.remaining
    let remainingText =
      remaining.minorUnits >= 0
      ? "\(format.money(remaining)) left\(used)"
      : "Over budget by \(format.magnitude(remaining))\(used)"
    let over = status.overCount
    let badge = over == 0 ? "On track" : over == 1 ? "1 category over" : "\(over) categories over"

    return DashboardBudget(
      month: month, currency: status.currency, spent: status.spent, limit: status.limit, status: status.status,
      barFraction: barFraction(spent: status.spent, limit: status.limit), overCount: over,
      daysLeft: status.daysLeft, rows: rows, unallocated: unallocated, total: totalRow, missing: missing,
      spentText: format.money(status.spent), limitText: "of \(format.money(status.limit))",
      remainingText: remainingText, badgeText: badge, currencyNote: currencyNote)
  }

  static func barFraction(spent: Money, limit: Money) -> Double {
    guard let fraction = Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) else {
      return spent.minorUnits > 0 ? 1 : 0
    }
    return min(1, max(0, NSDecimalNumber(decimal: fraction).doubleValue))
  }
}

// MARK: - Category donuts (R-HOME-3, R-HOME-6)

/// The expenses donut (R-HOME-3) keeps its name.
public typealias DashboardExpenses = DashboardDonut

/// A month's expenses (R-HOME-3) or income (R-HOME-6) by top-level category, for a donut.
public struct DashboardDonut: Sendable {
  public struct Slice: Hashable, Sendable, Identifiable {
    public let id: CategoryKey
    /// Expense or income: which donut the slice belongs to (and what a drill-down filters).
    public let kind: CategoryKind
    /// nil for "Uncategorised" (drills down to the kind's transactions without a category).
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

    /// Picking it opens Transactions: a category or "Uncategorised", not "Refunds".
    public var drillsDown: Bool {
      if case .refunds = id { false } else { true }
    }
  }

  public let kind: CategoryKind
  public let month: Month
  public let total: Money
  public let totalText: String
  /// Top-level categories with a positive amount, largest first.
  public let slices: [Slice]
  public let missing: DashboardMissingRates
  /// "Expenses by category, October 2026" / "Income by category, October 2026".
  public let chartLabel: String

  public var isEmpty: Bool { slices.isEmpty }

  /// "Monthly expenses" / "Monthly income".
  public var title: String { kind == .expense ? "Monthly expenses" : "Monthly income" }
  /// The label in the donut's hole: "Spent" / "Received".
  public var totalLabel: String { kind == .expense ? "Spent" : "Received" }
  /// "No expenses in October 2026." / "No income in October 2026."
  public func emptyText(_ monthTitle: String) -> String {
    kind == .expense ? "No expenses in \(monthTitle)." : "No income in \(monthTitle)."
  }

  /// "Refunds" and a category without a valid colour: the neutral grey of every screen.
  public static let neutralColor = "#8E8E93"

  /// Expenses or income of `month` by category (`Calc.categoryTotals`), each amount at its
  /// day's rate (R-FX-3), refunds by the setting (R-TX-4, R-SET-3): with it off, income has a
  /// "Refunds" slice (not a drill-down).
  static func make(
    kind: CategoryKind = .expense, month: Month, accounts: [Account], categories: [AbacusDomain.Category],
    txns: [TxnWithLines], currency: Currency, converter: any CurrencyConverter, refundsReduceSpending: Bool,
    format: DashboardFormat, uncategorisedColor: String = Uncategorised.defaultColorHex
  ) -> DashboardDonut {
    let breakdown = Calc.categoryTotals(
      kind: kind, days: month.firstDay...month.lastDay(calendar: format.calendar), accounts: accounts,
      categories: categories, txns: txns, currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, calendar: format.calendar)
    let tree = CategoryTree(categories)
    func slice(_ item: CategoryTotal, parentColor: String?) -> Slice {
      let category: AbacusDomain.Category? =
        if case .category(let id) = item.key { tree.category(id) } else { nil }
      // The same colour the Categories page shows (R-MGMT-7): the category's own, a child
      // without one takes its parent's; no category is the built-in Uncategorised (D47).
      let color =
        switch item.key {
        case .uncategorized: uncategorisedColor
        case .refunds: neutralColor
        case .category: ColorPalette.normalized(category?.colorHex) ?? parentColor ?? neutralColor
        }
      let name =
        switch item.key {
        case .category: category?.name ?? "Unknown category"
        case .uncategorized: Uncategorised.title
        case .refunds: "Refunds"
        }
      return Slice(
        id: item.key, kind: kind, categoryID: category?.id, name: name, colorHex: color, amount: item.total,
        share: item.share, amountText: format.money(item.total), percentText: item.share.map(format.percent) ?? "—",
        children: item.children.filter { $0.total.minorUnits > 0 }.map { slice($0, parentColor: color) })
    }
    var missing = DashboardMissingRates()
    missing.add(breakdown.unconverted)
    let what = kind == .expense ? "Expenses" : "Income"
    return DashboardDonut(
      kind: kind, month: month, total: breakdown.total, totalText: format.money(breakdown.total),
      slices: breakdown.items.filter { $0.total.minorUnits > 0 }.map { slice($0, parentColor: nil) },
      missing: missing, chartLabel: "\(what) by category, \(format.month(month))")
  }
}
