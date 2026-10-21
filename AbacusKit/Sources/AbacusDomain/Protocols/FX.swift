import Foundation

/// Fetches official rates for a day from a remote source (WP A2: Frankfurter `providers=NBU`,
/// fallback NBU). Returned rates are tagged with the provider name.
public protocol RateProvider: Sendable {
  var name: String { get }
  func rates(on day: Day, base: Currency, quotes: [Currency]) async throws -> [FXRate]
}

/// Synchronous conversion over rates already loaded in memory, so aggregates over thousands of
/// transactions stay fast (R-FX-3, R-NF-2). Implemented by AbacusFX.
public protocol CurrencyConverter: Sendable {
  /// `1 from = rate to` on `day`; manual overrides win; weekends/holidays fall back to the most
  /// recent earlier rate; nil when nothing is known.
  func rate(from: Currency, to: Currency, on day: Day) -> Decimal?
  /// The most recent rate known (net worth).
  func latestRate(from: Currency, to: Currency) -> Decimal?
  /// The day the latest rates are from ("rates as of", R-FX-4).
  var latestDay: Day? { get }
}

extension CurrencyConverter {
  public func convert(_ money: Money, to currency: Currency, on day: Day) -> Money? {
    if money.currency == currency { return money }
    guard let rate = rate(from: money.currency, to: currency, on: day) else { return nil }
    return Money(money.decimal * rate, currency)
  }

  public func convertAtLatest(_ money: Money, to currency: Currency) -> Money? {
    if money.currency == currency { return money }
    guard let rate = latestRate(from: money.currency, to: currency) else { return nil }
    return Money(money.decimal * rate, currency)
  }
}
