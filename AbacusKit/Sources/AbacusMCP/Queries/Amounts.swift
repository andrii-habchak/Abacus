import AbacusDomain
import Foundation

/// An amount for the client: a decimal string and a currency, never a float.
public struct MoneyDTO: Codable, Hashable, Sendable {
  public let amount: String
  public let currency: String

  public init(minor: Int64, currency: Currency) {
    self.amount = Amounts.string(minor: minor)
    self.currency = currency.rawValue
  }

  public init(_ money: Money) { self.init(minor: money.minorUnits, currency: money.currency) }

  public init(minor: Int64, code: String) {
    self.amount = Amounts.string(minor: minor, digits: CurrencyDigits.minorUnits(code))
    self.currency = code.uppercased()
  }
}

public enum Amounts {
  /// `-12345` → `"-123.45"` by integer math (two minor digits unless `digits` says otherwise).
  public static func string(minor: Int64, digits: Int = 2) -> String {
    guard digits > 0 else { return String(minor) }
    var scale: Int64 = 1
    for _ in 0..<digits { scale *= 10 }
    let magnitude = minor.magnitude
    let whole = magnitude / UInt64(scale)
    let fraction = String(magnitude % UInt64(scale))
    let padded = String(repeating: "0", count: digits - fraction.count) + fraction
    return (minor < 0 ? "-" : "") + "\(whole).\(padded)"
  }

  /// Parses a decimal amount such as `"12.5"`, `"-3"` or `"1 234,50"` into minor units; nil when
  /// it is not a number or has more fractional digits than `digits`.
  public static func minor(from text: String, digits: Int = 2) -> Int64? {
    let cleaned = text.filter { !$0.isWhitespace }.replacing(",", with: ".")
    guard !cleaned.isEmpty else { return nil }
    var sign: Int64 = 1
    var body = Substring(cleaned)
    if body.hasPrefix("-") {
      sign = -1
      body = body.dropFirst()
    } else if body.hasPrefix("+") {
      body = body.dropFirst()
    }
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isASCII), whole.allSatisfy(\.isNumber) else {
      return nil
    }
    var fraction = parts.count == 2 ? String(parts[1]) : ""
    guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }), fraction.count <= digits else { return nil }
    fraction += String(repeating: "0", count: digits - fraction.count)
    guard let wholeValue = Int64(whole), let fractionValue = Int64(fraction.isEmpty ? "0" : fraction) else { return nil }
    var scale: Int64 = 1
    for _ in 0..<digits { scale *= 10 }
    let (scaled, overflow) = wholeValue.multipliedReportingOverflow(by: scale)
    guard !overflow else { return nil }
    return sign * (scaled + fractionValue)
  }
}

/// Nothing is known about rates: only same-currency amounts convert. The fallback when the app's
/// rate table cannot be built; every other amount is reported as unconverted.
public struct NoRates: CurrencyConverter {
  public init() {}
  public func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { from == to ? 1 : nil }
  public func latestRate(from: Currency, to: Currency) -> Decimal? { from == to ? 1 : nil }
  public var latestDay: Day? { nil }
}
