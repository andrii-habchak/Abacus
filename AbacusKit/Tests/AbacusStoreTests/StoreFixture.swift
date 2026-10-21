import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Synthetic data for store tests (R-NF-6: never real exports). Days are calendar days in
/// `calendar` (Europe/Warsaw, so day bucketing differs from UTC).
struct StoreFixture {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
  }()

  let database: any DatabaseWriter

  init() throws {
    database = try AbacusDatabase.open(at: nil)
  }

  var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: Self.calendar) }
  var categories: SQLiteCategoryRepository { SQLiteCategoryRepository(database: database) }
  var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: Self.calendar) }
  var budgets: SQLiteBudgetRepository { SQLiteBudgetRepository(database: database) }
  var events: SQLiteEventRepository { SQLiteEventRepository(database: database) }
  var rules: SQLiteRuleRepository { SQLiteRuleRepository(database: database) }
  var settings: SQLiteSettingsRepository { SQLiteSettingsRepository(database: database) }
  var rates: SQLiteRateStore { SQLiteRateStore(database: database) }
  var imports: SQLiteImportStore { SQLiteImportStore(database: database, calendar: Self.calendar) }
  var reports: SQLiteReportQueries { SQLiteReportQueries(database: database, calendar: Self.calendar) }

  static func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  /// `"2026-03-05"` at `time` in the fixture calendar.
  static func at(_ day: String, _ time: String = "12:00") -> Date {
    let d = Day(day)!
    let hm = time.split(separator: ":").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hm[0], minute: hm[1]))!
  }

  // MARK: Standard data set

  static let bank = Account(id: id(1), name: "Bank", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00, openingDate: at("2026-01-01", "00:00"), position: 0)
  static let card = Account(id: id(2), name: "Card", currency: .EUR, kind: .card, openingBalanceMinor: 0, openingDate: at("2026-01-01", "00:00"), position: 1)
  static let loan = Account(id: id(3), name: "Loan", currency: .PLN, kind: .loan, openingBalanceMinor: -500_00, openingDate: at("2026-01-01", "00:00"), position: 2)

  static let food = AbacusDomain.Category(id: id(10), name: "Food", kind: .expense, position: 0)
  static let groceries = AbacusDomain.Category(id: id(11), name: "Groceries", kind: .expense, parentID: id(10), position: 1)
  static let eatingOut = AbacusDomain.Category(id: id(12), name: "Eating out", kind: .expense, parentID: id(10), position: 2)
  static let fees = AbacusDomain.Category(id: id(13), name: "Fees", kind: .expense, position: 3)
  static let transport = AbacusDomain.Category(id: id(14), name: "Transport", kind: .expense, position: 4)
  static let salary = AbacusDomain.Category(id: id(20), name: "Salary", kind: .income, position: 0)
  static let cashback = AbacusDomain.Category(id: id(21), name: "Cashback", kind: .income, position: 1)

  static let trip = Event(id: id(30), name: "Trip", startDay: "2026-03-01", endDay: "2026-03-10")

  static func expense(
    _ n: Int, _ day: String, _ amount: Int64, _ category: AbacusDomain.Category?, account: Account = bank,
    payee: String = "", note: String = "", refund: Bool = false, event: Event? = nil, time: String = "12:00"
  ) -> Txn {
    Txn(
      id: id(n), type: .expense, occurredAt: at(day, time), accountID: account.id, amountMinor: amount,
      categoryID: category?.id, isRefund: refund, payee: payee, note: note, eventID: event?.id,
      createdAt: at(day, time))
  }

  static func income(_ n: Int, _ day: String, _ amount: Int64, _ category: AbacusDomain.Category?, account: Account = bank, payee: String = "", reversal: Bool = false) -> Txn {
    Txn(
      id: id(n), type: .income, occurredAt: at(day), accountID: account.id, amountMinor: amount,
      categoryID: category?.id, isRefund: reversal, payee: payee, createdAt: at(day))
  }

  static func transfer(_ n: Int, _ day: String, from: Account, to: Account, _ amount: Int64, received: Int64? = nil) -> Txn {
    Txn(
      id: id(n), type: .transfer, occurredAt: at(day), accountID: from.id, amountMinor: amount,
      toAccountID: to.id, toAmountMinor: received ?? amount, createdAt: at(day))
  }

  /// Accounts, categories and the trip event.
  func seedBasics() throws {
    try database.write { db in
      try db.seed {
        Self.bank
        Self.card
        Self.loan
        Self.food
        Self.groceries
        Self.eatingOut
        Self.fees
        Self.transport
        Self.salary
        Self.cashback
        Self.trip
      }
    }
  }

  func insert(_ txn: Txn, lines: [AttachedRecord] = []) async throws {
    try await txns.save(txn, lines: lines)
  }
}

/// A converter with fixed per-pair rates (same rate every day) and an optional different
/// "latest" rate.
struct FixedConverter: CurrencyConverter {
  var rates: [String: Decimal]
  var latest: [String: Decimal] = [:]
  var latestDay: Day? = nil

  func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
    from == to ? 1 : rates["\(from.rawValue)\(to.rawValue)"]
  }

  func latestRate(from: Currency, to: Currency) -> Decimal? {
    from == to ? 1 : latest["\(from.rawValue)\(to.rawValue)"] ?? rates["\(from.rawValue)\(to.rawValue)"]
  }
}
