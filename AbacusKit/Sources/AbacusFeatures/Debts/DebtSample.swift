import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Synthetic debts for "Load Sample Data", previews and screenshots (R-DEBT): three made-up
/// people in several currencies, every record kind, legs on the `PreviewData` accounts. Also
/// converts the sample "Loan from friend" debt account the way migration v10 does.
public enum DebtSample {
  public static let alex = Debt(
    id: PreviewData.id(1401), personName: "Alex Example", currency: .EUR, dueDay: "2026-12-01",
    note: "Concert tickets and the flat deposit", createdAt: Date(timeIntervalSince1970: 1_780_000_000))
  public static let alexPLN = Debt(
    id: PreviewData.id(1402), personName: "Alex Example", currency: .PLN, createdAt: Date(timeIntervalSince1970: 1_780_000_001))
  public static let maria = Debt(
    id: PreviewData.id(1403), personName: "Maria Sample", currency: .UAH, createdAt: Date(timeIntervalSince1970: 1_780_000_002))
  public static let sam = Debt(
    id: PreviewData.id(1404), personName: "Sam Placeholder", currency: .PLN, countsInNetWorth: false,
    createdAt: Date(timeIntervalSince1970: 1_780_000_003))
  public static let kim = Debt(
    id: PreviewData.id(1405), personName: "Kim Settled", currency: .USD, isSettled: true,
    createdAt: Date(timeIntervalSince1970: 1_780_000_004))

  public static let debts = [alex, alexPLN, maria, sam, kim]

  /// Records with the account each one moved money on (nil = none).
  public static let records: [(DebtRecord, DebtLegInput?)] = {
    func record(
      _ n: Int, _ debt: Debt, _ kind: DebtRecordKind, _ day: String, _ amount: Int64, note: String = "",
      reportKind: CategoryKind? = nil
    ) -> DebtRecord {
      DebtRecord(
        id: PreviewData.id(1500 + n), debtID: debt.id, kind: kind, day: day, amountMinor: amount, note: note,
        reportKind: reportKind, createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(n)))
    }
    let revolut = PreviewData.revolutEUR.id
    let pko = PreviewData.pkoPersonal.id
    let mono = PreviewData.monobank.id
    let pkoUSD = PreviewData.pkoUSD.id
    return [
      (record(1, alex, .lent, "2026-08-14", 300_00, note: "Flat deposit"), DebtLegInput(accountID: revolut, amountMinor: 300_00)),
      (record(2, alex, .paidOnTheirBehalf, "2026-09-03", 80_00, note: "Concert tickets"),
       DebtLegInput(accountID: revolut, amountMinor: 80_00)),
      (record(3, alex, .theyRepaid, "2026-10-02", 120_00), DebtLegInput(accountID: revolut, amountMinor: 120_00)),
      (record(4, alexPLN, .borrowed, "2026-10-05", 250_00, note: "Taxi home"), DebtLegInput(accountID: pko, amountMinor: 250_00)),
      (record(5, maria, .lent, "2026-07-20", 6_000_00), DebtLegInput(accountID: mono, amountMinor: 6_000_00)),
      (record(6, maria, .theyRepaid, "2026-09-25", 2_500_00), DebtLegInput(accountID: mono, amountMinor: 2_500_00)),
      (record(7, maria, .forgaveThem, "2026-10-10", 500_00, note: "Birthday", reportKind: .expense), nil),
      (record(8, sam, .paidOnTheirBehalf, "2026-10-12", 140_00, note: "Dinner", reportKind: .expense),
       DebtLegInput(accountID: pko, amountMinor: 140_00)),
      (record(9, kim, .lent, "2026-06-01", 50_00), DebtLegInput(accountID: pkoUSD, amountMinor: 50_00)),
      (record(10, kim, .theyRepaid, "2026-06-20", 50_00), DebtLegInput(accountID: pkoUSD, amountMinor: 50_00)),
    ]
  }()

  /// Converts debt-kind accounts, then inserts the sample debts and records (with legs) into
  /// `db`, which must hold the `PreviewData` accounts.
  public static func seed(_ db: Database, calendar: Calendar = .current) throws {
    try DebtConversion.convertDebtAccounts(db, calendar: calendar)
    try db.seed {
      for debt in debts { debt }
    }
    for (record, leg) in records {
      try SQLiteDebtRepository.save(record, leg: leg, calendar: calendar, db)
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
