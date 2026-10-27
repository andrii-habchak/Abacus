import AbacusDomain
import Foundation
import SQLiteData

/// Dashboard and report aggregations (R-HOME-1/3, R-BUD-2, R-EVT-3, R-ACC-3). Amounts come out in
/// the account's currency, bucketed by day, so callers convert at each date's rate (R-FX-3)
/// with a `CurrencyConverter`; the `converted` helpers do exactly that.
public struct SQLiteReportQueries: Sendable {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  var bounds: DayBounds { DayBounds(calendar: calendar) }

  // MARK: Spending by category

  /// R-HOME-3, R-BUD-2: expenses and income of `month` by category, attached records included
  /// under their own category (R-TX-6). Refunds follow R-SET-3 unless `refundsReduceSpending`
  /// is given (R-TX-4). An income attached record in an expense category is a refund line
  /// (D22) and counts like a refunded expense.
  public func monthlySpending(_ month: Month, refundsReduceSpending: Bool? = nil) async throws -> SpendingReport {
    try await spending(from: month.firstDay, to: month.lastDay(calendar: calendar), refundsReduceSpending: refundsReduceSpending)
  }

  /// Spending between two days (inclusive), optionally of one event only.
  public func spending(
    from: Day? = nil, to: Day? = nil, eventID: Event.ID? = nil, refundsReduceSpending: Bool? = nil
  ) async throws -> SpendingReport {
    var conditions: [QueryFragment] = []
    if let from { conditions.append(#""t"."occurredAt" >= \#(bounds.start(from))"#) }
    if let to { conditions.append(#""t"."occurredAt" < \#(bounds.end(to))"#) }
    if let eventID { conditions.append(#""t"."eventID" = \#(eventID)"#) }
    let condition: QueryFragment = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
    let sql: QueryFragment = #"""
      SELECT "t"."categoryID", "a"."currency", "t"."occurredAt", "t"."type", "t"."isRefund", \#
      "t"."amountMinor"
      FROM "txns" AS "t" JOIN "accounts" AS "a" ON "a"."id" = "t"."accountID"
      WHERE "t"."type" <> 'transfer' AND \#(condition)
      UNION ALL
      SELECT "r"."categoryID", "a"."currency", "t"."occurredAt",
        CASE WHEN "r"."kind" = 'income' AND "c"."kind" = 'expense' THEN 'expense' ELSE "r"."kind" END,
        ("r"."kind" = 'income' AND coalesce("c"."kind" = 'expense', 0)),
        "r"."amountMinor"
      FROM "attachedRecords" AS "r"
      JOIN "txns" AS "t" ON "t"."id" = "r"."txnID"
      JOIN "accounts" AS "a" ON "a"."id" = "t"."accountID"
      LEFT JOIN "categories" AS "c" ON "c"."id" = "r"."categoryID"
      WHERE \#(condition)
      """#
    let bounds = self.bounds
    return try await database.read { db in
      let reduce = try refundsReduceSpending ?? SQLiteSettingsRepository.refundsReduceSpending(db)
      let flows = try SQLQueryExpression(sql, as: FlowRow.self).fetchAll(db)
      return SpendingReport(flows: flows, refundsReduceSpending: reduce, bounds: bounds)
    }
  }

  // MARK: Balances

  /// R-ACC-3, R-HOME-1: every account's balance at the end of each of `days` (opening balance
  /// counted from its opening date, plus all transaction effects up to that day; transfers move
  /// `amountMinor` out and `toAmountMinor` in — a debt leg without destination marked `isRefund`
  /// moves it in; attached records adjust the source account).
  /// Archived accounts are left out unless `includeArchived` (R-ACC-4).
  public func balances(on days: [Day], includeArchived: Bool = false) async throws -> BalanceSeries {
    let days = Array(Set(days)).sorted()
    let ends = days.map(bounds.end)
    guard let last = ends.last else { return BalanceSeries(days: [], accounts: [], balances: [:]) }
    var bucket: QueryFragment = "CASE"
    for (index, end) in ends.enumerated() {
      bucket += #" WHEN "t"."occurredAt" < \#(end) THEN \#(raw: index)"#
    }
    bucket += " END"
    let sql: QueryFragment = #"""
      SELECT "accountID", "bucket", SUM("delta") FROM (
        SELECT "t"."accountID" AS "accountID", \#(bucket) AS "bucket",
          (CASE "t"."type"
            WHEN 'expense' THEN (CASE WHEN "t"."isRefund" THEN "t"."amountMinor" ELSE -"t"."amountMinor" END)
            WHEN 'income' THEN (CASE WHEN "t"."isRefund" THEN -"t"."amountMinor" ELSE "t"."amountMinor" END)
            ELSE (CASE WHEN "t"."isRefund" AND "t"."toAccountID" IS NULL THEN "t"."amountMinor" ELSE -"t"."amountMinor" END) END)
          + COALESCE((SELECT SUM(CASE "r"."kind" WHEN 'income' THEN "r"."amountMinor" ELSE -"r"."amountMinor" END)
            FROM "attachedRecords" AS "r" WHERE "r"."txnID" = "t"."id"), 0) AS "delta"
        FROM "txns" AS "t" WHERE "t"."occurredAt" < \#(last)
        UNION ALL
        SELECT "t"."toAccountID", \#(bucket), COALESCE("t"."toAmountMinor", "t"."amountMinor")
        FROM "txns" AS "t"
        WHERE "t"."type" = 'transfer' AND "t"."toAccountID" IS NOT NULL AND "t"."occurredAt" < \#(last)
      )
      GROUP BY "accountID", "bucket"
      """#
    return try await database.read { db in
      let accounts = try Account
        .where { if !includeArchived { !$0.isArchived } }
        .order { ($0.position, $0.name) }
        .fetchAll(db)
      let sums = try SQLQueryExpression(sql, as: BucketSum.self).fetchAll(db)
      var deltas: [Account.ID: [Int64]] = [:]
      for sum in sums {
        deltas[sum.accountID, default: Array(repeating: 0, count: ends.count)][sum.bucket] += sum.total
      }
      var balances: [Account.ID: [Int64]] = [:]
      for account in accounts {
        var running: Int64 = 0
        let accountDeltas = deltas[account.id] ?? Array(repeating: 0, count: ends.count)
        balances[account.id] = ends.indices.map { index in
          running += accountDeltas[index]
          return running + (account.openingDate < ends[index] ? account.openingBalanceMinor : 0)
        }
      }
      return BalanceSeries(days: days, accounts: accounts, balances: balances)
    }
  }

  /// R-HOME-1: month-end balances from `from` through the month of `today`; the last point is
  /// `today` itself.
  public func netWorthSeries(from: Month, today: Day, includeArchived: Bool = false) async throws -> BalanceSeries {
    try await balances(on: Self.netWorthDays(from: from, today: today, calendar: calendar), includeArchived: includeArchived)
  }

  /// Month ends of `from`…the month before `today`, then `today`.
  public static func netWorthDays(from: Month, today: Day, calendar: Calendar = .current) -> [Day] {
    var days: [Day] = []
    var month = from
    while month < today.yearMonth {
      days.append(month.lastDay(calendar: calendar))
      month = month.adding(months: 1)
    }
    days.append(today)
    return days
  }
}

// MARK: - Rows

@Selection
struct FlowRow: Sendable {
  var categoryID: AbacusDomain.Category.ID?
  var currency: Currency
  var occurredAt: Date
  /// `.expense` / `.income` (attached records reuse their kind's raw value).
  var type: TxnType
  var isRefund: Bool
  var amountMinor: Int64
}

@Selection
struct BucketSum: Sendable {
  var accountID: Account.ID
  var bucket: Int
  var total: Int64
}

// MARK: - Results

/// An amount of one category, in one currency, on one day.
public struct CategoryAmount: Hashable, Sendable {
  public var categoryID: AbacusDomain.Category.ID?
  public var currency: Currency
  public var day: Day
  public var amountMinor: Int64

  public init(categoryID: AbacusDomain.Category.ID?, currency: Currency, day: Day, amountMinor: Int64) {
    self.categoryID = categoryID
    self.currency = currency
    self.day = day
    self.amountMinor = amountMinor
  }
}

/// Expenses and income by category for a period (R-HOME-3, R-BUD-2, R-EVT-3).
///
/// - `expenses`: expense transactions and attached expense records, positive = spent. With
///   refunds reducing spending (R-SET-3 on) expense refunds are subtracted here.
/// - `income`: income transactions and attached income records; reversals subtracted.
/// - `refunds`: with R-SET-3 off, expense refunds reported as income ("Refunds", R-TX-4), still
///   keyed by their expense category; empty when the setting is on.
public struct SpendingReport: Hashable, Sendable {
  public var expenses: [CategoryAmount]
  public var income: [CategoryAmount]
  public var refunds: [CategoryAmount]

  public init(expenses: [CategoryAmount] = [], income: [CategoryAmount] = [], refunds: [CategoryAmount] = []) {
    self.expenses = expenses
    self.income = income
    self.refunds = refunds
  }

  init(flows: [FlowRow], refundsReduceSpending: Bool, bounds: DayBounds) {
    struct Key: Hashable {
      var categoryID: AbacusDomain.Category.ID?
      var currency: Currency
      var day: Day
    }
    var expenses: [Key: Int64] = [:]
    var income: [Key: Int64] = [:]
    var refunds: [Key: Int64] = [:]
    for flow in flows {
      let key = Key(categoryID: flow.categoryID, currency: flow.currency, day: bounds.day(flow.occurredAt))
      switch (flow.type, flow.isRefund) {
      case (.expense, false): expenses[key, default: 0] += flow.amountMinor
      case (.expense, true):
        if refundsReduceSpending {
          expenses[key, default: 0] -= flow.amountMinor
        } else {
          refunds[key, default: 0] += flow.amountMinor
        }
      case (.income, false): income[key, default: 0] += flow.amountMinor
      case (.income, true): income[key, default: 0] -= flow.amountMinor
      case (.transfer, _): break
      }
    }
    func rows(_ sums: [Key: Int64]) -> [CategoryAmount] {
      sums.map { CategoryAmount(categoryID: $0.key.categoryID, currency: $0.key.currency, day: $0.key.day, amountMinor: $0.value) }
        .sorted { ($0.day, $0.currency.rawValue, $0.categoryID?.uuidString ?? "") < ($1.day, $1.currency.rawValue, $1.categoryID?.uuidString ?? "") }
    }
    self.expenses = rows(expenses)
    self.income = rows(income)
    self.refunds = rows(refunds)
  }
}

extension Array where Element == CategoryAmount {
  /// Totals per category in `currency`, each amount at its day's rate (R-FX-3). `unconverted`
  /// counts amounts without a known rate (left out).
  public func totalsByCategory(
    in currency: Currency, using converter: any CurrencyConverter
  ) -> (totals: [AbacusDomain.Category.ID?: Money], unconverted: Int) {
    var totals: [AbacusDomain.Category.ID?: Money] = [:]
    var unconverted = 0
    for amount in self {
      guard
        let money = converter.convert(
          Money(minorUnits: amount.amountMinor, currency: amount.currency), to: currency, on: amount.day)
      else {
        unconverted += 1
        continue
      }
      totals[amount.categoryID] = (totals[amount.categoryID] ?? .zero(currency)) + money
    }
    return (totals, unconverted)
  }

  /// R-CAT-2: the same amounts with each child category replaced by its parent.
  public func rolledUpToParents(_ categories: [AbacusDomain.Category]) -> [CategoryAmount] {
    let parentOf = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.parentID) })
    return map { amount in
      var amount = amount
      if let id = amount.categoryID, let parent = parentOf[id] ?? nil {
        amount.categoryID = parent
      }
      return amount
    }
  }
}

/// Balances of accounts at the end of several days, in each account's currency.
public struct BalanceSeries: Hashable, Sendable {
  public var days: [Day]
  public var accounts: [Account]
  /// Account → one balance per entry of `days`.
  public var balances: [Account.ID: [Int64]]

  public init(days: [Day], accounts: [Account], balances: [Account.ID: [Int64]]) {
    self.days = days
    self.accounts = accounts
    self.balances = balances
  }

  /// R-HOME-1: net worth (assets − liabilities = sum of signed balances) per day in `currency`,
  /// converted at each day's rate; the last point at the latest rate when `latestForLast`.
  /// A point is nil when a needed rate is missing.
  public func netWorth(
    in currency: Currency, using converter: any CurrencyConverter, latestForLast: Bool = true
  ) -> [Money?] {
    days.indices.map { index in
      var total = Money.zero(currency)
      for account in accounts {
        let money = Money(minorUnits: balances[account.id]?[index] ?? 0, currency: account.currency)
        let converted =
          latestForLast && index == days.count - 1
          ? converter.convertAtLatest(money, to: currency)
          : converter.convert(money, to: currency, on: days[index])
        guard let converted else { return nil }
        total = total + converted
      }
      return total
    }
  }
}
