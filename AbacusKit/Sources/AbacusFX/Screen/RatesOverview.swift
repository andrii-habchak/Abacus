import AbacusDomain
import Foundation

/// Day-over-day change of a rate ("▲ 0.21 %" on the rates screen, R-FX-5).
public struct RateChange: Hashable, Sendable {
  public enum Direction: Hashable, Sendable { case up, down, flat }

  public var current: RateQuote
  public var previous: RateQuote

  public var delta: Decimal { current.rate - previous.rate }
  /// Percent, unrounded (`(current − previous) / previous × 100`).
  public var percent: Decimal { previous.rate == 0 ? 0 : delta / previous.rate * 100 }
  public var direction: Direction { delta > 0 ? .up : delta < 0 ? .down : .flat }
}

/// One point of a sparkline: the rate in effect on a calendar day.
public struct RatePoint: Hashable, Sendable {
  public var day: Day
  public var rate: Decimal
}

/// A row of "Today's rates": `1 currency = rate showIn` (R-FX-5).
public struct RateRow: Hashable, Sendable, Identifiable {
  public var currency: Currency
  public var showIn: Currency
  public var quote: RateQuote
  public var change: RateChange?
  public var series: [RatePoint]

  public var id: Currency { currency }
  /// "NBU" or "Manual".
  public var badge: String { quote.source.badge }
}

extension RateTable {
  /// The rate on `day` against the rate of the previous official day before the one it is from
  /// (so on a Saturday: Friday vs Thursday). Nil without both.
  public func dayChange(from: Currency, to: Currency, on day: Day) -> RateChange? {
    guard from != to, let current = quote(from: from, to: to, on: day) else { return nil }
    guard let previousDay = officialDays(before: current.day, for: [from, to], count: 1).first,
      let previous = quote(from: from, to: to, on: previousDay)
    else { return nil }
    return RateChange(current: current, previous: previous)
  }

  /// One point per calendar day for the `days` days ending on `endingOn` (weekends repeat the
  /// previous rate); days before any known rate are left out.
  public func series(from: Currency, to: Currency, endingOn end: Day, days: Int = 30) -> [RatePoint] {
    guard days > 0 else { return [] }
    let start = end.adding(days: -(days - 1), calendar: .fxDays)
    return HTTP.days(from: start, to: end, calendar: .fxDays).compactMap { day in
      rate(from: from, to: to, on: day).map { RatePoint(day: day, rate: $0) }
    }
  }
}

/// Builds the rates screen's table (R-FX-5).
public enum RatesOverview {
  /// Rows for every currency except `showIn`, as of `day` (normally today).
  public static func rows(
    _ table: RateTable, showIn: Currency, on day: Day, currencies: [Currency] = Currency.allCases,
    seriesDays: Int = 30
  ) -> [RateRow] {
    currencies.filter { $0 != showIn }.compactMap { currency in
      guard let quote = table.quote(from: currency, to: showIn, on: day) else { return nil }
      return RateRow(
        currency: currency, showIn: showIn, quote: quote,
        change: table.dayChange(from: currency, to: showIn, on: day),
        series: table.series(from: currency, to: showIn, endingOn: day, days: seriesDays))
    }
  }
}

/// How a manual rate applies ("on 15 Jan only" / "from 15 Jan until changed", R-FX-2).
public enum OverrideScope: Hashable, Sendable {
  case singleDay(Day)
  case fromDay(Day)
  case range(Day, Day)
}

extension FXOverride {
  public var scope: OverrideScope? {
    guard let from = Day(fromDay) else { return nil }
    guard let untilText = untilDay else { return .fromDay(from) }
    guard let until = Day(untilText) else { return nil }
    return until == from ? .singleDay(from) : .range(from, until)
  }

  /// `1 base = rate quote`.
  public var rate: Decimal { RateScale.decimal(rateE8) }

  /// A one-day override.
  public static func onDay(
    _ day: Day, base: Currency, quote: Currency, rate: Decimal, note: String = ""
  ) -> FXOverride {
    FXOverride(
      base: base, quote: quote, rateE8: RateScale.scaled(rate), fromDay: day.string,
      untilDay: day.string, note: note)
  }

  /// An override from `day` until changed.
  public static func from(
    _ day: Day, base: Currency, quote: Currency, rate: Decimal, note: String = ""
  ) -> FXOverride {
    FXOverride(
      base: base, quote: quote, rateE8: RateScale.scaled(rate), fromDay: day.string, note: note)
  }
}
