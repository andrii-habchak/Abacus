#if DEBUG
  import AbacusDomain
  import AbacusFX
  import AbacusImport
  import AbacusStore
  import Foundation
  import SQLiteData

  /// UI reviews only (`-AbacusForecastDemo YES` on a scratch database with sample data): turns the
  /// sample's recurring transactions into scheduled items, adds one large yearly bill that takes the
  /// main account below zero, takes past snapshots as if the app had been opened on those days,
  /// then runs the matching sweep so the accuracy panel has paid and missed occurrences.
  /// Never run it on the owner's database.
  public enum ForecastDemoSeed {
    @discardableResult
    public static func seed(
      database: any DatabaseWriter, today: Day, converter: (any CurrencyConverter)?, calendar: Calendar = .current,
      snapshotDaysAgo: [Int] = [45, 30, 14, 7]
    ) async throws -> Int {
      let store = SQLiteScheduledStore(database: database, calendar: calendar)
      guard try await store.items().isEmpty else { return 0 }
      let (accounts, txns) = try await database.read { db in
        (try Account.where { !$0.isArchived }.fetchAll(db), try Txn.fetchAll(db))
      }
      let usable = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
      let from = today.plusDays(-200)
      // Recurring payees: the same payee and type on one account in at least four months.
      struct Key: Hashable {
        let payee: String
        let type: TxnType
        let account: Account.ID
      }
      var groups: [Key: [(day: Day, amount: Int64)]] = [:]
      for txn in txns where txn.type != .transfer && !txn.isRefund && !txn.payee.isEmpty {
        guard usable[txn.accountID] != nil else { continue }
        let day = Day(txn.occurredAt, calendar: calendar)
        guard day >= from, day <= today else { continue }
        groups[Key(payee: txn.payee, type: txn.type, account: txn.accountID), default: []].append((day, txn.amountMinor))
      }
      let recurring =
        groups
        .filter { Set($0.value.map { $0.day.yearMonth }).count >= 4 }
        .sorted { ($0.value.count, $0.key.payee) > ($1.value.count, $1.key.payee) }
        .prefix(6)
      var items: [ScheduledItem] = []
      for (key, rows) in recurring {
        let sorted = rows.sorted { $0.day < $1.day }
        let amounts = sorted.map(\.amount).sorted()
        let start = sorted[0].day
        items.append(
          ScheduledItem(
            type: key.type, accountID: key.account, amountMinor: amounts[amounts.count / 2], payee: key.payee,
            unit: .month, startDay: start.string, tolerancePercent: 20, createdAt: start.date(calendar: calendar)))
      }
      // A large yearly bill on the busiest asset account, enough to go below zero for a while.
      let balances = try await SQLiteReportQueries(database: database, calendar: calendar).balances(on: [today])
      let counts = Dictionary(grouping: txns, by: \.accountID).mapValues(\.count)
      let busiest = accounts.filter { !$0.kind.isLiability }.max { (counts[$0.id] ?? 0) < (counts[$1.id] ?? 0) }
      if let main = busiest {
        let balance = balances.balances[main.id]?.first ?? 0
        let due = today.plusDays(24)
        items.append(
          ScheduledItem(
            type: .expense, accountID: main.id, amountMinor: max(100_00, balance + 1_250_00), payee: "Car insurance",
            unit: .year, startDay: due.string, createdAt: today.date(calendar: calendar)))
        if let savings = accounts.first(where: { $0.id != main.id && !$0.kind.isLiability && $0.currency == main.currency }) {
          let start = today.plusDays(-75)
          items.append(
            ScheduledItem(
              type: .transfer, accountID: main.id, toAccountID: savings.id, amountMinor: 200_00, payee: "Savings top-up",
              unit: .month, startDay: start.string, createdAt: start.date(calendar: calendar)))
        }
      }
      for item in items { try await store.save(item) }
      // Past forecasts first (as the app would have taken them, before those payments existed).
      let snapshots = SQLiteForecastSnapshotRepository(database: database, calendar: calendar)
      let rates =
        converter.map { SnapshotRates.latest(from: $0, currencies: Set(accounts.map(\.currency))) }
        ?? SnapshotRates(asOf: nil, base: .UAH, toBase: [:])
      for days in snapshotDaysAgo.sorted(by: >) {
        try await snapshots.takeIfNeeded(today: today.plusDays(-days), rates: rates, debts: [:])
      }
      _ = try await store.sweep(today: today, matcher: ScheduledMatch.rule)
      try await snapshots.takeIfNeeded(today: today, rates: rates, debts: [:])
      return items.count
    }
  }

  extension ForecastDependencies {
    /// UI reviews: the Forecast tab on the scratch database named by `-AbacusDatabasePath`, seeded
    /// with `ForecastDemoSeed` first; nil without a path (never the app's own file).
    public static func demo(databasePath: String?, format: DashboardFormat = DashboardFormat()) async -> ForecastDependencies? {
      guard let databasePath, !databasePath.isEmpty,
        let database = try? AbacusDatabase.open(at: URL(fileURLWithPath: databasePath))
      else { return nil }
      let calendar = format.calendar
      let today = Day(Date(), calendar: calendar)
      let store = SQLiteRateStore(database: database)
      let rates = (try? await store.rates(from: today.plusDays(-400), to: today)) ?? []
      let overrides = (try? await store.overrides()) ?? []
      let table = RateTable(rates: rates, overrides: overrides, today: today)
      _ = try? await ForecastDemoSeed.seed(database: database, today: today, converter: table, calendar: calendar)
      return .database(database, rates: { table }, format: format)
    }
  }
#endif
