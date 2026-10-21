import AbacusDomain
import Foundation

/// Amount text of the editor fields ↔ exact minor units (R-CUR-2). Typing accepts either
/// decimal separator and grouping spaces: "86.40", "86,40", "1 234,56", "1,234.56".
public enum EditorAmount {
  /// The typed amount, or nil when the text is empty, not a number, or negative.
  public static func decimal(_ text: String) -> Decimal? {
    var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    digits.removeAll { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" || $0 == "'" || $0 == "_" }
    guard !digits.isEmpty else { return nil }
    let dots = digits.filter { $0 == "." }.count
    let commas = digits.filter { $0 == "," }.count
    let decimalSeparator: Character?
    switch (dots, commas) {
    case (0, 0): decimalSeparator = nil
    case (1, 0): decimalSeparator = "."
    case (0, 1): decimalSeparator = ","
    case (_, 0), (0, _): decimalSeparator = nil  // "1.234.567": grouping only
    default:
      decimalSeparator = digits.lastIndex(of: ".")! > digits.lastIndex(of: ",")! ? "." : ","
    }
    var normalized = ""
    for character in digits {
      if character == decimalSeparator {
        normalized.append(".")
      } else if character == "." || character == "," {
        continue
      } else if character.isASCII, character.isNumber {
        normalized.append(character)
      } else {
        return nil
      }
    }
    guard normalized.contains(where: \.isNumber) else { return nil }
    return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
  }

  /// Minor units of `code` (banker's rounding to its digits, `CurrencyDigits`), or nil.
  public static func minor(_ text: String, code: String) -> Int64? {
    guard let value = decimal(text) else { return nil }
    return CurrencyDigits.minorUnits(from: value, code: code)
  }

  /// Field text for stored minor units: "86.40", "1234.00", "1500" (no grouping).
  public static func text(minor: Int64, code: String) -> String {
    let digits = CurrencyDigits.minorUnits(code)
    var value = Decimal(minor)
    for _ in 0..<digits { value /= 10 }
    return value.formatted(
      .number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
  }

  /// A rate with four decimals: "4.2920".
  public static func rateText(_ rate: Decimal) -> String {
    rate.formatted(
      .number.precision(.fractionLength(4)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
  }
}
