import Foundation

/// One category limit of the budget, in the limit's own currency (R-BUD-1, R-HOME-2, D43).
public struct BudgetLine: Hashable, Sendable, Identifiable {
  public let allocationID: BudgetAllocation.ID
  public let categoryID: Category.ID
  /// In the allocation's currency.
  public let limit: Money
  /// The category's spending (its children's too, unless they have a limit of their own) in the
  /// allocation's currency, each amount converted at its day's rate (R-BUD-2).
  public let spent: Money
  /// Decided in the allocation's currency, so the display currency never changes it (D30, D43).
  public let status: LimitStatus

  public var id: BudgetAllocation.ID { allocationID }
  public var currency: Currency { limit.currency }
  /// limit − spent; negative = over by that much.
  public var remaining: Money { limit - spent }
  /// spent / limit (1 = 100 %), nil when the limit is not positive.
  public var fractionUsed: Decimal? { Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) }
}

/// A limit with its spending in one currency: the budget's own total, or the unallocated
/// remainder (R-BUD-1, D46).
public struct BudgetAmount: Hashable, Sendable {
  public let limit: Money
  public let spent: Money
  public let status: LimitStatus

  public var currency: Currency { limit.currency }
  /// limit − spent; negative = over by that much.
  public var remaining: Money { limit - spent }
  /// spent / limit (1 = 100 %), nil when the limit is not positive.
  public var fractionUsed: Decimal? { Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) }
}

/// The budget of one month (R-BUD-1…3, R-HOME-2, D43, D46): per-category lines in their own
/// currencies, the plan's total in its own currency with the unallocated remainder, and the
/// headline sums in one currency (the display currency).
public struct BudgetStatus: Hashable, Sendable {
  public let month: Month
  public let plan: BudgetPlan
  /// One per category limit, in category order (by category position).
  public let lines: [BudgetLine]
  /// The plan's total in its own currency; spent = every expense of the month (uncategorised
  /// too) converted to it at each day's rate. nil when the plan has no total (`totalMinor` 0):
  /// the budget's total is then the sum of the limits.
  public let total: BudgetAmount?
  /// With a total: total − the limits (converted to the total's currency at `totalRate`) and the
  /// spending outside the limited categories (uncategorised too), in the total's currency.
  public let unallocated: BudgetAmount?
  /// The currency of the sums below: the display currency (the total's currency when the total
  /// has no rate to it).
  public let currency: Currency
  /// The rate the sums use: the latest for the current (or a future) month, the month's last
  /// day for a closed one (D30).
  public let totalRate: RateDate
  /// The total in `currency`; without a total, the sum of the lines' limits (a line whose
  /// currency has no rate is left out and recorded in `totalUnconverted`).
  public let limit: Money
  /// The total's spending in `currency`; without a total, the sum of the lines' spending.
  public let spent: Money
  /// The total's status, decided in the total's own currency (D30, D46); without a total, of
  /// the sums. Category statuses do not depend on `currency`.
  public let status: LimitStatus
  /// Days of the month after `today` (0 for past months, all days for future months).
  public let daysLeft: Int
  /// Spending that could not be converted to its limit's (or the total's) currency.
  public let unconverted: Unconverted
  /// Amounts that could not be converted to `currency` or to the total's currency.
  public let totalUnconverted: Unconverted

  public var remaining: Money { limit - spent }
  public var fractionUsed: Decimal? { Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) }
  /// Category lines over their limit, and the unallocated remainder when it is over.
  public var overCount: Int {
    lines.filter { $0.status == .over }.count + (unallocated?.status == .over ? 1 : 0)
  }
  /// The limits' currencies, in line order, without repeats.
  public var limitCurrencies: [Currency] {
    var seen: Set<Currency> = []
    return lines.map(\.currency).filter { seen.insert($0).inserted }
  }
}

extension Calc {
  /// The plan in effect for `month`: the latest one with `effectiveMonth <= month` (R-BUD-3).
  public static func planInEffect(for month: Month, plans: [BudgetPlan]) -> BudgetPlan? {
    plans
      .compactMap { plan in Month(plan.effectiveMonth).map { (plan, $0) } }
      .filter { $0.1 <= month }
      .max { $0.1 < $1.1 }?.0
  }

  /// The rate a month's budget sums use (D30): the latest for the current or a future month,
  /// the month's last day for a closed one.
  public static func budgetTotalRate(for month: Month, today: Day, calendar: Calendar = .current) -> RateDate {
    month >= today.yearMonth ? .latest : .day(month.lastDay(calendar: calendar))
  }

  /// Budget status for `month` (R-BUD-1…3, R-HOME-2, D27, D43, D46), nil when no plan is in
  /// effect.
  ///
  /// Spent per limit = the month's expense entries (attached expense records included; refunds
  /// and refund lines by the setting) converted to that limit's currency at each day's rate
  /// (R-BUD-2, R-FX-3). An entry counts under the limit of its own category, else under its
  /// parent's (a parent's limit covers its children; a child's own limit wins), else nowhere.
  /// With a total (`plan.total`): its spending is every expense entry converted to the total's
  /// currency at each day's rate; unallocated = total − the limits at `budgetTotalRate`, spent =
  /// the entries no limit covers; the headline converts the total to `currency` at
  /// `budgetTotalRate`. Without one, the headline sums each line's limit and spending in
  /// `currency` at `budgetTotalRate`.
  /// Amounts without a rate are left out and reported, never converted at 1 (D27).
  ///
  /// `allocations` may hold every plan's allocations; only the plan in effect's are used. Two
  /// allocations of one category (not written by the app) add up in the first one's currency.
  public static func budgetStatus(
    month: Month, plans: [BudgetPlan], allocations: [BudgetAllocation], accounts: [Account],
    categories: [Category], txns: [TxnWithLines], converter: some CurrencyConverter,
    refundsReduceSpending: Bool, currency: Currency, today: Day, calendar: Calendar = .current
  ) -> BudgetStatus? {
    guard let plan = planInEffect(for: month, plans: plans) else { return nil }
    let tree = CategoryTree(categories)
    let totalRate = budgetTotalRate(for: month, today: today, calendar: calendar)
    var gaps = Unconverted()

    // One limit per category.
    var order: [Category.ID] = []
    var limits: [Category.ID: (allocationID: BudgetAllocation.ID, limit: Money)] = [:]
    for allocation in allocations where allocation.planID == plan.id {
      guard let existing = limits[allocation.categoryID] else {
        order.append(allocation.categoryID)
        limits[allocation.categoryID] = (allocation.id, allocation.limit)
        continue
      }
      let target = existing.limit.currency
      guard
        let minor = convert(
          allocation.limitMinor, from: allocation.currency, to: target, at: totalRate, using: converter, gaps: &gaps)
      else { continue }
      limits[allocation.categoryID] = (existing.allocationID, existing.limit + Money(minorUnits: minor, currency: target))
    }

    // Spending, each entry converted to its limit's currency at its day's rate.
    let accountCurrencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
    let days = month.firstDay...month.lastDay(calendar: calendar)
    let total = plan.total
    var spent: [Category.ID: Int64] = [:]
    var totalSpent: Int64 = 0
    var otherSpent: Int64 = 0
    for item in txns {
      guard days.contains(Day(item.txn.occurredAt, calendar: calendar)) else { continue }
      let from = accountCurrencies[item.txn.accountID]
      let entries = reportEntries(
        of: item, currency: from ?? currency, categories: tree, refundsReduceSpending: refundsReduceSpending,
        calendar: calendar)
      for entry in entries where entry.kind == .expense {
        var owner: Category.ID?
        if case .category(let id) = entry.key {
          if limits[id] != nil {
            owner = id
          } else if let parent = tree.parentID(of: id), limits[parent] != nil {
            owner = parent
          }
        }
        guard owner != nil || total != nil else { continue }
        guard let from else {
          gaps.recordUnknownAccount(item.txn.accountID)
          continue
        }
        if let owner,
          let minor = convert(
            entry.amount.minorUnits, from: from, to: limits[owner]!.limit.currency, at: .day(entry.day),
            using: converter, gaps: &gaps)
        {
          spent[owner, default: 0] += minor
        }
        if let total,
          let minor = convert(
            entry.amount.minorUnits, from: from, to: total.currency, at: .day(entry.day), using: converter,
            gaps: &gaps)
        {
          totalSpent += minor
          if owner == nil { otherSpent += minor }
        }
      }
    }

    let sortedOrder = order.enumerated().sorted { a, b in
      let pa = tree.category(a.element)?.position ?? Int.max
      let pb = tree.category(b.element)?.position ?? Int.max
      return (pa, a.offset) < (pb, b.offset)
    }.map(\.element)
    let lines = sortedOrder.map { categoryID -> BudgetLine in
      let (allocationID, limit) = limits[categoryID]!
      let spentMinor = spent[categoryID] ?? 0
      return BudgetLine(
        allocationID: allocationID, categoryID: categoryID, limit: limit,
        spent: Money(minorUnits: spentMinor, currency: limit.currency),
        status: limitStatus(spentMinor: spentMinor, limitMinor: limit.minorUnits))
    }

    var totalGaps = Unconverted()
    let daysLeft = daysLeft(in: month, today: today, calendar: calendar)

    if let total {
      // Unallocated = total − the limits, every limit at the same rate (D30, D46).
      var allocated: Int64 = 0
      for line in lines {
        guard
          let minor = convert(
            line.limit.minorUnits, from: line.currency, to: total.currency, at: totalRate, using: converter,
            gaps: &totalGaps)
        else { continue }
        allocated += minor
      }
      let unallocatedLimit = total.minorUnits - allocated
      let unallocated = BudgetAmount(
        limit: Money(minorUnits: unallocatedLimit, currency: total.currency),
        spent: Money(minorUnits: otherSpent, currency: total.currency),
        status: limitStatus(spentMinor: otherSpent, limitMinor: unallocatedLimit))
      let own = BudgetAmount(
        limit: total, spent: Money(minorUnits: totalSpent, currency: total.currency),
        status: limitStatus(spentMinor: totalSpent, limitMinor: total.minorUnits))

      // The headline in `currency`; the total's own currency when it has no rate to it.
      var shownCurrency = currency
      var shownLimit = total.minorUnits
      var shownSpent = totalSpent
      if let limit = convert(total.minorUnits, from: total.currency, to: currency, at: totalRate, using: converter, gaps: &totalGaps),
        let spent = convert(totalSpent, from: total.currency, to: currency, at: totalRate, using: converter, gaps: &totalGaps)
      {
        shownLimit = limit
        shownSpent = spent
      } else {
        shownCurrency = total.currency
      }
      return BudgetStatus(
        month: month, plan: plan, lines: lines, total: own, unallocated: unallocated, currency: shownCurrency,
        totalRate: totalRate, limit: Money(minorUnits: shownLimit, currency: shownCurrency),
        spent: Money(minorUnits: shownSpent, currency: shownCurrency), status: own.status, daysLeft: daysLeft,
        unconverted: gaps, totalUnconverted: totalGaps)
    }

    // No total: the sums of the lines in `currency`, every line at the same rate.
    var limitSum: Int64 = 0
    var spentSum: Int64 = 0
    for line in lines {
      guard
        let limit = convert(
          line.limit.minorUnits, from: line.currency, to: currency, at: totalRate, using: converter, gaps: &totalGaps),
        let spent = convert(
          line.spent.minorUnits, from: line.currency, to: currency, at: totalRate, using: converter, gaps: &totalGaps)
      else { continue }
      limitSum += limit
      spentSum += spent
    }

    return BudgetStatus(
      month: month, plan: plan, lines: lines, total: nil, unallocated: nil, currency: currency, totalRate: totalRate,
      limit: Money(minorUnits: limitSum, currency: currency), spent: Money(minorUnits: spentSum, currency: currency),
      status: limitStatus(spentMinor: spentSum, limitMinor: limitSum), daysLeft: daysLeft, unconverted: gaps,
      totalUnconverted: totalGaps)
  }

  /// Days of `month` after `today`: 31 Oct with today = 21 Oct → 10 (R-HOME-2).
  public static func daysLeft(in month: Month, today: Day, calendar: Calendar = .current) -> Int {
    let last = month.lastDay(calendar: calendar)
    if month < today.yearMonth { return 0 }
    if month > today.yearMonth { return last.day }
    return last.day - today.day
  }
}
