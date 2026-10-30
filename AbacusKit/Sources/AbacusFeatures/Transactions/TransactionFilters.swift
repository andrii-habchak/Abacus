import AbacusDomain
import Foundation

/// What the filter bar of the transaction list holds (approved prototype 2): date range,
/// categories (with "Uncategorised"), accounts, types, event, import batch, search and sort
/// (R-LIST-1…3, R-LIST-6, R-EVT-3, R-HOME-3, R-IMP-6).
/// Plain values; `query(today:)` turns them into the repository's `TxnQuery`.
public struct TransactionFilters: Hashable, Sendable {
  /// Date presets of the date menu, in menu order.
  public enum Preset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case last30Days, thisMonth, lastMonth, last3Months, thisYear

    public var id: Self { self }

    public var title: String {
      switch self {
      case .last30Days: "Last 30 days"
      case .thisMonth: "This month"
      case .lastMonth: "Last month"
      case .last3Months: "Last 3 months"
      case .thisYear: "This year"
      }
    }

    /// The inclusive day range of the preset as seen on `today`.
    public func days(today: Day, calendar: Calendar = .current) -> ClosedRange<Day> {
      switch self {
      case .last30Days:
        return today.adding(days: -29, calendar: calendar)...today
      case .thisMonth:
        let month = today.yearMonth
        return month.firstDay...month.lastDay(calendar: calendar)
      case .lastMonth:
        let month = today.yearMonth.adding(months: -1)
        return month.firstDay...month.lastDay(calendar: calendar)
      case .last3Months:
        let start = calendar.date(byAdding: .month, value: -3, to: today.date(calendar: calendar))!
        return Day(start, calendar: calendar).adding(days: 1, calendar: calendar)...today
      case .thisYear:
        return Day(year: today.year, month: 1, day: 1)...Day(year: today.year, month: 12, day: 31)
      }
    }
  }

  public enum DateRange: Hashable, Sendable {
    case preset(Preset)
    /// Inclusive custom range ("Custom range" From/To).
    case custom(from: Day, to: Day)
  }

  /// Every day: the range the import filter opens with.
  public static let allDates = DateRange.custom(
    from: Day(year: 1900, month: 1, day: 1), to: Day(year: 9999, month: 12, day: 31))

  public var dateRange: DateRange
  /// Selected categories; a selected parent covers its children (R-LIST-2).
  public var categoryIDs: Set<AbacusDomain.Category.ID>
  /// "Uncategorised" ticked: expenses and incomes without a category, in addition to
  /// `categoryIDs` (dashboard drill-down, R-HOME-3).
  public var includeUncategorised: Bool
  public var accountIDs: Set<Account.ID>
  /// Selected debts (R-DEBT-22). A debt stands for its linked accounts, which sit in `accountIDs`
  /// as removable entries; the debt stays selected when the user un-ticks one of them.
  public var debtIDs: Set<Debt.ID>
  /// The accounts each selected debt added to `accountIDs` (not accounts the user had selected
  /// on their own): clearing the debt removes exactly these.
  public var debtAccountIDs: [Debt.ID: Set<Account.ID>]
  /// Type toggles; all three on by default. None on matches nothing.
  public var types: Set<TxnType>
  public var eventID: Event.ID?
  /// "Show transactions" after an import (R-IMP-6): only that batch's transactions. The batch is
  /// kept whole for the chip ("Import: <file> · <date>").
  public var importBatch: ImportBatch?
  /// Matches description (payee) and note (R-LIST-6).
  public var search: String
  /// R-LIST-3: newest first by default.
  public var newestFirst: Bool

  public init(
    dateRange: DateRange = .preset(.last30Days), categoryIDs: Set<AbacusDomain.Category.ID> = [],
    accountIDs: Set<Account.ID> = [], types: Set<TxnType> = Set(TxnType.allCases),
    eventID: Event.ID? = nil, search: String = "", newestFirst: Bool = true,
    includeUncategorised: Bool = false, importBatch: ImportBatch? = nil, debtIDs: Set<Debt.ID> = [],
    debtAccountIDs: [Debt.ID: Set<Account.ID>] = [:]
  ) {
    self.debtIDs = debtIDs
    self.debtAccountIDs = debtAccountIDs
    self.dateRange = dateRange
    self.categoryIDs = categoryIDs
    self.includeUncategorised = includeUncategorised
    self.importBatch = importBatch
    self.accountIDs = accountIDs
    self.types = types
    self.eventID = eventID
    self.search = search
    self.newestFirst = newestFirst
  }

  /// R-LIST-1: the last 30 days, every type, newest first.
  public static let `default` = TransactionFilters()

  /// Dashboard drill-down (R-HOME-3, R-HOME-6): one category in one month; a nil category is
  /// the "Uncategorised" slice (that kind without a category). The income donut also filters to
  /// income (`DashboardDrillDown.types`).
  public static func drillDown(
    category: AbacusDomain.Category.ID?, month: Month, kind: CategoryKind = .expense, calendar: Calendar = .current
  ) -> TransactionFilters {
    let days = DateRange.custom(from: month.firstDay, to: month.lastDay(calendar: calendar))
    let types = DashboardDrillDown.types(kind: kind, uncategorised: category == nil) ?? Set(TxnType.allCases)
    guard let category else {
      return TransactionFilters(dateRange: days, types: types, includeUncategorised: true)
    }
    return TransactionFilters(dateRange: days, categoryIDs: [category], types: types)
  }

  /// A picked donut slice's drill-down (R-HOME-3, R-HOME-6).
  public static func drillDown(_ target: DashboardDrillDown.Target, calendar: Calendar = .current) -> TransactionFilters {
    drillDown(category: target.categoryID, month: target.month, kind: target.kind, calendar: calendar)
  }

  /// Event view "Show N transactions" (R-EVT-3): every transaction tagged with the event, of
  /// any type and on any date — the N the event view counts. The event's own dates only steer
  /// auto-tagging (R-EVT-2): a flight booked before the trip or a refund after it still belongs.
  public static func event(_ event: Event) -> TransactionFilters {
    TransactionFilters(dateRange: allDates, eventID: event.id)
  }

  /// Import "Show transactions" (R-IMP-6): every transaction the import created, any date.
  public static func importBatch(_ batch: ImportBatch) -> TransactionFilters {
    TransactionFilters(dateRange: allDates, importBatch: batch)
  }

  /// A debt's "Show transactions" (R-DEBT-22): the debt selected with all its linked accounts as
  /// account entries, any date.
  public static func debt(_ id: Debt.ID, accountIDs: Set<Account.ID>) -> TransactionFilters {
    var filters = TransactionFilters(dateRange: allDates)
    filters.addDebt(id, accountIDs: accountIDs)
    return filters
  }

  // MARK: State

  /// Whether anything other than the sort order differs from the default ("Clear filters").
  public var hasActiveFilters: Bool {
    var other = self
    other.newestFirst = Self.default.newestFirst
    other.search = other.search.trimmingCharacters(in: .whitespacesAndNewlines)
    return other != Self.default
  }

  public var isDateFiltered: Bool { dateRange != Self.default.dateRange }
  public var isTypeFiltered: Bool { types != Self.default.types }
  public var isCategoryFiltered: Bool { !categoryIDs.isEmpty || includeUncategorised }

  /// "Clear filters": back to the default; the sort order stays.
  public mutating func clear() {
    let newestFirst = self.newestFirst
    self = Self.default
    self.newestFirst = newestFirst
  }

  public func days(today: Day, calendar: Calendar = .current) -> ClosedRange<Day> {
    switch dateRange {
    case .preset(let preset): preset.days(today: today, calendar: calendar)
    case .custom(let from, let to): min(from, to)...max(from, to)
    }
  }

  /// Sets a custom range; the ends are swapped when `from` is after `to`.
  public mutating func setCustomRange(from: Day, to: Day) {
    dateRange = .custom(from: min(from, to), to: max(from, to))
  }

  public mutating func toggleType(_ type: TxnType) {
    if types.contains(type) { types.remove(type) } else { types.insert(type) }
  }

  /// Un-ticking an account that a debt added keeps the debt selected (R-DEBT-22); ticking it
  /// again makes it an independent selection.
  public mutating func toggleAccount(_ id: Account.ID) {
    if accountIDs.contains(id) {
      accountIDs.remove(id)
      for debt in debtAccountIDs.keys { debtAccountIDs[debt]?.remove(id) }
    } else {
      accountIDs.insert(id)
    }
  }

  /// R-DEBT-22: selects the debt and expands it to its accounts. Accounts the user had already
  /// selected stay theirs (clearing the debt does not remove them).
  public mutating func addDebt(_ id: Debt.ID, accountIDs linked: Set<Account.ID>) {
    debtIDs.insert(id)
    debtAccountIDs[id] = linked.subtracting(accountIDs)
    accountIDs.formUnion(linked)
  }

  /// R-DEBT-22: clears the debt and removes the account entries it added, not those selected
  /// independently.
  public mutating func removeDebt(_ id: Debt.ID) {
    debtIDs.remove(id)
    accountIDs.subtract(debtAccountIDs[id] ?? [])
    debtAccountIDs[id] = nil
  }

  /// Account entries that came from a debt and are still selected.
  public var debtAddedAccountIDs: Set<Account.ID> {
    debtAccountIDs.values.reduce(into: Set<Account.ID>()) { $0.formUnion($1) }.intersection(accountIDs)
  }

  public var isDebtFiltered: Bool { !debtIDs.isEmpty }

  // MARK: Query

  /// The repository query for these filters, or nil when no type is on (nothing can match).
  /// All three types map to "any type"; the category set is passed as selected — the
  /// repository expands parents to their children (`TxnQuery.categoryIDs`).
  public func query(today: Day, calendar: Calendar = .current) -> TxnQuery? {
    guard !types.isEmpty else { return nil }
    // A debt with every account entry un-ticked (or no linked account) matches nothing, not all.
    if !debtIDs.isEmpty && accountIDs.isEmpty { return nil }
    let days = days(today: today, calendar: calendar)
    return TxnQuery(
      fromDay: days.lowerBound, toDay: days.upperBound, categoryIDs: categoryIDs,
      accountIDs: accountIDs, types: types == Set(TxnType.allCases) ? [] : types,
      eventIDs: eventID.map { [$0] } ?? [],
      search: search.trimmingCharacters(in: .whitespacesAndNewlines), newestFirst: newestFirst,
      includeUncategorised: includeUncategorised, importBatchIDs: importBatch.map { [$0.id] } ?? [])
  }
}
