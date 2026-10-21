import Foundation
import SQLiteData

/// Account and display currencies (R-CUR-1). Original purchase amounts may use any ISO 4217
/// code and are stored as plain strings instead (R-CUR-4).
public enum Currency: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case UAH, PLN, EUR, USD

  /// All four currencies have 2 decimal places.
  public static let minorUnitsPerUnit: Int64 = 100
}

/// An exact amount in integer minor units (R-CUR-2). Use `Decimal` for math, never `Double`.
public struct Money: Hashable, Codable, Sendable {
  public var minorUnits: Int64
  public var currency: Currency

  public init(minorUnits: Int64, currency: Currency) {
    self.minorUnits = minorUnits
    self.currency = currency
  }

  /// Rounds to minor units with banker's rounding.
  public init(_ amount: Decimal, _ currency: Currency) {
    self.init(minorUnits: Money.minorUnits(from: amount), currency: currency)
  }

  public static func zero(_ currency: Currency) -> Money {
    Money(minorUnits: 0, currency: currency)
  }

  public var decimal: Decimal {
    Decimal(minorUnits) / Decimal(Currency.minorUnitsPerUnit)
  }

  public var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }

  public static func + (lhs: Money, rhs: Money) -> Money {
    precondition(lhs.currency == rhs.currency, "Adding \(lhs.currency) to \(rhs.currency)")
    return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
  }

  public static func - (lhs: Money, rhs: Money) -> Money { lhs + rhs.negated }

  /// Banker's rounding of a decimal amount to minor units.
  public static func minorUnits(from amount: Decimal) -> Int64 {
    var scaled = amount * Decimal(Currency.minorUnitsPerUnit)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .bankers)
    return NSDecimalNumber(decimal: rounded).int64Value
  }
}
