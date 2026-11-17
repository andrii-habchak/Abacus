import AbacusDomain
import Foundation
import SQLiteData

/// Forecast snapshots (R-REC-17, R-REC-18). Reads scheduled items and resolved occurrences from
/// the v18 tables directly; the forecast itself is `ForecastEngine.run`, so a snapshot equals the
/// Forecast tab at the moment it was taken.
public struct SQLiteForecastSnapshotRepository: ForecastSnapshotRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  @discardableResult
  public func takeIfNeeded(today: Day, rates: SnapshotRates, debts: [Currency: Int64] = [:]) async throws -> ForecastSnapshot? {
    let takenDay = today.string
    let needed = try await database.read { db in
      try Self.hasSnapshot(on: takenDay, db) == false && Self.hasActiveItem(db)
    }
    guard needed else { return nil }
    // End-of-today balances (R-ACC-3), the same figures the Forecast tab starts from.
    let balances = try await SQLiteReportQueries(database: database, calendar: calendar)
      .balances(on: [today], includeArchived: false)
      .balances.mapValues { $0.first ?? 0 }
    let snapshot = try await database.write { db -> ForecastSnapshot? in
      // Checked again inside the write: two activations racing must not store two rows.
      guard try !Self.hasSnapshot(on: takenDay, db), try Self.hasActiveItem(db) else { return nil }
      let horizon = Self.intSetting(.forecastHorizonDays, db) ?? ForecastEngine.defaultHorizonDays
      let grace = Self.intSetting(.scheduledGraceDays, db) ?? ScheduledOccurrences.defaultGraceDays
      let accounts = try Account.all.fetchAll(db)
      let items = try ScheduledItem.all.fetchAll(db)
      let resolved = try Self.resolvedKeys(db)
      let forecast = ForecastEngine.run(
        accounts: accounts, balances: balances, items: items, resolved: resolved, today: today,
        horizonDays: max(1, horizon), graceDays: max(0, grace))
      let start = SnapshotStartBalances(
        accounts: forecast.accounts.map {
          SnapshotAccountBalance(
            accountID: $0.id, currency: $0.currency, isLiability: $0.kind.isLiability, balanceMinor: balances[$0.id] ?? 0)
        },
        debts: debts)
      let snapshot = ForecastSnapshot(
        takenDay: takenDay, horizonDays: forecast.horizonDays, startBalancesJSON: try SnapshotJSON.encode(start),
        ratesJSON: try SnapshotJSON.encode(rates))
      try ForecastSnapshot.insert { snapshot }.execute(db)
      let rows = forecast.occurrences.compactMap { Self.item(snapshotID: snapshot.id, $0) }
      for part in rows.chunked(200) {
        try ForecastSnapshotItem.insert { Array(part) }.execute(db)
      }
      return snapshot
    }
    if snapshot != nil { try await prune(today: today) }
    return snapshot
  }

  @discardableResult
  public func prune(today: Day) async throws -> Int {
    try await database.write { db in
      let all = try ForecastSnapshot.all.fetchAll(db)
      let winners = Self.dedupe(all)
      let keepDays = ForecastSnapshotRetention.keep(winners.compactMap { Day($0.takenDay) }, today: today)
      let keepIDs = Set(winners.filter { Day($0.takenDay).map(keepDays.contains) ?? false }.map(\.id))
      let doomed = all.map(\.id).filter { !keepIDs.contains($0) }
      for part in doomed.chunked(200) {
        let ids = Array(part)
        // The schema cascades, but foreign keys may be off on some connections: delete explicitly.
        try ForecastSnapshotItem.where { $0.snapshotID.in(ids) }.delete().execute(db)
        try ForecastSnapshot.where { $0.id.in(ids) }.delete().execute(db)
      }
      return doomed.count
    }
  }

  public func snapshots() async throws -> [ForecastSnapshotSummary] {
    try await database.read { db in
      let winners = Self.dedupe(try ForecastSnapshot.all.fetchAll(db))
      var deltas: [ForecastSnapshot.ID: [Account.ID: Int64]] = [:]
      for part in winners.map(\.id).chunked(200) {
        let ids = Array(part)
        for item in try ForecastSnapshotItem.where({ $0.snapshotID.in(ids) }).fetchAll(db) {
          deltas[item.snapshotID, default: [:]][item.accountID, default: 0] += item.amountMinor
          if let to = item.toAccountID, let amount = item.toAmountMinor {
            deltas[item.snapshotID, default: [:]][to, default: 0] += amount
          }
        }
      }
      return winners.compactMap { snapshot -> ForecastSnapshotSummary? in
        guard let day = Day(snapshot.takenDay), let decoded = Self.decode(snapshot) else { return nil }
        let delta = deltas[snapshot.id] ?? [:]
        var end: [Account.ID: Int64] = [:]
        for account in decoded.start.accounts { end[account.accountID] = account.balanceMinor + (delta[account.accountID] ?? 0) }
        return ForecastSnapshotSummary(
          id: snapshot.id, takenDay: day, horizonDays: snapshot.horizonDays, createdAt: snapshot.createdAt,
          start: decoded.start, rates: decoded.rates, endBalances: end)
      }
    }
  }

  public func snapshot(_ id: ForecastSnapshot.ID) async throws -> ForecastSnapshotContent? {
    try await database.read { db in
      guard let snapshot = try ForecastSnapshot.where({ $0.id.eq(id) }).fetchOne(db) else { return nil }
      return try Self.content(snapshot, db)
    }
  }

  public func snapshot(takenOn day: Day) async throws -> ForecastSnapshotContent? {
    let takenDay = day.string
    return try await database.read { db in
      let rows = try ForecastSnapshot.where { $0.takenDay.eq(takenDay) }.fetchAll(db)
      guard let winner = Self.dedupe(rows).first else { return nil }
      return try Self.content(winner, db)
    }
  }

  // MARK: Helpers

  /// One row per `takenDay`, the newest `createdAt` (then the larger id, so the choice is stable
  /// on every device); newest day first.
  static func dedupe(_ snapshots: [ForecastSnapshot]) -> [ForecastSnapshot] {
    var best: [String: ForecastSnapshot] = [:]
    for snapshot in snapshots {
      if let current = best[snapshot.takenDay],
        (current.createdAt, current.id.uuidString) >= (snapshot.createdAt, snapshot.id.uuidString)
      {
        continue
      }
      best[snapshot.takenDay] = snapshot
    }
    return best.values.sorted { $0.takenDay > $1.takenDay }
  }

  static func decode(_ snapshot: ForecastSnapshot) -> (start: SnapshotStartBalances, rates: SnapshotRates)? {
    guard let start = try? SnapshotJSON.decode(SnapshotStartBalances.self, snapshot.startBalancesJSON),
      let rates = try? SnapshotJSON.decode(SnapshotRates.self, snapshot.ratesJSON)
    else { return nil }
    return (start, rates)
  }

  static func content(_ snapshot: ForecastSnapshot, _ db: Database) throws -> ForecastSnapshotContent? {
    guard let decoded = decode(snapshot) else { return nil }
    let id = snapshot.id
    let items = try ForecastSnapshotItem.where { $0.snapshotID.eq(id) }.fetchAll(db)
      .sorted { ($0.day, $0.itemID?.uuidString ?? "", $0.id.uuidString) < ($1.day, $1.itemID?.uuidString ?? "", $1.id.uuidString) }
    return ForecastSnapshotContent(snapshot: snapshot, start: decoded.start, rates: decoded.rates, items: items)
  }

  static func hasSnapshot(on takenDay: String, _ db: Database) throws -> Bool {
    try ForecastSnapshot.where { $0.takenDay.eq(takenDay) }.fetchCount(db) > 0
  }

  static func hasActiveItem(_ db: Database) throws -> Bool {
    try ScheduledItem.where { $0.status.eq(ScheduledItemStatus.active) }.fetchCount(db) > 0
  }

  static func resolvedKeys(_ db: Database) throws -> Set<OccurrenceKey> {
    Set(try ScheduledOccurrence.all.fetchAll(db).compactMap { occurrence in
      Day(occurrence.expectedDay).map { OccurrenceKey(itemID: occurrence.itemID, day: $0) }
    })
  }

  static func intSetting(_ key: SettingKey, _ db: Database) -> Int? {
    (try? SQLiteSettingsRepository.value(key, db)).flatMap { $0.flatMap { Int($0) } }
  }

  /// The occurrence as a snapshot row: the expected day (overdue ones keep their day; the overlay
  /// counts them on the snapshot day, as the forecast does), first effect on `accountID`, the
  /// transfer's second effect on `toAccountID`.
  static func item(snapshotID: ForecastSnapshot.ID, _ occurrence: ExpectedOccurrence) -> ForecastSnapshotItem? {
    guard let first = occurrence.effects.first else { return nil }
    let second = occurrence.effects.dropFirst().first
    return ForecastSnapshotItem(
      snapshotID: snapshotID, itemID: occurrence.itemID, day: occurrence.expectedDay.string, accountID: first.accountID,
      toAccountID: second?.accountID, amountMinor: first.amountMinor, toAmountMinor: second?.amountMinor)
  }
}
