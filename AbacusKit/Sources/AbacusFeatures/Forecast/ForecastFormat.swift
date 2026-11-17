import AbacusDomain
import Foundation

/// Text of the Forecast tab (approved prototype `N5-forecast`): amounts with two decimals and a
/// true minus sign, short days ("18 Dec") and days with the weekday ("Tue 18 Dec").
public struct ForecastFormat: Sendable {
  public var base: DashboardFormat

  public init(_ base: DashboardFormat = DashboardFormat()) { self.base = base }

  public var calendar: Calendar { base.calendar }

  /// "−120.00 zł" / "₴48,250.00" (locale's currency style, narrow symbol, two decimals).
  public func money(_ minor: Int64, _ currency: Currency) -> String {
    let value = Money(minorUnits: minor, currency: currency)
    let text = magnitude(value)
    return minor < 0 ? "−" + text : text
  }

  /// "+120.00 zł" / "−120.00 zł".
  public func signed(_ minor: Int64, _ currency: Currency) -> String {
    (minor < 0 ? "−" : "+") + magnitude(Money(minorUnits: minor, currency: currency))
  }

  private func magnitude(_ value: Money) -> String {
    let positive = value.minorUnits < 0 ? value.negated : value
    return positive.decimal.formatted(
      .currency(code: value.currency.rawValue).presentation(.narrow).precision(.fractionLength(2)).locale(base.locale))
  }

  /// Chart axis: "₴650K".
  public func compact(_ minor: Int64, _ currency: Currency) -> String {
    let value = Money(minorUnits: minor, currency: currency).decimal
    return base.compact(value, currency)
  }

  /// "18 Dec".
  public func day(_ day: Day) -> String {
    day.date(calendar: calendar).formatted(style().day().month(.abbreviated))
  }

  /// "Tue 18 Dec".
  public func longDay(_ day: Day) -> String {
    day.date(calendar: calendar).formatted(style().weekday(.abbreviated).day().month(.abbreviated))
  }

  /// "3 Nov 2026".
  public func fullDay(_ day: Day) -> String { base.day(day) }

  /// "3.1 %" (one decimal, no sign).
  public func percent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)).locale(base.locale)) + " %"
  }

  /// "+3.1 %" / "−3.1 %" / "0".
  public func signedPercent(_ value: Double) -> String {
    if abs(value) < 0.05 { return "0" }
    return (value < 0 ? "−" : "+") + percent(abs(value))
  }

  /// "+2" / "−1" / "0" days.
  public func dayShift(_ days: Int) -> String {
    days == 0 ? "0" : (days > 0 ? "+\(days)" : "−\(-days)")
  }

  private func style() -> Date.FormatStyle {
    Date.FormatStyle(locale: base.locale, calendar: calendar, timeZone: calendar.timeZone)
  }
}
