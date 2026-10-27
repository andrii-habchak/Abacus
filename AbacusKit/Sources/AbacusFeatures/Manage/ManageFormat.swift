import AbacusDomain
import Foundation

/// Text formatting and amount parsing of the management screens (approved prototype group 4).
/// Numbers and dates follow `locale` (the system locale in the app); tests pin one.
public struct ManageFormat: Sendable {
  public var locale: Locale
  public var calendar: Calendar

  public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
    self.locale = locale
    self.calendar = calendar
  }

  /// Two decimals with a narrow symbol: "₴48,250.00", "-zł1,240.00".
  public func money(_ money: Money) -> String {
    money.decimal.formatted(
      .currency(code: money.currency.rawValue).presentation(.narrow).precision(.fractionLength(2)).locale(locale))
  }

  /// The value of an amount field: "4000.00" (no grouping, the locale's decimal separator).
  public func amountInput(_ minor: Int64) -> String {
    (Decimal(minor) / Decimal(Currency.minorUnitsPerUnit)).formatted(
      .number.precision(.fractionLength(2)).grouping(.never).locale(locale))
  }

  /// Parses what the user typed into an amount field into minor units: "1 234,50", "1,234.50",
  /// "1234.5", "-8000", "−8 000". Currency symbols, codes and spaces are ignored. nil when it is
  /// not a number.
  public func parseAmount(_ text: String) -> Int64? {
    var negative = false
    var kept = ""
    for character in text {
      if character.isNumber, character.isASCII {
        kept.append(character)
      } else if character == "," || character == "." {
        kept.append(character)
      } else if character == "-" || character == "−" {
        negative = true
      }
    }
    guard kept.contains(where: \.isNumber) else { return nil }
    let commas = kept.filter { $0 == "," }.count
    let dots = kept.filter { $0 == "." }.count
    var normalized: String
    if commas > 0, dots > 0 {
      // The last separator is the decimal one.
      let decimalIsComma = kept.lastIndex(of: ",")! > kept.lastIndex(of: ".")!
      normalized = kept.replacingOccurrences(of: decimalIsComma ? "." : ",", with: "")
      if decimalIsComma { normalized = normalized.replacingOccurrences(of: ",", with: ".") }
    } else if commas > 0 {
      let digitsAfter = kept.split(separator: ",", omittingEmptySubsequences: false).last?.count ?? 0
      normalized =
        commas == 1 && digitsAfter != 3
        ? kept.replacingOccurrences(of: ",", with: ".")
        : kept.replacingOccurrences(of: ",", with: "")
    } else if dots > 1 {
      normalized = kept.replacingOccurrences(of: ".", with: "")
    } else {
      normalized = kept
    }
    guard normalized.filter({ $0 == "." }).count <= 1, let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    let minor = Money.minorUnits(from: value)
    return negative ? -minor : minor
  }

  /// "October 2026".
  public func month(_ month: Month) -> String {
    month.firstDay.date(calendar: calendar).formatted(dateStyle().month(.wide).year())
  }

  /// "21 Oct 2026" (en_GB) / "Oct 21, 2026" (en_US).
  public func day(_ day: Day) -> String {
    day.date(calendar: calendar).formatted(dateStyle().day().month(.abbreviated).year())
  }

  /// An event's dates as in the prototype: "01.10 – 19.10.2026", "No dates (ongoing)";
  /// "From 01.10.2026" / "Until 19.10.2026" with one end only.
  public func dateRange(start: Day?, end: Day?) -> String {
    func short(_ day: Day) -> String { String(format: "%02d.%02d", day.day, day.month) }
    func long(_ day: Day) -> String { String(format: "%02d.%02d.%04d", day.day, day.month, day.year) }
    switch (start, end) {
    case (nil, nil): return "No dates (ongoing)"
    case (let start?, nil): return "From \(long(start))"
    case (nil, let end?): return "Until \(long(end))"
    case (let start?, let end?):
      return start.year == end.year ? "\(short(start)) – \(long(end))" : "\(long(start)) – \(long(end))"
    }
  }

  private func dateStyle() -> Date.FormatStyle {
    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
  }
}

/// Fixed copy of the management screens.
public enum ManageText {
  /// R-ACC-2 kinds as the prototype names them.
  public static func kindTitle(_ kind: AccountKind) -> String {
    switch kind {
    case .cash: "Cash"
    case .bank: "Bank account"
    case .card: "Card"
    case .savings: "Savings / deposit"
    case .investment: "Investment"
    case .creditCard: "Credit card"
    case .loan: "Loan"
    case .debt: "Debt (person)"
    }
  }

  public static let assetKinds: [AccountKind] = AccountKind.allCases.filter { !$0.isLiability }
  public static let liabilityKinds: [AccountKind] = AccountKind.allCases.filter(\.isLiability)

  /// The symbol on an account's tile: "₴", "zł", "€", "$".
  public static func symbol(_ currency: Currency) -> String {
    switch currency {
    case .UAH: "₴"
    case .PLN: "zł"
    case .EUR: "€"
    case .USD: "$"
    }
  }

  /// "Food › Groceries" for a subcategory, "Health" for a top-level one.
  public static func categoryPath(_ id: AbacusDomain.Category.ID, tree: CategoryTree) -> String {
    guard let category = tree.category(id) else { return "Unknown category" }
    guard let parent = category.parentID.flatMap(tree.category) else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  /// "1 transaction" / "124 transactions".
  public static func transactions(_ count: Int) -> String {
    count == 1 ? "1 transaction" : "\(count) transactions"
  }

  /// The colour swatches of the category, account and event inspectors (R-MGMT-7).
  public static let swatches = ColorPalette.colors
}
