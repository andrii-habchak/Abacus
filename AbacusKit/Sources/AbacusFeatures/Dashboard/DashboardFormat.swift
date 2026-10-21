import AbacusDomain
import Foundation

/// Text formatting of the dashboard (approved prototype group 1). Numbers and dates follow
/// `locale` (system locale in the app); tests pin one.
public struct DashboardFormat: Sendable {
  public var locale: Locale
  public var calendar: Calendar

  public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
    self.locale = locale
    self.calendar = calendar
  }

  /// Whole units with a narrow symbol: "₴48,250", "-zł1,240".
  public func money(_ money: Money) -> String {
    money.decimal.formatted(
      .currency(code: money.currency.rawValue).presentation(.narrow).precision(.fractionLength(0)).locale(locale))
  }

  /// The magnitude only: "₴1,240" for −1,240.
  public func magnitude(_ value: Money) -> String {
    money(value.minorUnits < 0 ? value.negated : value)
  }

  /// "+₴1,240" / "−₴1,240" (true minus sign, as in the prototype).
  public func signed(_ value: Money) -> String {
    (value.minorUnits < 0 ? "−" : "+") + magnitude(value)
  }

  /// A liability total shown as owed: "−₴20,035" (or "₴0").
  public func owed(_ value: Money) -> String {
    value.minorUnits == 0 ? money(value) : "−" + magnitude(value)
  }

  /// Chart axis labels: "₴650K".
  public func compact(_ value: Decimal, _ currency: Currency) -> String {
    value.formatted(
      .currency(code: currency.rawValue).presentation(.narrow).notation(.compactName)
        .precision(.significantDigits(1...3)).locale(locale))
  }

  /// A fraction as a whole percent: 0.64 → "64%".
  public func percent(_ fraction: Decimal) -> String {
    (fraction * 100).formatted(.number.precision(.fractionLength(0)).locale(locale)) + "%"
  }

  /// A signed percent with one decimal: "+3.2%" / "−1.0%".
  public func signedPercent(_ fraction: Decimal) -> String {
    let magnitude = (fraction < 0 ? -fraction : fraction) * 100
    return (fraction < 0 ? "−" : "+") + magnitude.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "%"
  }

  /// "October 2026".
  public func month(_ month: Month) -> String {
    month.firstDay.date(calendar: calendar).formatted(dateStyle().month(.wide).year())
  }

  /// "September" (the "since end of September" line).
  public func monthName(_ month: Month) -> String {
    month.firstDay.date(calendar: calendar).formatted(dateStyle().month(.wide))
  }

  /// "Oct" (chart axis).
  public func shortMonth(_ month: Month) -> String {
    month.firstDay.date(calendar: calendar).formatted(dateStyle().month(.abbreviated))
  }

  /// "21 Oct 2026" (en_GB) / "Oct 21, 2026" (en_US).
  public func day(_ day: Day) -> String {
    day.date(calendar: calendar).formatted(dateStyle().day().month(.abbreviated).year())
  }

  private func dateStyle() -> Date.FormatStyle {
    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
  }
}
