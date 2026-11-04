import Foundation

/// Identity of a resolved occurrence: (item, expected day). Used to skip occurrences that were
/// paid, skipped or already marked missed.
public struct OccurrenceKey: Hashable, Sendable {
  public let itemID: ScheduledItem.ID
  public let day: Day
  public init(itemID: ScheduledItem.ID, day: Day) {
    self.itemID = itemID
    self.day = day
  }
}

/// One expected (computed, not stored) occurrence of a scheduled item.
public struct ExpectedOccurrence: Hashable, Sendable {
  public let itemID: ScheduledItem.ID
  public let expectedDay: Day
  /// The day is past and the occurrence is still unresolved (R-REC-9); inside the grace period.
  public let isOverdue: Bool
  /// Signed effects per account, same rule as a real transaction (R-REC-13).
  public let effects: [AccountEffect]
}

/// Which occurrences are expected, from items and what is already resolved (R-REC-3, R-REC-9).
public enum ScheduledOccurrences {
  public static let defaultGraceDays = 14

  /// The signed effect of one occurrence of `item`: expense out, income in, transfer
  /// out of the account and (`toAmountMinor` or the same amount) into the other.
  public static func effects(of item: ScheduledItem) -> [AccountEffect] {
    switch item.type {
    case .expense: return [AccountEffect(accountID: item.accountID, amountMinor: -item.amountMinor)]
    case .income: return [AccountEffect(accountID: item.accountID, amountMinor: item.amountMinor)]
    case .transfer:
      var result = [AccountEffect(accountID: item.accountID, amountMinor: -item.amountMinor)]
      if let to = item.toAccountID {
        result.append(AccountEffect(accountID: to, amountMinor: item.toAmountMinor ?? item.amountMinor))
      }
      return result
    }
  }

  /// Unresolved occurrences with `today - graceDays <= day <= through`. Only active items on a
  /// known, non-archived account take part; older unresolved ones are *missed* (see `missed`).
  public static func expected(
    items: [ScheduledItem], resolved: Set<OccurrenceKey>, accounts: [Account], today: Day, through: Day,
    graceDays: Int = defaultGraceDays
  ) -> [ExpectedOccurrence] {
    let usable = Dictionary(uniqueKeysWithValues: accounts.filter { !$0.isArchived }.map { ($0.id, $0) })
    let from = today.plusDays(-graceDays)
    var result: [ExpectedOccurrence] = []
    for item in items where item.status == .active && usable[item.accountID] != nil {
      guard let schedule = item.schedule else { continue }
      let effects = effects(of: item)
      for day in schedule.occurrences(from: from, through: through)
      where !resolved.contains(OccurrenceKey(itemID: item.id, day: day)) {
        result.append(ExpectedOccurrence(itemID: item.id, expectedDay: day, isOverdue: day < today, effects: effects))
      }
    }
    return result.sorted { ($0.expectedDay, $0.itemID.uuidString) < ($1.expectedDay, $1.itemID.uuidString) }
  }

  /// Unresolved occurrences older than the grace period (within `lookbackDays` before it), the
  /// ones to be stored as `missed` at launch. Occurrences before the item's start are not generated.
  public static func missed(
    items: [ScheduledItem], resolved: Set<OccurrenceKey>, today: Day, graceDays: Int = defaultGraceDays,
    lookbackDays: Int = 365
  ) -> [(item: ScheduledItem, day: Day)] {
    let cutoff = today.plusDays(-graceDays - 1)  // last day that is already past grace
    let from = today.plusDays(-graceDays - lookbackDays)
    var result: [(item: ScheduledItem, day: Day)] = []
    for item in items where item.status == .active {
      guard let schedule = item.schedule else { continue }
      for day in schedule.occurrences(from: from, through: cutoff)
      where !resolved.contains(OccurrenceKey(itemID: item.id, day: day)) {
        result.append((item, day))
      }
    }
    return result
  }
}

/// A day on which an account's projected balance is below zero (R-REC-15).
public struct ForecastWarning: Hashable, Sendable {
  public let accountID: Account.ID
  public let day: Day
  public let balanceMinor: Int64
  /// Negative-effect occurrences on that account up to and including that day, newest last.
  public let causes: [ExpectedOccurrence]
}

public struct ForecastPoint: Hashable, Sendable {
  public let day: Day
  public let valueMinor: Int64
}

/// The projected balances per day for the horizon (R-REC-13). Index 0 is today; overdue
/// occurrences count on today (R-REC-9, Q12).
public struct Forecast: Sendable {
  public let today: Day
  public let horizonDays: Int
  public let accounts: [Account]
  /// `days.count == horizonDays + 1`.
  public let days: [Day]
  /// Per account, one balance per day (account currency, signed).
  public let balances: [Account.ID: [Int64]]
  public let occurrences: [ExpectedOccurrence]

  public func series(for accountID: Account.ID) -> [ForecastPoint] {
    guard let values = balances[accountID] else { return [] }
    return zip(days, values).map { ForecastPoint(day: $0, valueMinor: $1) }
  }

  /// Net worth per day: signed balances (a liability normally negative) converted with
  /// `convert` (today's latest rate for the whole horizon, R-REC-13). Accounts whose currency
  /// has no rate are left out and their currencies named (D27).
  public func netWorth(convert: (Currency, Int64) -> Int64?) -> (points: [ForecastPoint], unconverted: Set<Currency>) {
    var totals = [Int64](repeating: 0, count: days.count)
    var missing: Set<Currency> = []
    for account in accounts {
      guard let values = balances[account.id] else { continue }
      var converted: [Int64] = []
      converted.reserveCapacity(values.count)
      var ok = true
      for value in values {
        guard let c = convert(account.currency, value) else { ok = false; break }
        converted.append(c)
      }
      if !ok { missing.insert(account.currency); continue }
      for i in totals.indices { totals[i] += converted[i] }
    }
    return (zip(days, totals).map { ForecastPoint(day: $0, valueMinor: $1) }, missing)
  }

  /// The lowest projected point of one account.
  public func lowest(for accountID: Account.ID) -> ForecastPoint? {
    series(for: accountID).min { $0.valueMinor < $1.valueMinor }
  }

  /// For every non-liability account, the first day its projected balance goes below zero
  /// (it was not below zero today), with the occurrences that cause it (R-REC-15).
  public var warnings: [ForecastWarning] {
    var result: [ForecastWarning] = []
    for account in accounts where !account.kind.isLiability {
      guard let values = balances[account.id], let first = values.firstIndex(where: { $0 < 0 }) else { continue }
      let day = days[first]
      let causes = occurrences.filter { occurrence in
        let effectDay = max(occurrence.expectedDay, today)
        return effectDay <= day
          && occurrence.effects.contains { $0.accountID == account.id && $0.amountMinor < 0 }
      }
      result.append(ForecastWarning(accountID: account.id, day: day, balanceMinor: values[first], causes: causes))
    }
    return result.sorted { ($0.day, $0.accountID.uuidString) < ($1.day, $1.accountID.uuidString) }
  }
}

public enum ForecastEngine {
  public static let defaultHorizonDays = 90
  public static let horizonChoices = [30, 60, 90]

  /// Pure function over accounts, today's balances and items (R-REC-21: no per-day SQL).
  /// Archived accounts are excluded (R-ACC-4, R-REC-5). `balances` holds today's balance per account.
  public static func run(
    accounts: [Account], balances: [Account.ID: Int64], items: [ScheduledItem], resolved: Set<OccurrenceKey> = [],
    today: Day, horizonDays: Int = defaultHorizonDays, graceDays: Int = ScheduledOccurrences.defaultGraceDays
  ) -> Forecast {
    let active = accounts.filter { !$0.isArchived }
    let through = today.plusDays(horizonDays)
    let days = (0...horizonDays).map { today.plusDays($0) }
    let occurrences = ScheduledOccurrences.expected(
      items: items, resolved: resolved, accounts: accounts, today: today, through: through, graceDays: graceDays)
    // Net change per account per day index.
    var deltas: [Account.ID: [Int64]] = [:]
    for account in active { deltas[account.id] = [Int64](repeating: 0, count: horizonDays + 1) }
    for occurrence in occurrences {
      let index = max(0, today.daysUntil(occurrence.expectedDay))
      guard index <= horizonDays else { continue }
      for effect in occurrence.effects where deltas[effect.accountID] != nil {
        deltas[effect.accountID]![index] += effect.amountMinor
      }
    }
    var series: [Account.ID: [Int64]] = [:]
    for account in active {
      var running = balances[account.id] ?? 0
      var values: [Int64] = []
      values.reserveCapacity(horizonDays + 1)
      for delta in deltas[account.id]! {
        running += delta
        values.append(running)
      }
      series[account.id] = values
    }
    return Forecast(
      today: today, horizonDays: horizonDays, accounts: active, days: days, balances: series,
      occurrences: occurrences)
  }
}
