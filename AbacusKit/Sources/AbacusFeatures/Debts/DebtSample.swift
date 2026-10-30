import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Synthetic debts for "Load Sample Data", previews and screenshots (R-DEBT-16…19): four made-up
/// people, each with virtual (and one with an external) account of the person, payments as
/// transfers between the `PreviewData` accounts and those accounts, a manual forgive record. Also
/// links the sample "Loan from friend" debt account to its own debt.
public enum DebtSample {
  public static let alex = Debt(
    id: PreviewData.id(1401), personName: "Alex Example", dueDay: "2026-12-01",
    note: "Concert tickets and the flat deposit", countsInNetWorth: true,
    createdAt: Date(timeIntervalSince1970: 1_780_000_000))
  public static let maria = Debt(
    id: PreviewData.id(1403), personName: "Maria Sample", countsInNetWorth: true,
    createdAt: Date(timeIntervalSince1970: 1_780_000_002))
  public static let sam = Debt(
    id: PreviewData.id(1404), personName: "Sam Placeholder", countsInNetWorth: false,
    createdAt: Date(timeIntervalSince1970: 1_780_000_003))
  public static let kim = Debt(
    id: PreviewData.id(1405), personName: "Kim Settled", countsInNetWorth: true, isSettled: true,
    createdAt: Date(timeIntervalSince1970: 1_780_000_004))

  public static let debts = [alex, maria, sam, kim]

  private static func account(_ n: Int, _ name: String, _ currency: Currency, kind: AccountKind = .debt, opening: Int64 = 0)
    -> Account
  {
    Account(
      id: PreviewData.id(n), name: name, currency: currency, kind: kind, openingBalanceMinor: opening,
      openingDate: Date(timeIntervalSince1970: 1_700_000_000), position: 50 + n - 1410)
  }

  /// The people's accounts: virtual ones (debt kind) and one external account of Maria's.
  public static let alexEUR = account(1410, "Alex Example (EUR)", .EUR)
  public static let alexPLN = account(1411, "Alex Example (PLN)", .PLN)
  public static let mariaUAH = account(1412, "Maria Sample (UAH)", .UAH)
  public static let samPLN = account(1413, "Sam Placeholder (PLN)", .PLN)
  public static let kimUSD = account(1414, "Kim Settled (USD)", .USD)
  /// Maria's own bank account whose statement the owner imports (R-DEBT-17 external).
  public static let mariaBank = account(1415, "Maria bank", .UAH, kind: .bank)

  public static let accounts = [alexEUR, alexPLN, mariaUAH, samPLN, kimUSD, mariaBank]

  public static let links: [DebtAccountLink] = [
    DebtAccountLink(accountID: alexEUR.id, debtID: alex.id, role: .virtual, createdAt: Date(timeIntervalSince1970: 1_780_000_010)),
    DebtAccountLink(accountID: alexPLN.id, debtID: alex.id, role: .virtual, createdAt: Date(timeIntervalSince1970: 1_780_000_011)),
    DebtAccountLink(accountID: mariaUAH.id, debtID: maria.id, role: .virtual, createdAt: Date(timeIntervalSince1970: 1_780_000_012)),
    DebtAccountLink(accountID: mariaBank.id, debtID: maria.id, role: .external, createdAt: Date(timeIntervalSince1970: 1_780_000_013)),
    DebtAccountLink(accountID: samPLN.id, debtID: sam.id, role: .virtual, createdAt: Date(timeIntervalSince1970: 1_780_000_014)),
    DebtAccountLink(accountID: kimUSD.id, debtID: kim.id, role: .virtual, createdAt: Date(timeIntervalSince1970: 1_780_000_015)),
  ]

  /// Payments as transfers: out of my account into the person's, or the other way round.
  public static let txns: [Txn] = {
    func transfer(
      _ n: Int, _ day: String, from: Account, to: Account, _ amount: Int64, toAmount: Int64? = nil, _ payee: String
    ) -> Txn {
      Txn(
        id: PreviewData.id(1600 + n), type: .transfer, occurredAt: PreviewData.at(day), accountID: from.id,
        amountMinor: amount, toAccountID: to.id, toAmountMinor: toAmount, payee: payee,
        createdAt: PreviewData.at(day))
    }
    let revolut = PreviewData.revolutEUR
    let pko = PreviewData.pkoPersonal
    let mono = PreviewData.monobank
    let pkoUSD = PreviewData.pkoUSD
    return [
      transfer(1, "2026-08-14", from: revolut, to: alexEUR, 300_00, "Flat deposit"),
      transfer(2, "2026-09-03", from: revolut, to: alexEUR, 80_00, "Concert tickets"),
      transfer(3, "2026-10-02", from: alexEUR, to: revolut, 120_00, "Alex repaid"),
      // The EUR debt paid from a UAH account too: €50 left as ₴2,400.
      transfer(11, "2026-10-08", from: mono, to: alexEUR, 2_400_00, toAmount: 50_00, "Train tickets"),
      transfer(4, "2026-10-05", from: alexPLN, to: pko, 250_00, "Taxi home"),
      transfer(5, "2026-07-20", from: mono, to: mariaUAH, 6_000_00, "To Maria"),
      transfer(6, "2026-09-25", from: mariaUAH, to: mono, 2_500_00, "Maria repaid"),
      transfer(8, "2026-10-12", from: pko, to: samPLN, 140_00, "Dinner"),
      transfer(9, "2026-06-01", from: pkoUSD, to: kimUSD, 50_00, "To Kim"),
      transfer(10, "2026-06-20", from: kimUSD, to: pkoUSD, 50_00, "Kim repaid"),
    ]
  }()

  /// Manual records: a forgiven part of Maria's debt (counted as an expense).
  public static let records: [DebtRecord] = [
    DebtRecord(
      id: PreviewData.id(1507), debtID: maria.id, kind: .forgaveThem, day: "2026-10-10", amountMinor: 500_00,
      currency: .UAH, note: "Birthday", reportKind: .expense, createdAt: Date(timeIntervalSince1970: 1_780_000_007))
  ]

  /// Links debt-kind accounts of the database, then inserts the sample debts, accounts, links,
  /// transfers and records into `db`, which must hold the `PreviewData` accounts.
  public static func seed(_ db: Database, calendar: Calendar = .current) throws {
    try DebtConversion.convertDebtAccounts(db, calendar: calendar)
    try db.seed {
      for account in accounts { account }
      for debt in debts { debt }
      for link in links { link }
      for txn in txns { txn }
    }
    for record in records {
      try SQLiteDebtRepository.save(record, db)
    }
  }

  /// An in-memory database with `PreviewData` and these debts (previews, tests).
  public static func database(calendar: Calendar = .current) throws -> any DatabaseWriter {
    let database = try AbacusDatabase.open(at: nil)
    try database.write { db in
      try PreviewData.seed(db)
      try seed(db, calendar: calendar)
    }
    return database
  }
}
