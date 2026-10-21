import Foundation

/// One row of the budget widget: an allocation, or the unallocated remainder (R-BUD-1, R-HOME-2).
public struct BudgetLine: Hashable, Sendable, Identifiable {
  /// nil for the "Unallocated (other categories)" row.
  public let allocationID: BudgetAllocation.ID?
  /// The allocation's category; nil for the unallocated row.
  public let categoryID: Category.ID?
  /// For the unallocated row: total − allocated limits (negative when limits exceed the total).
  public let limit: Money
  public let spent: Money
  public let status: LimitStatus

  public var id: String { allocationID?.uuidString ?? "unallocated" }
  public var isUnallocated: Bool { allocationID == nil }
  /// limit − spent; negative = over by that much.
  public var remaining: Money { limit - spent }
  /// spent / limit (1 = 100 %), nil when the limit is not positive.
  public var fractionUsed: Decimal? { Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) }
}

/// The budget of one month in the plan's currency (R-BUD-1…3, R-HOME-2).
public struct BudgetStatus: Hashable, Sendable {
  public let month: Month
  public let plan: BudgetPlan
  /// One per category limit, in the plan's category order (by category position).
  public let lines: [BudgetLine]
  public let unallocated: BudgetLine
  /// The plan's total limit.
  public let limit: Money
  /// All of the month's spending: allocated categories + other categories.
  public let spent: Money
  public let status: LimitStatus
  /// Days of the month after `today` (0 for past months, all days for future months).
  public let daysLeft: Int
  public let unconverted: Unconverted

  public var remaining: Money { limit - spent }
  public var fractionUsed: Decimal? { Calc.fractionUsed(spentMinor: spent.minorUnits, limitMinor: limit.minorUnits) }
  /// Category rows over their limit, the unallocated row included.
  public var overCount: Int { (lines + [unallocated]).filter { $0.status == .over }.count }
}

extension Calc {
  /// The plan in effect for `month`: the latest one with `effectiveMonth <= month` (R-BUD-3).
  public static func planInEffect(for month: Month, plans: [BudgetPlan]) -> BudgetPlan? {
    plans
      .compactMap { plan in Month(plan.effectiveMonth).map { (plan, $0) } }
      .filter { $0.1 <= month }
      .max { $0.1 < $1.1 }?.0
  }

  /// Budget status for `month` (R-BUD-1…3, R-HOME-2), nil when no plan is in effect.
  ///
  /// Spent = the month's expense entries (attached expense records included; refunds and refund
  /// lines by the setting) converted to the plan's currency at each day's rate (R-BUD-2, R-FX-3). An entry
  /// counts under the allocation of its own category, else under its parent's allocation (a
  /// parent's limit covers its children), else under "unallocated / other".
  ///
  /// `allocations` may hold every plan's allocations; only the plan in effect's are used.
  public static func budgetStatus(
    month: Month, plans: [BudgetPlan], allocations: [BudgetAllocation], accounts: [Account],
    categories: [Category], txns: [TxnWithLines], converter: some CurrencyConverter,
    refundsReduceSpending: Bool, today: Day, calendar: Calendar = .current
  ) -> BudgetStatus? {
    guard let plan = planInEffect(for: month, plans: plans) else { return nil }
    let currency = plan.currency
    let tree = CategoryTree(categories)

    // One limit per category; duplicates add up.
    var order: [Category.ID] = []
    var limits: [Category.ID: (allocationID: BudgetAllocation.ID, limit: Int64)] = [:]
    for allocation in allocations where allocation.planID == plan.id {
      if let existing = limits[allocation.categoryID] {
        limits[allocation.categoryID] = (existing.allocationID, existing.limit + allocation.limitMinor)
      } else {
        order.append(allocation.categoryID)
        limits[allocation.categoryID] = (allocation.id, allocation.limitMinor)
      }
    }

    var gaps = Unconverted()
    let entries = convertedEntries(
      txns, accounts: accounts, categories: tree, currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, days: month.firstDay...month.lastDay(calendar: calendar),
      calendar: calendar, gaps: &gaps)

    var spentByAllocation: [Category.ID: Int64] = [:]
    var other: Int64 = 0
    var total: Int64 = 0
    for entry in entries where entry.kind == .expense {
      let minor = entry.amount.minorUnits
      total += minor
      if case .category(let id) = entry.key {
        if limits[id] != nil {
          spentByAllocation[id, default: 0] += minor
          continue
        }
        if let parent = tree.parentID(of: id), limits[parent] != nil {
          spentByAllocation[parent, default: 0] += minor
          continue
        }
      }
      other += minor
    }

    func money(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: currency) }
    let sortedOrder = order.enumerated().sorted { a, b in
      let pa = tree.category(a.element)?.position ?? Int.max
      let pb = tree.category(b.element)?.position ?? Int.max
      return (pa, a.offset) < (pb, b.offset)
    }.map(\.element)
    let lines = sortedOrder.map { categoryID -> BudgetLine in
      let (allocationID, limit) = limits[categoryID]!
      let spent = spentByAllocation[categoryID] ?? 0
      return BudgetLine(
        allocationID: allocationID, categoryID: categoryID, limit: money(limit), spent: money(spent),
        status: limitStatus(spentMinor: spent, limitMinor: limit))
    }
    let unallocatedLimit = plan.totalMinor - limits.values.reduce(0) { $0 + $1.limit }
    let unallocated = BudgetLine(
      allocationID: nil, categoryID: nil, limit: money(unallocatedLimit), spent: money(other),
      status: limitStatus(spentMinor: other, limitMinor: unallocatedLimit))

    return BudgetStatus(
      month: month, plan: plan, lines: lines, unallocated: unallocated, limit: money(plan.totalMinor),
      spent: money(total), status: limitStatus(spentMinor: total, limitMinor: plan.totalMinor),
      daysLeft: daysLeft(in: month, today: today, calendar: calendar), unconverted: gaps)
  }

  /// Days of `month` after `today`: 31 Oct with today = 21 Oct → 10 (R-HOME-2).
  public static func daysLeft(in month: Month, today: Day, calendar: Calendar = .current) -> Int {
    let last = month.lastDay(calendar: calendar)
    if month < today.yearMonth { return 0 }
    if month > today.yearMonth { return last.day }
    return last.day - today.day
  }
}
