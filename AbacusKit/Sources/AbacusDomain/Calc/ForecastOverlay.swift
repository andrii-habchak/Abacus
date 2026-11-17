import Foundation

/// Which line the Forecast tab shows (R-REC-14): net worth in a display currency, or one account
/// in its own currency.
public enum ForecastSeriesSelection: Hashable, Sendable {
  case netWorth(Currency)
  case account(Account.ID)
}

/// Actual end-of-day balances (R-ACC-3), e.g. from `SQLiteReportQueries.balances(on:)`.
public struct ActualDailyBalances: Sendable {
  /// Ascending, one entry per balance index.
  public var days: [Day]
  public var currencies: [Account.ID: Currency]
  /// Account → one balance per entry of `days` (signed, account currency).
  public var balances: [Account.ID: [Int64]]
  /// Signed debt terms that count in net worth (R-REC-13) per day; a missing day has none.
  public var debts: [Day: [Currency: Int64]]

  public init(
    days: [Day], currencies: [Account.ID: Currency], balances: [Account.ID: [Int64]], debts: [Day: [Currency: Int64]] = [:]
  ) {
    self.days = days
    self.currencies = currencies
    self.balances = balances
    self.debts = debts
  }
}

/// The gap at the comparison day split in two (R-REC-19, Q13). `scheduledMinor + otherMinor == gap`.
public struct ForecastGapSplit: Hashable, Sendable {
  /// Scheduled items of the snapshot paid differently: other amount, other day, skipped, missed or
  /// not paid yet (actual effect − forecast effect).
  public let scheduledMinor: Int64
  /// Everything else: unscheduled spending and income, edits, new accounts.
  public let otherMinor: Int64

  public init(scheduledMinor: Int64, otherMinor: Int64) {
    self.scheduledMinor = scheduledMinor
    self.otherMinor = otherMinor
  }
}

/// A past forecast against what happened (R-REC-19), in one currency, at the snapshot's rates.
public struct ForecastOverlay: Sendable {
  public let selection: ForecastSeriesSelection
  /// The currency of every value (the display currency, or the account's currency).
  public let currency: Currency
  /// The snapshot's forecast over its whole horizon (index 0 = snapshot day).
  public let forecast: [ForecastPoint]
  /// Actual balances from the snapshot day (or the first day with data, clamped) to today.
  public let actual: [ForecastPoint]
  /// The day the gap is measured: today, or the last day both lines have.
  public let gapDay: Day?
  public let actualAtGap: Int64?
  public let forecastAtGap: Int64?
  /// Currencies left out of a net-worth overlay because the snapshot has no rate for them (D27).
  public let unconverted: Set<Currency>
  public let split: ForecastGapSplit?

  /// Actual − forecast at `gapDay`.
  public var gapMinor: Int64? {
    guard let a = actualAtGap, let f = forecastAtGap else { return nil }
    return a - f
  }
}

extension ForecastOverlay {
  /// Builds the overlay. Pure; both lines are converted at `snapshot.rates` so exchange-rate moves
  /// do not show as a gap. `occurrences` are the resolved occurrences (for the gap split); an
  /// occurrence counts as happened when it is paid on a day after the snapshot day and at most
  /// the gap day (the start balance already holds the snapshot day).
  public static func make(
    snapshot: ForecastSnapshotContent, actual: ActualDailyBalances, occurrences: [ScheduledOccurrence],
    selection: ForecastSeriesSelection, today: Day
  ) -> ForecastOverlay? {
    guard let taken = snapshot.takenDay else { return nil }
    let rates = snapshot.rates
    let horizon = max(0, snapshot.snapshot.horizonDays)
    let horizonEnd = taken.plusDays(horizon)

    // Which currency and which accounts take part.
    let currency: Currency
    var unconverted: Set<Currency> = []
    var include: (Account.ID, Currency) -> Bool
    switch selection {
    case .account(let id):
      guard let c = snapshot.start.balance(of: id)?.currency ?? actual.currencies[id] else { return nil }
      currency = c
      include = { account, _ in account == id }
    case .netWorth(let c):
      currency = c
      var all = Set(snapshot.start.accounts.map(\.currency)).union(actual.currencies.values)
      all.formUnion(snapshot.start.debts.keys)
      for terms in actual.debts.values { all.formUnion(terms.keys) }
      unconverted = all.filter { rates.rate(from: $0, to: c) == nil }
      let missing = unconverted
      include = { _, accountCurrency in !missing.contains(accountCurrency) }
    }
    let isNetWorth = if case .netWorth = selection { true } else { false }
    func value(_ minor: Int64, _ from: Currency) -> Int64 { rates.convert(minor, from: from, to: currency) ?? 0 }

    // Forecast: start + item effects, an overdue item counting on the snapshot day.
    var forecastValues = [Int64](repeating: 0, count: horizon + 1)
    var base: Int64 = 0
    for account in snapshot.start.accounts where include(account.accountID, account.currency) {
      base += value(account.balanceMinor, account.currency)
    }
    if isNetWorth {
      for (c, minor) in snapshot.start.debts where !unconverted.contains(c) { base += value(minor, c) }
    }
    let startCurrency = Dictionary(uniqueKeysWithValues: snapshot.start.accounts.map { ($0.accountID, $0.currency) })
    var deltas = [Int64](repeating: 0, count: horizon + 1)
    for item in snapshot.items {
      guard let day = Day(item.day) else { continue }
      let index = max(0, taken.daysUntil(day))
      guard index <= horizon else { continue }
      for (account, amount) in effects(item) {
        guard let c = startCurrency[account], include(account, c) else { continue }
        deltas[index] += value(amount, c)
      }
    }
    var running = base
    for i in 0...horizon {
      running += deltas[i]
      forecastValues[i] = running
    }
    let forecast = (0...horizon).map { ForecastPoint(day: taken.plusDays($0), valueMinor: forecastValues[$0]) }

    // Actual: daily balances from the snapshot day to today, clamped to the data available.
    var actualPoints: [ForecastPoint] = []
    for (i, day) in actual.days.enumerated() where day >= taken && day <= today {
      var total: Int64 = 0
      for (account, values) in actual.balances where i < values.count {
        guard let c = actual.currencies[account], include(account, c) else { continue }
        total += value(values[i], c)
      }
      if isNetWorth {
        for (c, minor) in actual.debts[day] ?? [:] where !unconverted.contains(c) { total += value(minor, c) }
      }
      actualPoints.append(ForecastPoint(day: day, valueMinor: total))
    }

    // Gap at the last actual day inside the horizon.
    guard let gapPoint = actualPoints.last(where: { $0.day <= horizonEnd }) else {
      return ForecastOverlay(
        selection: selection, currency: currency, forecast: forecast, actual: actualPoints, gapDay: nil,
        actualAtGap: nil, forecastAtGap: nil, unconverted: unconverted, split: nil)
    }
    let gapDay = gapPoint.day
    let forecastAtGap = forecastValues[taken.daysUntil(gapDay)]
    let gap = gapPoint.valueMinor - forecastAtGap

    // Split: what the snapshot's own occurrences did versus what it expected, up to the gap day.
    var resolved: [OccurrenceKey: ScheduledOccurrence] = [:]
    for occurrence in occurrences {
      guard let day = Day(occurrence.expectedDay) else { continue }
      resolved[OccurrenceKey(itemID: occurrence.itemID, day: day)] = occurrence
    }
    var scheduled: Int64 = 0
    for item in snapshot.items {
      guard let day = Day(item.day) else { continue }
      let effectDay = max(day, taken)
      let counted = effects(item).filter { account, _ in
        guard let c = startCurrency[account] else { return false }
        return include(account, c)
      }
      if effectDay <= gapDay {
        for (account, amount) in counted { scheduled -= value(amount, startCurrency[account]!) }
      }
      guard let itemID = item.itemID, let occurrence = resolved[OccurrenceKey(itemID: itemID, day: day)],
        occurrence.status == .paid, let paidDay = occurrence.actualDay.flatMap(Day.init), paidDay > taken,
        paidDay <= gapDay
      else { continue }
      let paid = occurrence.actualAmountMinor ?? occurrence.expectedAmountMinor
      for (account, amount) in counted {
        scheduled += value(scaled(amount, paid: paid, expected: abs(item.amountMinor)), startCurrency[account]!)
      }
    }
    return ForecastOverlay(
      selection: selection, currency: currency, forecast: forecast, actual: actualPoints, gapDay: gapDay,
      actualAtGap: gapPoint.valueMinor, forecastAtGap: forecastAtGap, unconverted: unconverted,
      split: ForecastGapSplit(scheduledMinor: scheduled, otherMinor: gap - scheduled))
  }

  static func effects(_ item: ForecastSnapshotItem) -> [(Account.ID, Int64)] {
    var result = [(item.accountID, item.amountMinor)]
    if let to = item.toAccountID, let amount = item.toAmountMinor { result.append((to, amount)) }
    return result
  }

  /// A forecast effect rescaled to what was paid: same sign, `paid / expected` of it (a transfer's
  /// received side follows the paid amount proportionally).
  static func scaled(_ amount: Int64, paid: Int64, expected: Int64) -> Int64 {
    guard expected != 0 else { return amount }
    if abs(amount) == expected { return amount < 0 ? -paid : paid }
    var result = Decimal(amount) * Decimal(paid) / Decimal(expected)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &result, 0, .bankers)
    return NSDecimalNumber(decimal: rounded).int64Value
  }
}
