import AbacusDomain
import Foundation

/// Synthetic import files for previews, screenshots and tests of the import wizard, made to
/// meet `PreviewData` (approved prototype 5). Never real data: names, account numbers and
/// amounts are invented.
public enum ImportSamples {
  // MARK: Rules

  /// Categorisation rules of the preview world: Biedronka, Lidl → Groceries; Bolt, Uber → Taxi;
  /// Orlen → Fuel; Orange → Mobile.
  public static let rules: [CategoryRule] = [
    ("biedronka", 202), ("lidl", 202), ("bolt", 207), ("uber", 207), ("orlen", 208), ("orange", 211),
  ].enumerated().map { index, rule in
    CategoryRule(
      id: PreviewData.id(951 + index), pattern: rule.0, categoryID: PreviewData.id(rule.1),
      origin: .imported, hitCount: 3, position: index)
  }

  // MARK: PKO

  public static let pkoFileName = "Zestawienie operacji za 21.09.2026 - 23.10.2026.csv"

  /// A PKO BP statement of "PKO Personal" (Windows-1250, CRLF) with one row of every kind the
  /// preview shows: a pending hold, a settled hold, rule-categorised and uncategorised card
  /// payments, a currency exchange from the own USD account, an ATM withdrawal, a phone
  /// transfer, an unknown operation type (card fee), a possible duplicate of a manual
  /// transaction, an incoming transfer, and a row of the earlier statement (already imported).
  public static var pko: Data {
    pkoData([
      ["", "2026-10-23", "Blokada", "-64.90", "PLN", "W rozliczeniu", "Tytuł: P000000000000000000021  ",
       "Lokalizacja: Adres: DROGERIA EXAMPLE Miasto: Warszawa Kraj: POLSKA"],
      card("2026-10-23", "2026-10-21", "-23.40", "+15433.40", "22", "BOLT.EU", "Warszawa"),
      card("2026-10-22", "2026-10-22", "-42.10", "+15456.80", "23", "BIEDRONKA 0001", "Warszawa"),
      card("2026-10-22", "2026-10-21", "-18.50", "+15498.90", "24", "KAWIARNIA RELAKS", "Kraków"),
      ["2026-10-22", "2026-10-22", "WYMIANA W KANTORZE - UZNANIE", "+3900.00", "PLN", "+15517.40",
       "Rachunek nadawcy: 00 0000 0000 0000 0000 0000 0002", "Nazwa nadawcy: PRZYKŁADOWY KLIENT",
       "Tytuł: FX000000025 USD/PLN 3.9000  3\u{00A0}900,00 PLN -1\u{00A0}000,00 USD",
       "Referencje własne zleceniodawcy: 000000025"],
      ["2026-10-20", "2026-10-20", "Wypłata w bankomacie - kod mobilny", "-200.00", "PLN", "+11617.40",
       "Tytuł: A0BC0000 0000 00000000000000026  ", "Numer telefonu: 48000000000",
       "Lokalizacja: Adres: BANKOMAT CENTRUM Miasto: Warszawa Kraj: POLSKA", "Bankomat: A0BC0000",
       "'Operacja: 0000 00000000000000026", "Numer referencyjny: 0000 00000000000000026"],
      ["2026-10-15", "2026-10-15", "Przelew na telefon przychodz. zew.", "-200.00", "PLN", "+11817.40",
       "Rachunek odbiorcy: 33 3333 3333 3333 3333 3333 3333", "Nazwa odbiorcy: OTRZYMUJĄCY PRZELEW", "Tytuł: KOLACJA"],
      ["2026-10-14", "2026-10-14", "Opłata za kartę", "-5.00", "PLN", "+12012.40", "Tytuł: OPŁATA MIESIĘCZNA"],
      ["2026-10-12", "2026-10-12", "Przelew z rachunku", "-4000.00", "PLN", "+12017.40",
       "Rachunek odbiorcy: 11 1111 1111 1111 1111 1111 1111", "Nazwa odbiorcy: WYNAJMUJĄCY EXAMPLE",
       "Tytuł: CZYNSZ PAŹDZIERNIK", "Referencje własne zleceniodawcy: 000000027"],
      ["2026-10-10", "2026-10-10", "Przelew na konto", "+250.00", "PLN", "+16017.40", "Tytuł: ZWROT ZA BILETY",
       "Nazwa nadawcy: PRZYKŁADOWY NADAWCA", "Rachunek nadawcy: 22 2222 2222 2222 2222 2222 2222",
       "Adres nadawcy: UL. PRZYKŁADOWA 1 WARSZAWA"],
      ["2026-10-09", "2026-10-08", "Płatność web - kod mobilny", "-45.00", "PLN", "+15767.40",
       "Tytuł: 00000000000000028  ", "Numer telefonu: 48000000000", "Lokalizacja: Adres: www.orange.example",
       "'Operacja: 00000000000000028", "Numer referencyjny: 00000000000000028"],
      earlierAuchan,
    ])
  }

  public static let earlierPKOFileName = "Zestawienie operacji za 15.09.2026 - 30.09.2026.csv"

  /// The earlier statement the preview world has already imported.
  static var earlierPKO: Data {
    pkoData([card("2026-09-27", "2026-09-26", "-12.99", "+5087.01", "12", "SKLEP OSIEDLOWY", "Warszawa"), earlierAuchan])
  }

  private static let earlierAuchan = card("2026-09-24", "2026-09-23", "-142.30", "+5100.00", "11", "AUCHAN", "Warszawa")

  /// A card payment row ("Płatność kartą") in PLN.
  private static func card(
    _ booked: String, _ value: String, _ amount: String, _ balance: String, _ reference: String, _ merchant: String,
    _ city: String
  ) -> [String] {
    [
      booked, value, "Płatność kartą", amount, "PLN", balance,
      "Tytuł:  0000000000000000000000\(reference) ", "Lokalizacja: Adres: \(merchant) Miasto: \(city) Kraj: POLSKA",
      "Data wykonania operacji: \(value)", "Oryginalna kwota operacji: \(amount.dropFirst())", "Numer karty: 000000******0000",
    ]
  }

  private static let pkoHeader = ["Data operacji", "Data waluty", "Typ transakcji", "Kwota", "Waluta", "Saldo po transakcji", "Opis transakcji"]

  /// Quoted, 12 columns, CRLF, Windows-1250 — as PKO BP exports it.
  private static func pkoData(_ rows: [[String]]) -> Data {
    let lines = ([pkoHeader] + rows).map { fields in
      (fields + Array(repeating: "", count: max(0, 12 - fields.count))).map { "\"\($0)\"" }.joined(separator: ",")
    }
    return (lines.joined(separator: "\r\n") + "\r\n").data(using: .windowsCP1250)!
  }

  // MARK: Saldo

  public static let saldoFileName = "saldo_export.csv"

  /// A Saldo export with new and existing accounts (an archived one, a liability, cash), a split,
  /// a refund, a transfer with a fee, unbalanced legs, tags (one named like an existing event),
  /// and unpaired transfer halves for Needs review.
  public static var saldo: Data {
    saldoData([
      // Opening balances: a new card and a liability.
      ("1", "2024-06-01T09:00:00", "Initial balance", "Bank UAH card", "BANK_ACCOUNTS", "0", "DEBIT", "500.00", "UAH", "", ""),
      ("1", "2024-06-01T09:00:00", "Initial balance", "Initial balance", "EQUITY", "0", "CREDIT", "500.00", "UAH", "", ""),
      ("2", "2024-06-01T09:00:00", "Initial balance", "Loan from a relative", "LIABILITIES", "0", "CREDIT", "300.00", "EUR", "", ""),
      ("2", "2024-06-01T09:00:00", "Initial balance", "Initial balance", "EQUITY", "0", "DEBIT", "300.00", "EUR", "", ""),
      // A cross-currency transfer whose halves book different transit currencies: offered for
      // pairing, not paired automatically (D26).
      ("3", "2024-06-02T12:04:00", "To the USD card", "Bank UAH business", "BANK_ACCOUNTS", "1", "CREDIT", "1200.00", "UAH", "", ""),
      ("3", "2024-06-02T12:04:00", "To the USD card", "Bank USD card", "MONEY_ON_THE_WAY", "0", "DEBIT", "1200.00", "UAH", "", ""),
      ("4", "2024-06-03T09:30:00", "From business", "Bank USD card", "BANK_ACCOUNTS", "0", "DEBIT", "30.00", "USD", "", ""),
      ("4", "2024-06-03T09:30:00", "From business", "Bank UAH business", "MONEY_ON_THE_WAY", "1", "CREDIT", "30.00", "USD", "", ""),
      // A split purchase in EUR on a UAH card.
      ("5", "2024-06-27T18:00:00", "GYM", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "3900.00", "UAH", "", ""),
      ("5", "2024-06-27T18:00:00", "GYM", "Health", "EXPENSES", "0", "DEBIT", "30.00", "EUR", "", ""),
      ("5", "2024-06-27T18:00:00", "GYM", "Family care", "EXPENSES", "0", "DEBIT", "50.00", "EUR", "", ""),
      // A refund.
      ("6", "2024-07-26T08:00:00", "Cancellation. FUEL STATION", "Bank UAH card", "BANK_ACCOUNTS", "0", "DEBIT", "1300.00", "UAH", "", ""),
      ("6", "2024-07-26T08:00:00", "Cancellation. FUEL STATION", "Fuel", "EXPENSES", "0", "CREDIT", "1300.00", "UAH", "", ""),
      // Unbalanced legs.
      ("7", "2024-08-02T15:30:00", "Online shop", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "2400.00", "UAH", "", ""),
      ("7", "2024-08-02T15:30:00", "Online shop", "Clothing", "EXPENSES", "0", "DEBIT", "2380.00", "UAH", "", ""),
      // Money sent to someone: a half with no counterpart account.
      ("8", "2024-11-22T10:00:00", "Money sent", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "2000.00", "UAH", "", ""),
      ("8", "2024-11-22T10:00:00", "Money sent", "Money on the way", "MONEY_ON_THE_WAY", "0", "DEBIT", "2000.00", "UAH", "", ""),
      // A transfer with a fee.
      ("9", "2025-02-01T09:00:00", "Wallet top-up", "Bank USD card", "BANK_ACCOUNTS", "0", "CREDIT", "20.50", "USD", "", ""),
      ("9", "2025-02-01T09:00:00", "Wallet top-up", "Wallet USD", "BANK_ACCOUNTS", "0", "DEBIT", "20.00", "USD", "", ""),
      ("9", "2025-02-01T09:00:00", "Wallet top-up", "Fees", "EXPENSES", "0", "DEBIT", "0.50", "USD", "", ""),
      // An incoming half without an outgoing one.
      ("10", "2025-03-14T11:00:00", "Into EUR cash", "EUR Cash", "CASH", "0", "DEBIT", "300.00", "EUR", "", ""),
      ("10", "2025-03-14T11:00:00", "Into EUR cash", "Money on the way", "MONEY_ON_THE_WAY", "0", "CREDIT", "300.00", "EUR", "", ""),
      // Tagged trips.
      ("11", "2025-05-12T13:20:00", "CAFE DU PARC", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "440.00", "UAH", "Trip 2025", ""),
      ("11", "2025-05-12T13:20:00", "CAFE DU PARC", "Eating out", "EXPENSES", "0", "DEBIT", "10.00", "EUR", "Trip 2025", ""),
      ("12", "2025-05-13T10:00:00", "MUSEUM", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "600.00", "UAH", "Trip 2025", ""),
      ("12", "2025-05-13T10:00:00", "MUSEUM", "Travel", "EXPENSES", "0", "DEBIT", "600.00", "UAH", "Trip 2025", ""),
      ("13", "2025-07-10T09:00:00", "Movers", "Bank UAH card", "BANK_ACCOUNTS", "0", "CREDIT", "4000.00", "UAH", "Relocation", "Two trips"),
      ("13", "2025-07-10T09:00:00", "Movers", "Moving", "EXPENSES", "0", "DEBIT", "4000.00", "UAH", "Relocation", "Two trips"),
      ("14", "2025-09-06T20:00:00", "Hotel", "EUR Cash", "CASH", "0", "CREDIT", "120.00", "EUR", "City break 2025", ""),
      ("14", "2025-09-06T20:00:00", "Hotel", "Travel", "EXPENSES", "0", "DEBIT", "120.00", "EUR", "City break 2025", ""),
      // An existing account (same name) and existing categories.
      ("15", "2025-09-07T18:00:00", "SUPERMARKET", "Monobank Black", "BANK_ACCOUNTS", "0", "CREDIT", "850.00", "UAH", "", ""),
      ("15", "2025-09-07T18:00:00", "SUPERMARKET", "Groceries", "EXPENSES", "0", "DEBIT", "850.00", "UAH", "", ""),
      ("16", "2025-10-01T09:00:00", "Payroll", "Salary", "INCOME", "0", "CREDIT", "1500.00", "USD", "", ""),
      ("16", "2025-10-01T09:00:00", "Payroll", "Bank USD card", "BANK_ACCOUNTS", "0", "DEBIT", "1500.00", "USD", "", ""),
      ("17", "2025-10-03T09:00:00", "Deposit interest", "Interest", "INCOME", "0", "CREDIT", "50.00", "UAH", "", ""),
      ("17", "2025-10-03T09:00:00", "Deposit interest", "Bank UAH card", "BANK_ACCOUNTS", "0", "DEBIT", "50.00", "UAH", "", ""),
    ])
  }

  public static let oldSaldoFileName = "saldo_export_2025.csv"

  /// A small Saldo export the preview world imported and undid.
  static var oldSaldo: Data {
    saldoData([
      ("901", "2025-01-05T10:00:00", "BAKERY", "Old wallet", "CASH", "0", "CREDIT", "12.00", "PLN", "", ""),
      ("901", "2025-01-05T10:00:00", "BAKERY", "Groceries", "EXPENSES", "0", "DEBIT", "12.00", "PLN", "", ""),
    ])
  }

  private static let saldoHeader =
    #""Transaction ID","Transaction Date","Description","Parent account","Account","Account Type","Archived","Journal Type","Amount","Currency","Tags","Accrual Month","Notes""#

  private typealias SaldoLeg = (
    id: String, date: String, description: String, account: String, type: String, archived: String,
    journal: String, amount: String, currency: String, tags: String, notes: String
  )

  private static func saldoData(_ legs: [SaldoLeg]) -> Data {
    let lines = legs.map { leg in
      [
        leg.id, leg.date, leg.description, "", leg.account, leg.type, leg.archived, leg.journal, leg.amount,
        leg.currency, leg.tags, String(leg.date.prefix(10)), leg.notes,
      ]
      .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
      .joined(separator: ",")
    }
    return Data(([saldoHeader] + lines).joined(separator: "\n").utf8)
  }

  // MARK: Dates

  static func at(_ day: String, _ time: String, _ calendar: Calendar) -> Date {
    let d = Day(day)!
    let hm = time.split(separator: ":").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hm[0], minute: hm[1]))!
  }
}
