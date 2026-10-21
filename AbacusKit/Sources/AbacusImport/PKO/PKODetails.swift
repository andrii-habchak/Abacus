import Foundation

/// Keys of the `Key: value` detail columns (7–12) of a PKO export.
enum PKODetailKey: String, CaseIterable {
  case title = "Tytuł"
  case location = "Lokalizacja"
  case executionDate = "Data wykonania operacji"
  case originalAmount = "Oryginalna kwota operacji"
  case cardNumber = "Numer karty"
  case recipientAccount = "Rachunek odbiorcy"
  case recipientName = "Nazwa odbiorcy"
  case recipientAddress = "Adres odbiorcy"
  case senderAccount = "Rachunek nadawcy"
  case senderName = "Nazwa nadawcy"
  case senderAddress = "Adres nadawcy"
  case phoneNumber = "Numer telefonu"
  case operation = "Operacja"
  case referenceNumber = "Numer referencyjny"
  case ownReferences = "Referencje własne zleceniodawcy"
  case atm = "Bankomat"
}

/// The detail columns of one row, keyed. Columns come in any order and count; a column
/// without a colon is kept as unkeyed text.
struct PKODetails {
  private(set) var values: [String: String] = [:]
  private(set) var unkeyed: [String] = []
  /// Non-empty trimmed columns in file order (fingerprint input).
  private(set) var columns: [String] = []

  init(columns raw: some Sequence<String>) {
    for column in raw {
      let text = column.pkoTrimmed
      guard !text.isEmpty else { continue }
      columns.append(text)
      guard let colon = text.firstIndex(of: ":") else {
        unkeyed.append(text)
        continue
      }
      // Some keys carry a spreadsheet text prefix: `'Operacja: …`.
      var key = String(text[..<colon]).pkoTrimmed
      while key.hasPrefix("'") { key.removeFirst() }
      let value = String(text[text.index(after: colon)...]).pkoTrimmed
      if values[key] == nil { values[key] = value }
    }
  }

  subscript(key: PKODetailKey) -> String? {
    guard let value = values[key.rawValue], !value.isEmpty else { return nil }
    return value
  }

  /// `Lokalizacja: Adres: … Miasto: … Kraj: …` → the part after `Adres:` (the merchant).
  var merchant: String? {
    guard let location = self[.location] else { return nil }
    let parts = Self.labelled(location, labels: ["Adres", "Miasto", "Kraj"])
    let merchant = (parts["Adres"] ?? "").pkoCollapsed
    return merchant.isEmpty ? nil : merchant
  }

  /// Recipient for outgoing rows, sender for incoming ones; whichever the row has.
  var counterpartyName: String? {
    (self[.recipientName] ?? self[.senderName]).map(\.pkoCollapsed)
  }

  /// The counterparty account number without spaces (R-IMP-PKO-3).
  var counterpartyAccount: String? {
    guard let raw = self[.recipientAccount] ?? self[.senderAccount] else { return nil }
    let compact = raw.filter { !$0.isWhitespace }.uppercased()
    return compact.isEmpty ? nil : compact
  }

  /// `Oryginalna kwota operacji: 17.35` or `… 10.00 EUR` → amount text and currency code (if
  /// written).
  var originalAmount: (amount: String, currencyCode: String?)? {
    guard let raw = self[.originalAmount] else { return nil }
    var tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var code: String?
    if let last = tokens.last, last.count == 3, last.allSatisfy({ $0.isASCII && $0.isUppercase }) {
      code = last
      tokens.removeLast()
    }
    guard !tokens.isEmpty else { return nil }
    return (tokens.joined(separator: " "), code)
  }

  /// Splits `"Adres: X Miasto: Y Kraj: Z"` on known labels; text before the first label is
  /// dropped.
  static func labelled(_ text: String, labels: [String]) -> [String: String] {
    var marks: [(label: String, range: Range<String.Index>)] = []
    for label in labels {
      if let range = text.range(of: label + ":") { marks.append((label, range)) }
    }
    marks.sort { $0.range.lowerBound < $1.range.lowerBound }
    var result: [String: String] = [:]
    for (index, mark) in marks.enumerated() {
      let end = index + 1 < marks.count ? marks[index + 1].range.lowerBound : text.endIndex
      result[mark.label] = String(text[mark.range.upperBound..<end]).pkoTrimmed
    }
    return result
  }
}
