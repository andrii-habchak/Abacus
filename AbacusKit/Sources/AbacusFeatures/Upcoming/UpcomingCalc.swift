import AbacusDomain
import Foundation

/// One occurrence shown on the Bills tab (R-REC-10): expected (computed) or resolved in the range
/// (paid / skipped, dimmed with an undo action).
public struct UpcomingOccurrence: Identifiable, Hashable, Sendable {
  public var id: String { "\(item.id.uuidString)|\(day.string)" }
  public let item: ScheduledItem
  public let day: Day
  /// The stored row when the occurrence is paid or skipped; nil while expected.
  public let resolved: ScheduledOccurrence?

  public init(item: ScheduledItem, day: Day, resolved: ScheduledOccurrence? = nil) {
    self.item = item
    self.day = day
    self.resolved = resolved
  }

  public var isExpected: Bool { resolved == nil }
  public func isOverdue(today: Day) -> Bool { resolved == nil && day < today }
}

/// The Bills tab's groups (R-REC-10): Overdue, Today, This week (the next 7 days), Later.
public enum UpcomingGroup: String, CaseIterable, Hashable, Sendable, Identifiable {
  case overdue, today, thisWeek, later

  public var id: Self { self }

  public var title: String {
    switch self {
    case .overdue: "Overdue"
    case .today: "Today"
    case .thisWeek: "This week"
    case .later: "Later"
    }
  }
}

/// Money out / in / net of the expected occurrences of a range in the display currency at the
/// latest rate (R-REC-10, R-FX-4). Transfers are not counted; amounts without a rate are left
/// out and named (D27).
public struct UpcomingTotals: Hashable, Sendable {
  public var currency: Currency
  public var outMinor: Int64 = 0
  public var inMinor: Int64 = 0
  public var unconverted: Set<Currency> = []

  public init(currency: Currency) {
    self.currency = currency
  }

  public var netMinor: Int64 { inMinor - outMinor }
}

/// Pure rules of the Upcoming screen and the dashboard widget.
public enum UpcomingCalc {
  /// Expected occurrences from `today − grace` through `today + rangeDays` (active items on
  /// non-archived accounts, not resolved), plus the paid / skipped ones dated today or later in
  /// the range. Sorted by day, then description.
  public static func occurrences(
    items: [ScheduledItem], stored: [ScheduledOccurrence], accounts: [Account], today: Day, rangeDays: Int,
    graceDays: Int = ScheduledOccurrences.defaultGraceDays
  ) -> [UpcomingOccurrence] {
    let through = today.plusDays(rangeDays)
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let resolvedKeys = Set(stored.compactMap { row in Day(row.expectedDay).map { OccurrenceKey(itemID: row.itemID, day: $0) } })
    var result = ScheduledOccurrences.expected(
      items: items, resolved: resolvedKeys, accounts: accounts, today: today, through: through, graceDays: graceDays
    ).compactMap { occurrence in
      byID[occurrence.itemID].map { UpcomingOccurrence(item: $0, day: occurrence.expectedDay) }
    }
    let usable = Set(accounts.filter { !$0.isArchived }.map(\.id))
    var seen: Set<OccurrenceKey> = []
    for row in stored where row.status != .missed {
      guard let day = Day(row.expectedDay), day >= today, day <= through, let item = byID[row.itemID],
        item.status != .paused, usable.contains(item.accountID),
        seen.insert(OccurrenceKey(itemID: item.id, day: day)).inserted
      else { continue }
      result.append(UpcomingOccurrence(item: item, day: day, resolved: row))
    }
    return result.sorted {
      ($0.day, $0.item.payee.lowercased(), $0.item.id.uuidString) < ($1.day, $1.item.payee.lowercased(), $1.item.id.uuidString)
    }
  }

  /// The group of an occurrence; nil for a resolved one dated before today (not shown).
  public static func group(of occurrence: UpcomingOccurrence, today: Day) -> UpcomingGroup? {
    if occurrence.day < today { return occurrence.resolved == nil ? .overdue : nil }
    if occurrence.day == today { return .today }
    return today.daysUntil(occurrence.day) <= 7 ? .thisWeek : .later
  }

  /// Non-empty groups in screen order.
  public static func grouped(_ occurrences: [UpcomingOccurrence], today: Day) -> [(group: UpcomingGroup, rows: [UpcomingOccurrence])] {
    var buckets: [UpcomingGroup: [UpcomingOccurrence]] = [:]
    for occurrence in occurrences {
      guard let group = group(of: occurrence, today: today) else { continue }
      buckets[group, default: []].append(occurrence)
    }
    return UpcomingGroup.allCases.compactMap { group in buckets[group].map { (group, $0) } }
  }

  /// The sidebar badge (R-REC-10): overdue plus expected in the next 7 days, unresolved only.
  public static func badgeCount(
    items: [ScheduledItem], stored: [ScheduledOccurrence], accounts: [Account], today: Day,
    graceDays: Int = ScheduledOccurrences.defaultGraceDays
  ) -> Int {
    occurrences(items: items, stored: stored, accounts: accounts, today: today, rangeDays: 7, graceDays: graceDays)
      .filter(\.isExpected).count
  }

  /// R-REC-10 header totals over the expected occurrences.
  public static func totals(
    _ occurrences: [UpcomingOccurrence], accounts: [Account], currency: Currency, converter: any CurrencyConverter
  ) -> UpcomingTotals {
    let currencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })
    var totals = UpcomingTotals(currency: currency)
    for occurrence in occurrences where occurrence.isExpected && occurrence.item.type != .transfer {
      guard let from = currencies[occurrence.item.accountID] else { continue }
      guard let converted = converter.convertAtLatest(Money(minorUnits: occurrence.item.amountMinor, currency: from), to: currency)
      else {
        totals.unconverted.insert(from)
        continue
      }
      if occurrence.item.type == .income { totals.inMinor += converted.minorUnits } else { totals.outMinor += converted.minorUnits }
    }
    return totals
  }

  /// "Monthly", "Weekly", "Every 2 months", "Monthly, last day".
  public static func repeatLabel(_ item: ScheduledItem) -> String {
    if item.unit == .month, item.lastDayOfMonth {
      return item.interval == 1 ? "Monthly, last day" : "Every \(item.interval) months, last day"
    }
    if item.interval == 1 {
      switch item.unit {
      case .day: return "Daily"
      case .week: return "Weekly"
      case .month: return "Monthly"
      case .year: return "Yearly"
      }
    }
    return "Every \(item.interval) \(item.unit.rawValue)s"
  }

  /// Occurrences per month of an item (All items "per month" figure).
  public static func perMonth(_ item: ScheduledItem) -> Decimal {
    let base: Decimal =
      switch item.unit {
      case .day: Decimal(string: "30.436875")!
      case .week: Decimal(string: "4.348125")!
      case .month: 1
      case .year: Decimal(1) / 12
      }
    return base / Decimal(max(1, item.interval))
  }

  /// The average monthly cost of the active, non-transfer items in `currency` at the latest rate
  /// (income positive, expense negative); currencies without a rate are named.
  public static func monthlyAverage(
    _ items: [ScheduledItem], accounts: [Account], currency: Currency, converter: any CurrencyConverter
  ) -> (minor: Int64, unconverted: Set<Currency>) {
    let currencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })
    var sum: Decimal = 0
    var missing: Set<Currency> = []
    for item in items where item.status == .active && item.type != .transfer {
      guard let from = currencies[item.accountID] else { continue }
      guard let converted = converter.convertAtLatest(Money(minorUnits: item.amountMinor, currency: from), to: currency)
      else {
        missing.insert(from)
        continue
      }
      let signed = Decimal(converted.minorUnits) * (item.type == .income ? 1 : -1)
      sum += signed * perMonth(item)
    }
    var rounded = Decimal()
    var value = sum
    NSDecimalRound(&rounded, &value, 0, .bankers)
    return ((rounded as NSDecimalNumber).int64Value, missing)
  }

  /// The next occurrence on or after `today` (All items "Next" column); nil when the series ended.
  public static func nextDay(_ item: ScheduledItem, today: Day) -> Day? {
    item.schedule?.next(1, onOrAfter: today).first
  }

  /// "today", "tomorrow", "yesterday", "in 3 days", "8 days ago".
  public static func relative(_ day: Day, today: Day) -> String {
    let delta = today.daysUntil(day)
    switch delta {
    case 0: return "today"
    case 1: return "tomorrow"
    case -1: return "yesterday"
    default: return delta > 0 ? "in \(delta) days" : "\(-delta) days ago"
    }
  }
}
