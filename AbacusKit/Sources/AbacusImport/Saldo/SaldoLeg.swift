import AbacusDomain
import Foundation

/// Saldo's `Account Type` column (docs/import/saldo-format.md, "Account types").
enum SaldoAccountType: String, CaseIterable, Sendable {
  case bankAccounts = "BANK_ACCOUNTS"
  case cash = "CASH"
  case otherAssets = "OTHER_ASSETS"
  case liabilities = "LIABILITIES"
  case expenses = "EXPENSES"
  case income = "INCOME"
  case equity = "EQUITY"
  case moneyOnTheWay = "MONEY_ON_THE_WAY"

  /// Legs that are Abacus accounts ("asset" in the format doc, liabilities included).
  var isAccount: Bool { accountKind != nil }

  /// R-ACC-2: Saldo does not tell a bank account from a card, so both become `.bank`.
  var accountKind: AccountKind? {
    switch self {
    case .bankAccounts: .bank
    case .cash: .cash
    case .otherAssets: .investment
    case .liabilities: .debt
    case .expenses, .income, .equity, .moneyOnTheWay: nil
    }
  }
}

enum JournalSide: String, Sendable {
  case debit = "DEBIT"
  case credit = "CREDIT"
}

/// One CSV row of a Saldo export: a leg of a double-entry transaction.
struct SaldoLeg: Sendable {
  var transactionID: String
  var line: Int
  var date: Date
  var description: String
  var parentAccount: String
  var account: String
  /// Raw `Account Type`; `type` is nil when Saldo adds a type this parser does not know.
  var rawType: String
  var type: SaldoAccountType?
  var isArchived: Bool
  var side: JournalSide
  var amount: Decimal
  var currencyCode: String
  var tag: String
  var note: String

  var minorUnits: Int64 { MinorUnits.from(amount, currencyCode: currencyCode) }
  var accountKey: String { "\(account)|\(currencyCode)" }
}

/// Column lookup by header name, so a reordered export still parses.
struct SaldoHeader {
  static let transactionID = "Transaction ID"
  static let date = "Transaction Date"
  static let description = "Description"
  static let parentAccount = "Parent account"
  static let account = "Account"
  static let accountType = "Account Type"
  static let archived = "Archived"
  static let journalType = "Journal Type"
  static let amount = "Amount"
  static let currency = "Currency"
  static let tags = "Tags"
  static let notes = "Notes"

  static let required = [transactionID, date, account, accountType, journalType, amount, currency]
  /// Enough to tell a Saldo file from any other CSV.
  static let signature = [transactionID, accountType, journalType, "Accrual Month"]

  private let index: [String: Int]

  init?(_ fields: [String]) {
    var index: [String: Int] = [:]
    for (i, raw) in fields.enumerated() {
      let name = raw.trimmingCharacters(in: .whitespaces)
      if index[name] == nil { index[name] = i }
    }
    guard Self.required.allSatisfy({ index[$0] != nil }) else { return nil }
    self.index = index
  }

  func value(_ column: String, in fields: [String]) -> String {
    guard let i = index[column], i < fields.count else { return "" }
    return fields[i]
  }

  func leg(from record: CSVRecord, timeZone: TimeZone) throws -> SaldoLeg {
    let f = record.fields
    let line = record.line
    func field(_ column: String) -> String {
      value(column, in: f).trimmingCharacters(in: .whitespaces)
    }

    let id = field(Self.transactionID)
    guard !id.isEmpty else { throw ImportError.malformed(line: line, reason: "Empty Transaction ID") }
    guard let date = SaldoDate.parse(field(Self.date), timeZone: timeZone) else {
      throw ImportError.malformed(line: line, reason: "Unreadable Transaction Date")
    }
    guard let side = JournalSide(rawValue: field(Self.journalType).uppercased()) else {
      throw ImportError.malformed(line: line, reason: "Journal Type is neither DEBIT nor CREDIT")
    }
    guard let amount = SaldoAmount.parse(field(Self.amount)) else {
      throw ImportError.malformed(line: line, reason: "Unreadable Amount")
    }
    let currency = field(Self.currency).uppercased()
    guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }) else {
      throw ImportError.malformed(line: line, reason: "Currency is not an ISO 4217 code")
    }
    let rawType = field(Self.accountType).uppercased()
    return SaldoLeg(
      transactionID: id,
      line: line,
      date: date,
      description: value(Self.description, in: f),
      parentAccount: field(Self.parentAccount),
      account: field(Self.account),
      rawType: rawType,
      type: SaldoAccountType(rawValue: rawType),
      isArchived: field(Self.archived) == "1" || field(Self.archived).lowercased() == "true",
      side: side,
      amount: amount,
      currencyCode: currency,
      tag: field(Self.tags),
      note: value(Self.notes, in: f)
    )
  }
}

/// `Transaction Date`: local time without a zone in three shapes —
/// `2024-06-01T12:04:15`, `2025-02-27T12:27:24.835`, `2025-08-12T07:12`.
enum SaldoDate {
  static func parse(_ string: String, timeZone: TimeZone) -> Date? {
    let parts = string.split(separator: "T", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let ymd = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    let hms = parts[1].split(separator: ":", omittingEmptySubsequences: false)
    guard ymd.count == 3, hms.count == 2 || hms.count == 3,
      let year = Int(ymd[0]), let month = Int(ymd[1]), let day = Int(ymd[2]),
      let hour = Int(hms[0]), let minute = Int(hms[1]),
      (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute)
    else { return nil }

    var second = 0
    var nanosecond = 0
    if hms.count == 3 {
      let sec = hms[2].split(separator: ".", omittingEmptySubsequences: false)
      guard sec.count <= 2, let s = Int(sec[0]), (0...60).contains(s) else { return nil }
      second = s
      if sec.count == 2 {
        let digits = sec[1]
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCII), let fraction = Int(digits) else {
          return nil
        }
        nanosecond = fraction
        for _ in digits.count..<9 { nanosecond *= 10 }
      }
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute, second: second,
      nanosecond: nanosecond)
    return calendar.date(from: components)
  }
}

/// `Amount`: a positive decimal with `.` as separator (`1234.56`).
enum SaldoAmount {
  static func parse(_ string: String) -> Decimal? {
    guard !string.isEmpty,
      string.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
      string.filter({ $0 == "." }).count <= 1
    else { return nil }
    return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
  }
}

/// Minor units of any ISO 4217 currency (the file always writes 2 decimals; original amounts
/// may be in currencies with another exponent).
enum MinorUnits {
  private static let exponentZero: Set<String> = [
    "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND",
    "VUV", "XAF", "XOF", "XPF",
  ]
  private static let exponentThree: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

  static func exponent(_ currencyCode: String) -> Int {
    if exponentZero.contains(currencyCode) { return 0 }
    if exponentThree.contains(currencyCode) { return 3 }
    return 2
  }

  /// Banker's rounding to the currency's minor unit (R-CUR-2).
  static func from(_ amount: Decimal, currencyCode: String) -> Int64 {
    var scaled = amount
    for _ in 0..<exponent(currencyCode) { scaled *= 10 }
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .bankers)
    return NSDecimalNumber(decimal: rounded).int64Value
  }
}

/// Splits `total` across `weights` in proportion, exactly (largest remainder, ties to the
/// earlier index). Equal split when every weight is zero.
enum ProRata {
  static func split(_ total: Int64, weights: [Int64]) -> [Int64] {
    guard !weights.isEmpty else { return [] }
    let positive = weights.map { max($0, 0) }
    let sum = positive.reduce(Int128(0)) { $0 + Int128($1) }
    let effective = sum == 0 ? Array(repeating: Int64(1), count: weights.count) : positive
    let weightSum = sum == 0 ? Int128(weights.count) : sum
    let magnitude = Int128(total.magnitude)

    var shares: [Int128] = []
    var remainders: [(index: Int, remainder: Int128)] = []
    for (i, w) in effective.enumerated() {
      let product = magnitude * Int128(w)
      shares.append(product / weightSum)
      remainders.append((i, product % weightSum))
    }
    var left = magnitude - shares.reduce(0, +)
    for entry in remainders.sorted(by: { $0.remainder != $1.remainder ? $0.remainder > $1.remainder : $0.index < $1.index }) {
      guard left > 0 else { break }
      shares[entry.index] += 1
      left -= 1
    }
    return shares.map { total < 0 ? -Int64($0) : Int64($0) }
  }
}
