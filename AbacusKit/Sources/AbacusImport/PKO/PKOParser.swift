import AbacusDomain
import Foundation

/// Parses a PKO BP "Zestawienie operacji" CSV (`docs/import/pko-format.md`, R-IMP-PKO-1…3).
///
/// The file names neither the account nor its currency, so the parser is created for the
/// Abacus account the user picked; every row is booked on it (`resolvedID` is set).
///
/// What the pipeline (A6) gets beyond plain expense/income rows:
/// - holds (`Blokada`): `isPending`, dated by the value date, a hold fingerprint;
/// - ATM withdrawals: `.transfer` to `cashAccount(currency:)`, which the user maps once;
/// - currency exchanges: `.transferHalf` with the foreign amount as `transit`;
/// - any row with a counterparty account number: `counterpartyIBAN`, for own-account transfers.
public struct PKOParser: ImportParser {
  public static let source: ImportSource = .pko

  /// Name of the external cash account ATM withdrawals go to.
  public static let cashAccountName = "Cash"

  /// The first seven header fields; the last five are unnamed.
  static let header = [
    "Data operacji", "Data waluty", "Typ transakcji", "Kwota", "Waluta", "Saldo po transakcji",
    "Opis transakcji",
  ]

  public let accountID: Account.ID
  public let account: ExternalAccount
  public let calendar: Calendar

  public init(account: Account, calendar: Calendar = .current) {
    self.accountID = account.id
    self.account = ExternalAccount(
      name: account.name, currency: account.currency, kind: account.kind,
      isArchived: account.isArchived, iban: account.iban, resolvedID: account.id)
    self.calendar = calendar
  }

  public init(accountID: Account.ID, currency: Currency, name: String = "PKO BP", calendar: Calendar = .current) {
    self.accountID = accountID
    self.account = ExternalAccount(name: name, currency: currency, kind: .bank, resolvedID: accountID)
    self.calendar = calendar
  }

  /// The external cash account an ATM withdrawal in `currency` moves money to.
  public static func cashAccount(currency: Currency) -> ExternalAccount {
    ExternalAccount(name: cashAccountName, currency: currency, kind: .cash)
  }

  // MARK: Detection

  public static func canParse(_ data: Data) -> Bool {
    guard let text = PKOText.decode(data.prefix(1024)),
      let first = PKOText.records(text).first
    else { return false }
    return isHeader(first.fields)
  }

  static func isHeader(_ fields: [String]) -> Bool {
    guard fields.count >= header.count else { return false }
    return zip(fields, header).allSatisfy { $0.pkoTrimmed == $1 }
  }

  // MARK: Parsing

  public func parse(_ data: Data) throws -> ParsedImport {
    guard let text = PKOText.decode(data) else { throw ImportError.unreadableEncoding }
    let records = PKOText.records(text)
    guard let headerRecord = records.first, Self.isHeader(headerRecord.fields) else {
      throw ImportError.unrecognisedFormat
    }

    var rows: [NormalizedRow] = []
    var warnings: [ImportWarning] = []
    var skipped = 0
    var seenFingerprints: [String: Int] = [:]
    var reportedCurrency = false

    for record in records.dropFirst() {
      switch parseRow(record) {
      case .failure(let problem):
        warnings.append(ImportWarning(line: record.line, message: problem.message))
        skipped += 1
      case .success(var row):
        if row.fileCurrency != account.currency.rawValue, !reportedCurrency {
          reportedCurrency = true
          warnings.append(
            ImportWarning(
              line: record.line,
              message:
                "The file is in \(row.fileCurrency), the account \(account.name) is in \(account.currency.rawValue). Pick the matching account."
            ))
        }
        // Identical rows cannot share a fingerprint (UNIQUE). PKO's running balance makes this
        // practically impossible; if it happens, keep both and say so.
        let base = row.value.fingerprints[0]
        let seen = seenFingerprints[base, default: 0] + 1
        seenFingerprints[base] = seen
        if seen > 1 {
          row.value.fingerprints[0] = Fingerprint.pko(accountID: accountID, parts: [base, "repeat", String(seen)])
          row.value.warnings.append("This row appears \(seen) times in the file with identical content.")
        }
        rows.append(row.value)
      }
    }
    return ParsedImport(source: Self.source, rows: rows, warnings: warnings, skippedRowCount: skipped)
  }

  struct Problem: Error {
    var message: String
  }

  struct ParsedRow {
    var value: NormalizedRow
    var fileCurrency: String
  }

  private enum Column: Int {
    case operationDate = 0, valueDate, type, amount, currency, balance, firstDetail
  }

  func parseRow(_ record: PKOText.Record) -> Result<ParsedRow, Problem> {
    let fields = record.fields
    guard fields.count >= Column.firstDetail.rawValue else {
      return .failure(Problem(message: "Expected at least 7 columns, found \(fields.count); row skipped."))
    }
    func field(_ column: Column) -> String { fields[column.rawValue].pkoTrimmed }

    let operationDateText = field(.operationDate)
    let valueDateText = field(.valueDate)
    let amountText = field(.amount)
    let balanceText = field(.balance)
    let type = PKOTransactionType(field(.type))
    let details = PKODetails(columns: fields.dropFirst(Column.firstDetail.rawValue))
    var warnings: [String] = []

    guard let signed = PKOAmount.minorUnits(amountText) else {
      return .failure(Problem(message: "Amount “\(amountText)” is not a number; row skipped."))
    }
    let magnitude = abs(signed)
    let isCredit = signed > 0

    // Dates (TA Q22, R-IMP-PKO-2): every row is dated by the purchase day (`Data waluty`); the
    // booking day (`Data operacji`, 1–3 days later for cards) is kept as `bookedDay`.
    let valueDay = Day(valueDateText)
    let operationDay = Day(operationDateText)
    let day: Day
    if let valueDay {
      day = valueDay
    } else if type != .hold, let operationDay {
      day = operationDay
      warnings.append("No value date; dated by the booking date.")
    } else {
      return .failure(Problem(message: "No valid date (“\(operationDateText)”, “\(valueDateText)”); row skipped."))
    }

    // Kind and direction (R-IMP-PKO-3, R-TX-4).
    var kind: NormalizedRow.Kind
    var isRefund = false
    var rowAccount = account
    var counterAccount: ExternalAccount?
    var counterAmount: Int64?
    var transferHalf: TransferHalf?
    switch type {
    case .hold, .cardPayment, .webPayment:
      kind = .expense
      isRefund = isCredit
    case .outgoingTransfer, .incomingTransfer, .phoneTransfer:
      kind = isCredit ? .income : .expense
    case .atmWithdrawal:
      kind = .transfer
      let cash = Self.cashAccount(currency: account.currency)
      if isCredit {
        rowAccount = cash
        counterAccount = account
      } else {
        counterAccount = cash
      }
      counterAmount = magnitude
    case .currencyExchange:
      kind = .transferHalf
      let foreign = exchangeForeignAmount(details[.title])
      if foreign == nil {
        warnings.append("Currency exchange: the other currency's amount was not found in the title.")
      }
      transferHalf = TransferHalf(
        direction: isCredit ? .incoming : .outgoing,
        transit: foreign ?? OriginalAmount(minorUnits: magnitude, currencyCode: account.currency.rawValue),
        counterpartHint: details.counterpartyName)
    case .unknown(let name):
      kind = isCredit ? .income : .expense
      warnings.append("Unknown PKO transaction type “\(name)”; recorded as \(kind.rawValue) by its sign. Needs review.")
    }

    // Original amount (R-CUR-4).
    var original: OriginalAmount?
    if let parsed = details.originalAmount {
      let code = parsed.currencyCode ?? account.currency.rawValue
      let digits = PKOAmount.minorDigits(currencyCode: code)
      if let minor = PKOAmount.minorUnits(parsed.amount, digits: digits).map(abs) {
        if code != account.currency.rawValue {
          original = OriginalAmount(minorUnits: minor, currencyCode: code)
        } else if parsed.currencyCode == nil, minor != magnitude {
          warnings.append("Original amount \(parsed.amount) has no currency and differs from the charged amount.")
        }
      } else {
        warnings.append("Original amount “\(parsed.amount)” is not a number; ignored.")
      }
    }

    // Description: merchant, else counterparty, else title; the title becomes the note when
    // a counterparty is the description (R-IMP-PKO-3).
    let title = details[.title]?.pkoCollapsed
    var payee = ""
    var note = ""
    if let merchant = details.merchant {
      payee = merchant
    } else if let counterparty = details.counterpartyName {
      payee = counterparty
      note = title ?? ""
    } else {
      payee = title ?? ""
    }

    // Fingerprints (R-IMP-3, R-IMP-PKO-2).
    let fingerprint: String
    if type == .hold {
      fingerprint = Fingerprint.pko(
        accountID: accountID, parts: ["hold", valueDateText, amountText, details[.title] ?? ""])
    } else {
      fingerprint = Fingerprint.pko(
        accountID: accountID,
        parts: [operationDateText, valueDateText, amountText, balanceText] + details.columns)
    }

    let row = NormalizedRow(
      fingerprints: [fingerprint], kind: kind, occurredAt: day.date(calendar: calendar),
      valueDay: valueDay, bookedDay: operationDay, account: rowAccount, amountMinor: magnitude,
      counterAccount: counterAccount, counterAmountMinor: counterAmount, isRefund: isRefund,
      original: original, payee: payee, note: note, isPending: type == .hold,
      transferHalf: transferHalf, counterpartyIBAN: details.counterpartyAccount, warnings: warnings)
    return .success(ParsedRow(value: row, fileCurrency: field(.currency)))
  }

  /// `FX… USD/PLN 3.6500  3 650,00 PLN -1 000,00 USD` → the amount not in the account currency.
  func exchangeForeignAmount(_ title: String?) -> OriginalAmount? {
    guard let title else { return nil }
    let pattern = #/(?<amount>[+-]?\d+(?:[ \u{00A0}]\d{3})*(?:[.,]\d+)?)\s+(?<code>[A-Z]{3})(?![A-Za-z/])/#
    for match in title.matches(of: pattern) {
      let code = String(match.output.code)
      guard code != account.currency.rawValue,
        let minor = PKOAmount.minorUnits(String(match.output.amount), digits: PKOAmount.minorDigits(currencyCode: code))
      else { continue }
      return OriginalAmount(minorUnits: abs(minor), currencyCode: code)
    }
    return nil
  }
}
