import AbacusDomain
import Foundation

/// Where a rate on the rates screen comes from (the source badge).
public enum RateSourceBadge: String, Hashable, Sendable {
  case nbu = "NBU"
  case manual = "Manual"
}

/// One point of a 30-day sparkline: the rate in effect on a calendar day.
public struct RateSeriesPoint: Hashable, Sendable, Identifiable {
  public var day: Day
  public var rate: Decimal
  public var id: Day { day }

  public init(day: Day, rate: Decimal) {
    self.day = day
    self.rate = rate
  }
}

/// A row of "Today's rates": `1 currency = rate showIn` (R-FX-5).
public struct RateRowData: Hashable, Sendable, Identifiable {
  public var currency: Currency
  public var showIn: Currency
  public var rate: Decimal
  /// Percent change against the previous official day (nil without one).
  public var changePercent: Decimal?
  public var series: [RateSeriesPoint]
  public var source: RateSourceBadge
  public var id: Currency { currency }

  public init(
    currency: Currency, showIn: Currency, rate: Decimal, changePercent: Decimal?,
    series: [RateSeriesPoint], source: RateSourceBadge
  ) {
    self.currency = currency
    self.showIn = showIn
    self.rate = rate
    self.changePercent = changePercent
    self.series = series
    self.source = source
  }
}

/// Builds the rates screen's table from cached official rates and manual overrides (R-FX-2,
/// R-FX-5). Rates are cross rates through UAH; a weekend or holiday uses the most recent earlier
/// official day; a manual rate wins for its days — for its exact pair, the inverse pair, or
/// against UAH. Mirrors WP A2's `RatesOverview`, which can replace it when the real refresher is
/// wired.
public struct RatesTable: Sendable {
  /// UAH per 1 unit, per official day.
  private let official: [Day: [Currency: Decimal]]
  /// Ascending.
  public let officialDays: [Day]
  public let overrides: [FXOverride]

  public init(rates: [FXRate], overrides: [FXOverride]) {
    var official: [Day: [Currency: Decimal]] = [:]
    for rate in rates {
      guard let day = Day(rate.day), rate.rateE8 > 0 else { continue }
      let value = RateScale.decimal(rate.rateE8)
      if rate.quote == .UAH, rate.base != .UAH {
        official[day, default: [:]][rate.base] = value
      } else if rate.base == .UAH, rate.quote != .UAH {
        official[day, default: [:]][rate.quote] = 1 / value
      }
    }
    self.official = official
    self.officialDays = official.keys.sorted()
    self.overrides = overrides
  }

  /// The newest official day on or before `day` ("rates as of", R-FX-4).
  public func officialDay(onOrBefore day: Day) -> Day? {
    officialDays.last { $0 <= day }
  }

  /// UAH per 1 `currency` from the official rates, falling back to earlier days.
  func officialUAH(_ currency: Currency, on day: Day) -> Decimal? {
    if currency == .UAH { return 1 }
    for officialDay in officialDays.reversed() where officialDay <= day {
      if let value = official[officialDay]?[currency] { return value }
    }
    return nil
  }

  /// The manual rate for `1 from = r to` in effect on `day`, if any (latest start wins).
  func overrideRate(from: Currency, to: Currency, on day: Day) -> Decimal? {
    let active = overrides
      .filter { applies($0, on: day) && (($0.base == from && $0.quote == to) || ($0.base == to && $0.quote == from)) }
      .max { $0.fromDay < $1.fromDay }
    guard let active, active.rateE8 > 0 else { return nil }
    let value = RateScale.decimal(active.rateE8)
    return active.base == from ? value : 1 / value
  }

  func applies(_ override: FXOverride, on day: Day) -> Bool {
    guard override.fromDay <= day.string else { return false }
    guard let until = override.untilDay else { return true }
    return day.string <= until
  }

  /// UAH per 1 `currency`, a manual rate against UAH winning.
  func uah(_ currency: Currency, on day: Day) -> (Decimal, RateSourceBadge)? {
    if currency == .UAH { return (1, .nbu) }
    if let manual = overrideRate(from: currency, to: .UAH, on: day) { return (manual, .manual) }
    return officialUAH(currency, on: day).map { ($0, .nbu) }
  }

  /// `1 from = rate to` on `day`, manual rates winning; nil when nothing is known.
  public func quote(from: Currency, to: Currency, on day: Day) -> (rate: Decimal, source: RateSourceBadge)? {
    if from == to { return (1, .nbu) }
    if let manual = overrideRate(from: from, to: to, on: day) { return (manual, .manual) }
    guard let (fromUAH, fromSource) = uah(from, on: day), let (toUAH, toSource) = uah(to, on: day),
      toUAH != 0
    else { return nil }
    let source: RateSourceBadge = fromSource == .manual || toSource == .manual ? .manual : .nbu
    return (fromUAH / toUAH, source)
  }

  /// The official (fetched) rate only — the "fetched: …" hint of the add form.
  public func fetchedRate(from: Currency, to: Currency, on day: Day) -> Decimal? {
    if from == to { return 1 }
    guard let fromUAH = officialUAH(from, on: day), let toUAH = officialUAH(to, on: day), toUAH != 0 else {
      return nil
    }
    return fromUAH / toUAH
  }

  /// Rows for every currency except `showIn`, as of `day` (normally today).
  public func rows(showIn: Currency, on day: Day, seriesDays: Int = 30) -> [RateRowData] {
    Currency.allCases.filter { $0 != showIn }.compactMap { currency in
      guard let (rate, source) = quote(from: currency, to: showIn, on: day) else { return nil }
      return RateRowData(
        currency: currency, showIn: showIn, rate: rate,
        changePercent: changePercent(from: currency, to: showIn, on: day),
        series: series(from: currency, to: showIn, endingOn: day, days: seriesDays),
        source: source)
    }
  }

  /// The rate on `day` against the previous official day before the one it is from (so on a
  /// Saturday: Friday vs Thursday), in percent.
  public func changePercent(from: Currency, to: Currency, on day: Day) -> Decimal? {
    guard let current = officialDay(onOrBefore: day),
      let index = officialDays.firstIndex(of: current), index > 0,
      let now = quote(from: from, to: to, on: day)?.rate,
      let before = quote(from: from, to: to, on: officialDays[index - 1])?.rate,
      before != 0
    else { return nil }
    return (now - before) / before * 100
  }

  /// One point per calendar day for the `days` days ending on `end`; days before any known
  /// rate are left out.
  public func series(from: Currency, to: Currency, endingOn end: Day, days: Int = 30) -> [RateSeriesPoint] {
    guard days > 0 else { return [] }
    return (0..<days).reversed().compactMap { back in
      let day = end.adding(days: -back)
      return quote(from: from, to: to, on: day).map { RateSeriesPoint(day: day, rate: $0.rate) }
    }
  }
}
