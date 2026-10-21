import AbacusDomain
import Foundation

/// Display formatting shared by the shell, rates and settings. Numbers and dates follow the
/// given locale (system locale in the app, R-NF-4); tests pin one.
public struct Formats: Sendable {
  public var locale: Locale
  public var calendar: Calendar

  public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
    self.locale = locale
    self.calendar = calendar
  }

  private func dateStyle() -> Date.FormatStyle {
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    style = style.day().month(.abbreviated).year()
    return style
  }

  /// "21 Oct 2026" (en_GB).
  public func day(_ day: Day) -> String {
    day.date(calendar: calendar).formatted(dateStyle())
  }

  public func day(of date: Date) -> String {
    date.formatted(dateStyle())
  }

  /// "09:00" (en_GB).
  public func time(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
  }

  /// A rate with exactly `digits` fraction digits: "48.5012".
  public func rate(_ value: Decimal, digits: Int = 4) -> String {
    value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
  }

  /// A rate as typed by the user, 2–4 fraction digits: "48.20", "48.5012".
  public func manualRate(_ value: Decimal) -> String {
    value.formatted(.number.precision(.fractionLength(2...4)).grouping(.never).locale(locale))
  }

  /// "▲ 0.21%" / "▼ 0.25%" / "0.00%".
  public func change(_ percent: Decimal) -> String {
    var value = percent
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 2, .plain)
    let magnitude = (rounded < 0 ? -rounded : rounded)
      .formatted(.number.precision(.fractionLength(2)).locale(locale))
    if rounded == 0 { return "\(magnitude)%" }
    return (rounded > 0 ? "▲ " : "▼ ") + magnitude + "%"
  }

  /// Parses a typed decimal ("48,20" or "48.20"); nil when it is not a number.
  public func parseDecimal(_ text: String) -> Decimal? {
    var cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    let separator = locale.decimalSeparator ?? "."
    if separator != "." { cleaned = cleaned.replacingOccurrences(of: separator, with: ".") }
    if !cleaned.contains(".") { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
    guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
      cleaned.filter({ $0 == "." }).count <= 1
    else { return nil }
    return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
  }
}
