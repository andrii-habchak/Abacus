import Foundation

/// Amount parsing for PKO exports. Exact integer arithmetic only (R-CUR-2).
enum PKOAmount {
  /// Signed minor units of `"-17.35"`, `"+120.00"`, `"1 000,00"` (space or no-break-space
  /// thousands, dot or comma decimals). `nil` when the text is not an amount or has more
  /// significant decimals than the currency allows.
  static func minorUnits(_ text: String, digits: Int = 2) -> Int64? {
    var body = Substring(text.filter { !$0.isWhitespace })
    var negative = false
    if body.first == "-" || body.first == "+" {
      negative = body.first == "-"
      body = body.dropFirst()
    }
    guard !body.isEmpty else { return nil }

    // The last separator is the decimal one; earlier ones are thousands separators.
    var integerPart = body
    var fraction = Substring("")
    if let separator = body.lastIndex(where: { $0 == "." || $0 == "," }) {
      integerPart = Substring(body[..<separator].filter { $0 != "." && $0 != "," })
      fraction = body[body.index(after: separator)...]
    }
    guard !integerPart.isEmpty || !fraction.isEmpty,
      integerPart.allSatisfy(\.isASCIIDigit), fraction.allSatisfy(\.isASCIIDigit),
      integerPart.count <= 15
    else { return nil }

    // Extra decimals are accepted only when they are zeros (e.g. "1000.00" for a 0-digit currency).
    var significant = fraction
    while significant.count > digits {
      guard significant.last == "0" else { return nil }
      significant = significant.dropLast()
    }
    let padded = significant + String(repeating: "0", count: digits - significant.count)
    guard let value = Int64(String(integerPart.isEmpty ? "0" : integerPart) + padded) else {
      return nil
    }
    return negative ? -value : value
  }

  /// ISO 4217 minor-unit digits; 2 unless the currency is a known exception.
  static func minorDigits(currencyCode: String) -> Int {
    if zeroDigitCurrencies.contains(currencyCode) { return 0 }
    if threeDigitCurrencies.contains(currencyCode) { return 3 }
    return 2
  }

  private static let zeroDigitCurrencies: Set<String> = [
    "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND",
    "VUV", "XAF", "XOF", "XPF",
  ]
  private static let threeDigitCurrencies: Set<String> = [
    "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND",
  ]
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
