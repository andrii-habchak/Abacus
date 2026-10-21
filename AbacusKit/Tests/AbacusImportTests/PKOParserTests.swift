import AbacusDomain
@testable import AbacusImport
import AbacusTestSupport
import Foundation
import Testing

/// Synthetic fixtures in `Fixtures/pko/` (Windows-1250, CRLF); see their README.
enum PKOFixtures {
  static let accountID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
  static let account = Account(
    id: accountID, name: "PKO PLN", currency: .PLN, kind: .bank,
    openingDate: Date(timeIntervalSince1970: 0), iban: "55555555555555555555555555")

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  static var parser: PKOParser { PKOParser(account: account, calendar: calendar) }

  static func data(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/pko/\(name)", withExtension: "csv"))
    return try Data(contentsOf: url)
  }

  static func parse(_ name: String, parser: PKOParser = parser) throws -> ParsedImport {
    try parser.parse(data(name))
  }

  static func date(_ day: String) -> Date { Day(day)!.date(calendar: calendar) }

  /// A one-row file built in the test, encoded as PKO does.
  static func file(_ rows: [String], lineEnd: String = "\r\n") -> Data {
    let header = #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#
    return ([header] + rows).map { $0 + lineEnd }.joined().data(using: .windowsCP1250)!
  }
}

extension ParsedImport {
  func row(payee: String, amount: Int64? = nil) throws -> NormalizedRow {
    try #require(rows.first { $0.payee == payee && (amount == nil || $0.amountMinor == amount) })
  }
}

@Suite("PKO parser")
struct PKOParserTests {
  // MARK: R-IMP-PKO-1 — file format

  @Test("R-IMP-PKO-1: canParse accepts the PKO header and rejects other files")
  func detection() throws {
    #expect(PKOParser.canParse(try PKOFixtures.data("all-types")))
    #expect(PKOParser.canParse(PKOFixtures.file([])))
    #expect(!PKOParser.canParse(Data("Date,Account,Amount\r\n2026-01-01,Cash,1\r\n".utf8)))
    #expect(!PKOParser.canParse(Data()))
  }

  @Test("R-IMP-PKO-1: a file without the PKO header is rejected")
  func rejectsOtherFormats() {
    #expect(throws: ImportError.unrecognisedFormat) {
      try PKOFixtures.parser.parse(Data("\"Date\",\"Amount\"\r\n\"2026-01-01\",\"1.00\"\r\n".utf8))
    }
  }

  @Test("R-IMP-PKO-1: Windows-1250 is decoded and every row is booked on the picked account")
  func decodesAndBooksOnAccount() throws {
    let parsed = try PKOFixtures.parse("all-types")
    #expect(parsed.source == .pko)
    #expect(parsed.rows.count == 13)
    #expect(parsed.warnings.isEmpty)
    #expect(parsed.skippedRowCount == 0)
    // Polish letters survive the Windows-1250 decoding.
    #expect(try parsed.row(payee: "PIOTR WIŚNIEWSKI").note == "PIZZA")
    #expect(try parsed.row(payee: "ANNA NOWAK").note == "CZYNSZ STYCZEŃ")
    for row in parsed.rows where row.kind != .transfer {
      #expect(row.account.resolvedID == PKOFixtures.accountID)
      #expect(row.account.currency == .PLN)
    }
  }

  @Test("R-IMP-PKO-1: quoted commas, doubled quotes and LF-only line ends are read")
  func csvEdgeCases() throws {
    let data = PKOFixtures.file(
      [#""2026-01-05","2026-01-05","Przelew z rachunku","-10.00","PLN","+90.00","Nazwa odbiorcy: SHOP, ""BEST"" LTD","Tytuł: A, B","","","","""#],
      lineEnd: "\n")
    let parsed = try PKOFixtures.parser.parse(data)
    let row = try #require(parsed.rows.first)
    #expect(parsed.rows.count == 1)
    #expect(row.payee == #"SHOP, "BEST" LTD"#)
    #expect(row.note == "A, B")
  }

  @Test("R-IMP-PKO-1: a row with an unreadable amount is skipped with a line-numbered warning")
  func malformedRow() throws {
    let data = PKOFixtures.file([
      #""2026-01-05","2026-01-05","Płatność kartą","abc","PLN","+90.00","Tytuł: 1","","","","","""#,
      #""2026-01-04","2026-01-04","Płatność kartą","-1.00","PLN","+91.00","Tytuł: 2","","","","","""#,
    ])
    let parsed = try PKOFixtures.parser.parse(data)
    #expect(parsed.rows.count == 1)
    #expect(parsed.skippedRowCount == 1)
    #expect(parsed.warnings.map(\.line) == [2])
  }

  @Test("R-IMP-PKO-1: a file in another currency than the picked account is reported")
  func currencyMismatch() throws {
    let parser = PKOParser(accountID: PKOFixtures.accountID, currency: .EUR, calendar: PKOFixtures.calendar)
    let parsed = try PKOFixtures.parse("all-types", parser: parser)
    #expect(parsed.warnings.count == 1)
    #expect(parsed.rows.count == 13)
  }

  // MARK: R-IMP-PKO-3 — types, signs, details

  @Test("R-IMP-PKO-3: card and BLIK payments are expenses; a positive card payment is a refund (R-TX-4)")
  func payments() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let purchase = try parsed.row(payee: "GROCERY STORE", amount: 1735)
    let refunds = parsed.rows.filter(\.isRefund)
    let web = try parsed.row(payee: "www.shop.example")
    #expect(purchase.kind == .expense && !purchase.isRefund)
    // Q22: dated by the purchase (value) day; the booking day is kept for reference.
    #expect(purchase.occurredAt == PKOFixtures.date(try #require(purchase.valueDay).string))
    #expect(purchase.bookedDay == Day("2026-01-14"))
    #expect(purchase.valueDay == Day("2026-01-13"))
    #expect(refunds.count == 1)
    #expect(refunds.first?.kind == .expense)
    #expect(refunds.first?.payee == "GROCERY STORE")
    #expect(refunds.first?.amountMinor == 1735)
    #expect(web.kind == .expense && web.amountMinor == 4999 && !web.isRefund)
  }

  @Test("R-IMP-PKO-3: transfers take kind from the sign and carry the counterparty account number")
  func transfers() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let outgoing = try parsed.row(payee: "ANNA NOWAK")
    let incoming = try parsed.row(payee: "JAN KOWALSKI", amount: 12000)
    let phone = try parsed.row(payee: "PIOTR WIŚNIEWSKI")
    #expect(outgoing.kind == .expense && outgoing.amountMinor == 150000)
    #expect(outgoing.counterpartyIBAN == "11111111111111111111111111")
    #expect(incoming.kind == .income)
    #expect(incoming.counterpartyIBAN == "22222222222222222222222222")
    #expect(incoming.note == "ZWROT ZA BILETY")
    #expect(phone.kind == .expense && phone.amountMinor == 5000)
    #expect(phone.counterpartyIBAN == "33333333333333333333333333")
  }

  @Test("R-IMP-PKO-3: description is the Lokalizacja merchant, else the counterparty, else the title")
  func description() throws {
    let parsed = try PKOFixtures.parse("all-types")
    // Merchant, whitespace collapsed; card titles are reference numbers and are not kept.
    let purchase = try parsed.row(payee: "GROCERY STORE", amount: 1735)
    #expect(purchase.note.isEmpty)
    // Counterparty name with the title as note.
    #expect(try parsed.row(payee: "ANNA NOWAK").note == "CZYNSZ STYCZEŃ")
    // Neither: the title.
    #expect(try parsed.row(payee: "OPŁATA MIESIĘCZNA").amountMinor == 500)
  }

  @Test("R-CUR-4: a merchant amount in another currency becomes the original amount")
  func originalAmount() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let abroad = try parsed.row(payee: "MUZEUM SZTUKI")
    #expect(abroad.amountMinor == 4510)
    #expect(abroad.original == OriginalAmount(minorUnits: 1050, currencyCode: "EUR"))
    // Same currency, with or without the code: no original amount.
    #expect(try parsed.row(payee: "GROCERY STORE", amount: 1735).original == nil)
    #expect(parsed.rows.first { $0.isRefund }?.original == nil)
  }

  @Test("R-IMP-PKO-3: an ATM withdrawal is a transfer to the cash account")
  func atmWithdrawal() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let atm = try parsed.row(payee: "BANKOMAT CENTRUM")
    #expect(atm.kind == .transfer)
    #expect(atm.account.resolvedID == PKOFixtures.accountID)
    #expect(atm.counterAccount == PKOParser.cashAccount(currency: .PLN))
    #expect(atm.counterAccount?.kind == .cash)
    #expect(atm.amountMinor == 20000 && atm.counterAmountMinor == 20000)
    // Q22: dated by the purchase (value) day; the booking day is kept for reference.
    #expect(atm.occurredAt == PKOFixtures.date(try #require(atm.valueDay).string))
    #expect(atm.bookedDay == Day("2026-01-09"))
  }

  @Test("R-IMP-PKO-3: a currency exchange is a transfer half carrying the foreign amount")
  func currencyExchange() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let exchange = try #require(parsed.rows.first { $0.kind == .transferHalf })
    #expect(exchange.amountMinor == 365000)
    #expect(exchange.account.resolvedID == PKOFixtures.accountID)
    #expect(exchange.transferHalf?.direction == .incoming)
    #expect(exchange.transferHalf?.transit == OriginalAmount(minorUnits: 100000, currencyCode: "USD"))
    #expect(exchange.counterpartyIBAN == "44444444444444444444444444")
    #expect(exchange.warnings.isEmpty)
  }

  @Test("R-IMP-PKO-3: an unknown type is kept, kind by sign, with a review warning")
  func unknownType() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let fee = try parsed.row(payee: "OPŁATA MIESIĘCZNA")
    #expect(fee.kind == .expense)
    #expect(fee.warnings.count == 1)
    #expect(parsed.rows.filter { !$0.warnings.isEmpty }.count == 1)
  }

  // MARK: R-IMP-PKO-2 — holds

  @Test("R-IMP-PKO-2: a Blokada row is a pending expense dated by its value date")
  func hold() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let pending = parsed.rows.filter(\.isPending)
    let hold = try #require(pending.first)
    #expect(pending.count == 1)
    #expect(hold.kind == .expense && !hold.isRefund)
    #expect(hold.payee == "TAXI APP")
    #expect(hold.amountMinor == 2340)
    #expect(hold.occurredAt == PKOFixtures.date("2026-01-15"))
    #expect(hold.valueDay == Day("2026-01-15"))
    #expect(
      hold.fingerprints == [
        Fingerprint.pko(accountID: PKOFixtures.accountID, parts: ["hold", "2026-01-15", "-23.40", "P000000000000000000001"])
      ])
  }

  @Test("R-IMP-PKO-2: the settled row in a later export is a normal row the pipeline can match to the hold")
  func settledHold() throws {
    let hold = try #require(try PKOFixtures.parse("all-types").rows.first(where: \.isPending))
    let settled = try PKOFixtures.parse("settled-later").row(payee: "TAXI APP")
    #expect(!settled.isPending)
    #expect(settled.kind == .expense)
    #expect(settled.fingerprints != hold.fingerprints)
    #expect(settled.valueDay == hold.valueDay)
    #expect(settled.amountMinor == hold.amountMinor)
    // Q22: dated by the purchase (value) day; the booking day is kept for reference.
    #expect(settled.occurredAt == PKOFixtures.date(try #require(settled.valueDay).string))
    #expect(settled.bookedDay == Day("2026-01-17"))
  }

  // MARK: R-IMP-3 — fingerprints

  @Test("R-IMP-3: two identical same-day purchases get distinct fingerprints (running balance)")
  func identicalPurchases() throws {
    let parsed = try PKOFixtures.parse("all-types")
    let twins = parsed.rows.filter { $0.payee == "COFFEE KIOSK" }
    #expect(twins.count == 2)
    #expect(twins[0].amountMinor == twins[1].amountMinor && twins[0].occurredAt == twins[1].occurredAt)
    #expect(twins[0].fingerprints != twins[1].fingerprints)
  }

  @Test("R-IMP-3: re-parsing the same file gives identical fingerprints, all unique and CloudKit-safe")
  func stableFingerprints() throws {
    let first = try PKOFixtures.parse("all-types").rows.flatMap(\.fingerprints)
    let second = try PKOFixtures.parse("all-types").rows.flatMap(\.fingerprints)
    #expect(first == second)
    #expect(Set(first).count == first.count)
    for fingerprint in first {
      #expect(fingerprint.hasPrefix("pko:") && fingerprint.count < 255 && fingerprint.allSatisfy(\.isASCII))
    }
  }

  @Test("R-IMP-3: a row in an overlapping export keeps its fingerprint; another account changes it")
  func overlappingExport() throws {
    let earlier = try PKOFixtures.parse("all-types").row(payee: "GROCERY STORE", amount: 1735)
    let later = try PKOFixtures.parse("settled-later").row(payee: "GROCERY STORE")
    #expect(earlier.fingerprints == later.fingerprints)

    let other = PKOParser(accountID: UUID(), currency: .PLN, calendar: PKOFixtures.calendar)
    let elsewhere = try PKOFixtures.parse("settled-later", parser: other).row(payee: "GROCERY STORE")
    #expect(elsewhere.fingerprints != later.fingerprints)
  }

  @Test("R-IMP-3: rows identical in every column still get unique fingerprints, with a warning")
  func identicalRows() throws {
    let line = #""2026-01-05","2026-01-05","Płatność kartą","-1.00","PLN","+91.00","Tytuł: 1","","","","","""#
    let parsed = try PKOFixtures.parser.parse(PKOFixtures.file([line, line]))
    #expect(parsed.rows.count == 2)
    #expect(Set(parsed.rows.map(\.id)).count == 2)
    #expect(parsed.rows[1].warnings.count == 1)
  }
}

@Suite("PKO parser building blocks")
struct PKOBuildingBlockTests {
  @Test("R-CUR-2: amounts parse exactly into minor units")
  func amounts() {
    #expect(PKOAmount.minorUnits("-17.35") == -1735)
    #expect(PKOAmount.minorUnits("+120.00") == 12000)
    #expect(PKOAmount.minorUnits("1 000,00") == 100000)
    #expect(PKOAmount.minorUnits("-1\u{00A0}000,50") == -100050)
    #expect(PKOAmount.minorUnits("3") == 300)
    #expect(PKOAmount.minorUnits("10.5") == 1050)
    #expect(PKOAmount.minorUnits("1000.00", digits: 0) == 1000)
    #expect(PKOAmount.minorUnits("1.005", digits: 3) == 1005)
    #expect(PKOAmount.minorUnits("10.555") == nil)
    #expect(PKOAmount.minorUnits("W rozliczeniu") == nil)
    #expect(PKOAmount.minorUnits("") == nil)
    #expect(PKOAmount.minorDigits(currencyCode: "JPY") == 0)
    #expect(PKOAmount.minorDigits(currencyCode: "EUR") == 2)
  }

  @Test("R-IMP-PKO-1: detail columns are keyed in any order; spreadsheet quote prefixes are dropped")
  func details() {
    let details = PKODetails(columns: [
      "  Lokalizacja: Adres: SHOP  ONE Miasto: Łódź Kraj: POLSKA ", "", "'Operacja: 123", "Tytuł: X",
      "free text",
    ])
    #expect(details.merchant == "SHOP ONE")
    #expect(details[.operation] == "123")
    #expect(details[.title] == "X")
    #expect(details.unkeyed == ["free text"])
    #expect(details.columns.count == 4)
    #expect(PKODetails(columns: ["Lokalizacja: Adres: www.example.org"]).merchant == "www.example.org")
  }

  @Test("R-IMP-PKO-3: transaction types map from their Polish names")
  func types() {
    #expect(PKOTransactionType("Płatność kartą") == .cardPayment)
    #expect(PKOTransactionType("Płatność web - kod mobilny") == .webPayment)
    #expect(PKOTransactionType("Przelew z rachunku") == .outgoingTransfer)
    #expect(PKOTransactionType("Przelew na konto") == .incomingTransfer)
    #expect(PKOTransactionType("Przelew na telefon przychodz. zew.") == .phoneTransfer)
    #expect(PKOTransactionType("Wypłata w bankomacie - kod mobilny") == .atmWithdrawal)
    #expect(PKOTransactionType("WYMIANA W KANTORZE - UZNANIE") == .currencyExchange)
    #expect(PKOTransactionType("Blokada") == .hold)
    #expect(PKOTransactionType("Opłata") == .unknown("Opłata"))
  }
}
