import AbacusDomain
import Foundation

/// Small hand-made data for the calculator tests. Synthetic only.
enum Fx {
  /// UTC so `occurredAt` never shifts into another day.
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static func date(_ day: String, hour: Int = 12) -> Date {
    let d = Day(day)!
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour))!
  }

  static func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  // MARK: Accounts

  static func account(
    _ n: Int, _ currency: Currency, _ kind: AccountKind = .bank, opening: Int64 = 0,
    openedOn: String = "2026-01-01", archived: Bool = false
  ) -> Account {
    Account(
      id: id(n), name: "Account \(n)", currency: currency, kind: kind, openingBalanceMinor: opening,
      openingDate: date(openedOn, hour: 0), isArchived: archived)
  }

  // MARK: Categories

  static func category(_ n: Int, _ kind: CategoryKind = .expense, parent: Int? = nil) -> AbacusDomain.Category {
    AbacusDomain.Category(id: id(n), name: "Category \(n)", kind: kind, parentID: parent.map(id), position: n)
  }

  // MARK: Transactions

  static func expense(
    _ amount: Int64, _ account: Account, on day: String, category: AbacusDomain.Category? = nil,
    refund: Bool = false, event: Event? = nil, lines: [AttachedRecord] = [], id txnID: UUID = UUID()
  ) -> TxnWithLines {
    let txn = Txn(
      id: txnID, type: .expense, occurredAt: date(day), accountID: account.id, amountMinor: amount,
      categoryID: category?.id, isRefund: refund, eventID: event?.id)
    return TxnWithLines(txn: txn, lines: lines.map { reparent($0, to: txnID) })
  }

  static func income(
    _ amount: Int64, _ account: Account, on day: String, category: AbacusDomain.Category? = nil,
    reversal: Bool = false, event: Event? = nil, lines: [AttachedRecord] = [], id txnID: UUID = UUID()
  ) -> TxnWithLines {
    let txn = Txn(
      id: txnID, type: .income, occurredAt: date(day), accountID: account.id, amountMinor: amount,
      categoryID: category?.id, isRefund: reversal, eventID: event?.id)
    return TxnWithLines(txn: txn, lines: lines.map { reparent($0, to: txnID) })
  }

  static func transfer(
    _ amount: Int64, from: Account, to: Account, received: Int64? = nil, on day: String,
    lines: [AttachedRecord] = [], id txnID: UUID = UUID()
  ) -> TxnWithLines {
    let txn = Txn(
      id: txnID, type: .transfer, occurredAt: date(day), accountID: from.id, amountMinor: amount,
      toAccountID: to.id, toAmountMinor: received)
    return TxnWithLines(txn: txn, lines: lines.map { reparent($0, to: txnID) })
  }

  static func line(_ amount: Int64, _ kind: CategoryKind = .expense, category: AbacusDomain.Category? = nil) -> AttachedRecord {
    AttachedRecord(txnID: UUID(), kind: kind, categoryID: category?.id, amountMinor: amount)
  }

  private static func reparent(_ line: AttachedRecord, to txnID: UUID) -> AttachedRecord {
    var line = line
    line.txnID = txnID
    return line
  }
}

/// In-memory rates for tests: `1 from = rate to` per day; an earlier day's rate covers later
/// days without one (weekends); inverse pairs are derived. Unknown → nil.
struct FakeConverter: CurrencyConverter {
  struct Pair: Hashable {
    let from: Currency
    let to: Currency
  }

  var dated: [Pair: [(day: Day, rate: Decimal)]] = [:]
  var latest: [Pair: Decimal] = [:]
  var latestDay: Day?

  init() {}

  /// `rates`: `[("2026-10-01", .EUR, .UAH, "45.00")]`.
  init(_ rates: [(String, Currency, Currency, String)], latest: [(Currency, Currency, String)] = [], latestDay: String? = nil) {
    for (day, from, to, rate) in rates {
      dated[Pair(from: from, to: to), default: []].append((Day(day)!, Decimal(string: rate)!))
    }
    for key in dated.keys { dated[key]!.sort { $0.day < $1.day } }
    for (from, to, rate) in latest {
      self.latest[Pair(from: from, to: to)] = Decimal(string: rate)!
    }
    self.latestDay = latestDay.flatMap(Day.init)
  }

  func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
    if from == to { return 1 }
    if let rate = dated[Pair(from: from, to: to)]?.last(where: { $0.day <= day })?.rate { return rate }
    if let rate = dated[Pair(from: to, to: from)]?.last(where: { $0.day <= day })?.rate { return 1 / rate }
    return nil
  }

  func latestRate(from: Currency, to: Currency) -> Decimal? {
    if from == to { return 1 }
    if let rate = latest[Pair(from: from, to: to)] { return rate }
    if let rate = latest[Pair(from: to, to: from)] { return 1 / rate }
    return nil
  }
}
