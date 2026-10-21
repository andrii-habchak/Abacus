import AbacusDomain
import Foundation

/// What the filter bar of the transaction list holds (approved prototype 2): date range,
/// categories, accounts, types, event, search and sort (R-LIST-1…3, R-LIST-6, R-EVT-3).
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

  public var dateRange: DateRange
  /// Selected categories; a selected parent covers its children (R-LIST-2).
  public var categoryIDs: Set<AbacusDomain.Category.ID>
  public var accountIDs: Set<Account.ID>
  /// Type toggles; all three on by default. None on matches nothing.
  public var types: Set<TxnType>
  public var eventID: Event.ID?
  /// Matches description (payee) and note (R-LIST-6).
  public var search: String
  /// R-LIST-3: newest first by default.
  public var newestFirst: Bool

  public init(
    dateRange: DateRange = .preset(.last30Days), categoryIDs: Set<AbacusDomain.Category.ID> = [],
    accountIDs: Set<Account.ID> = [], types: Set<TxnType> = Set(TxnType.allCases),
    eventID: Event.ID? = nil, search: String = "", newestFirst: Bool = true
  ) {
    self.dateRange = dateRange
    self.categoryIDs = categoryIDs
    self.accountIDs = accountIDs
    self.types = types
    self.eventID = eventID
    self.search = search
    self.newestFirst = newestFirst
  }

  /// R-LIST-1: the last 30 days, every type, newest first.
  public static let `default` = TransactionFilters()

  /// Dashboard drill-down (R-HOME-3): one category in one month.
  public static func drillDown(
    category: AbacusDomain.Category.ID, month: Month, calendar: Calendar = .current
  ) -> TransactionFilters {
    TransactionFilters(
      dateRange: .custom(from: month.firstDay, to: month.lastDay(calendar: calendar)),
      categoryIDs: [category])
  }

  /// Event view "Show N transactions" (R-EVT-3): every transaction of the event, any date.
  public static func event(_ event: Event) -> TransactionFilters {
    let from = event.startDay.flatMap(Day.init) ?? Day(year: 1900, month: 1, day: 1)
    let to = event.endDay.flatMap(Day.init) ?? Day(year: 9999, month: 12, day: 31)
    return TransactionFilters(dateRange: .custom(from: from, to: to), eventID: event.id)
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

  public mutating func toggleAccount(_ id: Account.ID) {
    if accountIDs.contains(id) { accountIDs.remove(id) } else { accountIDs.insert(id) }
  }

  // MARK: Query

  /// The repository query for these filters, or nil when no type is on (nothing can match).
  /// All three types map to "any type"; the category set is passed as selected — the
  /// repository expands parents to their children (`TxnQuery.categoryIDs`).
  public func query(today: Day, calendar: Calendar = .current) -> TxnQuery? {
    guard !types.isEmpty else { return nil }
    let days = days(today: today, calendar: calendar)
    return TxnQuery(
      fromDay: days.lowerBound, toDay: days.upperBound, categoryIDs: categoryIDs,
      accountIDs: accountIDs, types: types == Set(TxnType.allCases) ? [] : types,
      eventIDs: eventID.map { [$0] } ?? [],
      search: search.trimmingCharacters(in: .whitespacesAndNewlines), newestFirst: newestFirst)
  }
}
