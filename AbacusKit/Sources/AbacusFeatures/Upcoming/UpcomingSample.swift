import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Synthetic scheduled items on the `PreviewData` accounts and categories (invented payees and
/// amounts), for previews, tests and "Load Sample Data". Kept outside `PreviewData` (shared).
public enum UpcomingSample {
  static func id(_ n: Int) -> UUID { PreviewData.id(n) }

  static func item(
    _ n: Int, _ payee: String, _ type: TxnType, _ account: Account, _ minor: Int64, category: Int?,
    unit: ScheduleUnit = .month, interval: Int = 1, start: String, lastDay: Bool = false, to: Account? = nil,
    toMinor: Int64? = nil
  ) -> ScheduledItem {
    ScheduledItem(
      id: id(n), type: type, accountID: account.id, toAccountID: to?.id, amountMinor: minor, toAmountMinor: toMinor,
      categoryID: category.map(PreviewData.id), payee: payee, unit: unit, interval: interval, startDay: start,
      lastDayOfMonth: lastDay, createdAt: Date(timeIntervalSince1970: 1_767_225_600 + Double(n)))
  }

  public static let items: [ScheduledItem] = [
    item(901, "Flat rent", .expense, PreviewData.pkoPersonal, 3_200_00, category: 205, start: "2026-01-05"),
    item(902, "Salary", .income, PreviewData.pkoPersonal, 9_800_00, category: 251, start: "2026-01-10"),
    item(903, "Streaming service", .expense, PreviewData.monobank, 199_00, category: 210, start: "2026-01-14"),
    item(904, "Phone plan", .expense, PreviewData.pkoPersonal, 59_99, category: 211, start: "2026-01-22"),
    item(905, "Cloud storage", .expense, PreviewData.pkoUSD, 9_99, category: 210, start: "2026-01-08"),
    item(906, "Gym membership", .expense, PreviewData.revolutEUR, 35_00, category: 209, start: "2026-01-20"),
    item(907, "Water utility", .expense, PreviewData.pkoPersonal, 140_00, category: 210, interval: 2, start: "2026-01-12"),
    item(908, "Accountant", .expense, PreviewData.pkoPersonal, 250_00, category: nil, start: "2026-01-31", lastDay: true),
    item(
      909, "Savings top-up", .transfer, PreviewData.pkoPersonal, 1_000_00, category: nil, start: "2026-01-28",
      to: PreviewData.cashPLN),
  ]

  /// Inserts the items (accounts and categories must exist).
  public static func seed(_ db: Database) throws {
    try db.seed {
      for item in items { item }
    }
  }

  /// "Load Sample Data": the items, only when the sample accounts are there and no item exists.
  /// The items start two months before `today` (QA-N2 L3: a January start left dozens of missed
  /// occurrences), and a few of their past occurrences get a matching synthetic transaction, so
  /// the first sweep stores a mix of paid and missed.
  public static func seedIfAbsent(_ db: Database, today: Day, calendar: Calendar = .current) throws {
    guard try ScheduledItem.fetchCount(db) == 0,
      try Account.find(PreviewData.pkoPersonal.id).fetchCount(db) > 0
    else { return }
    // Categories may have been mapped to the default set by name (`SampleData`): find the
    // stored category of the same name and kind.
    let stored = try AbacusDomain.Category.fetchAll(db)
    let rows = recent(today: today, calendar: calendar).map { item in
      var item = item
      if let wanted = PreviewData.categories.first(where: { $0.id == item.categoryID }) {
        item.categoryID =
          stored.first { $0.id == wanted.id }?.id
          ?? stored.first { $0.name == wanted.name && $0.kind == wanted.kind }?.id
      }
      return item
    }
    let paid = paidTxns(rows, today: today, calendar: calendar)
    try db.seed {
      for item in rows { item }
      for txn in paid { txn }
    }
  }

  /// The items moved to start in the month two months before `today` (same day of the month;
  /// "last day of the month" items on that month's last day), created on their start day.
  static func recent(today: Day, calendar: Calendar) -> [ScheduledItem] {
    let month = today.yearMonth.adding(months: -2)
    return items.map { item in
      var item = item
      guard let original = Day(item.startDay) else { return item }
      let last = month.lastDay(calendar: calendar)
      let start = item.lastDayOfMonth ? last : Day(year: month.year, month: month.month, day: min(original.day, last.day))
      item.startDay = start.string
      item.createdAt = start.date(calendar: calendar)
      return item
    }
  }

  /// Items whose past occurrences were paid in the sample (the rest end up missed).
  static let paidItems = [901, 902, 903, 904]

  /// One synthetic transaction per past monthly occurrence of `paidItems`: the item's account,
  /// type, amount, description and category, on the expected day.
  static func paidTxns(_ items: [ScheduledItem], today: Day, calendar: Calendar) -> [Txn] {
    var result: [Txn] = []
    for (index, n) in paidItems.enumerated() {
      guard let item = items.first(where: { $0.id == id(n) }), let start = Day(item.startDay) else { continue }
      for offset in 0..<3 {
        let month = start.yearMonth.adding(months: offset)
        let last = month.lastDay(calendar: calendar)
        let day = Day(year: month.year, month: month.month, day: min(start.day, last.day))
        guard day < today else { break }
        let at = day.date(calendar: calendar).addingTimeInterval(10 * 3600)
        result.append(
          Txn(
            id: id(960 + index * 10 + offset), type: item.type, occurredAt: at, accountID: item.accountID,
            amountMinor: item.amountMinor, categoryID: item.categoryID, payee: item.payee, createdAt: at))
      }
    }
    return result
  }

  /// `PreviewData` plus the items, in memory.
  public static func database() throws -> any DatabaseWriter {
    let database = try PreviewData.database()
    try database.write { try seed($0) }
    return database
  }
}
