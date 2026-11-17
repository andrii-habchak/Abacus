import AbacusDomain
import Foundation
import SQLiteData

// Resolved occurrences (R-REC-3, R-REC-4, R-REC-9), store-level matching after a manual save and
// the launch sweep (R-REC-7b/c), and what the import pipeline needs (R-REC-7a).
// Nothing here creates or changes a transaction (R-REC-3).

extension SQLiteScheduledStore {
  public func occurrences(itemID: ScheduledItem.ID?) async throws -> [ScheduledOccurrence] {
    try await database.read { db in
      try ScheduledOccurrence
        .where { if let itemID { $0.itemID.eq(itemID) } }
        .order { ($0.expectedDay, $0.resolvedAt, $0.id) }
        .fetchAll(db)
    }
  }

  public func resolvedKeys() async throws -> Set<OccurrenceKey> {
    try await database.read { db in try ScheduledRules.resolvedKeys(db) }
  }

  @discardableResult
  public func markPaid(
    itemID: ScheduledItem.ID, expectedDay: Day, txnID: Txn.ID, kind: OccurrenceMatchKind
  ) async throws -> ScheduledOccurrence {
    let now = now()
    let calendar = self.calendar
    return try await database.write { db in
      let item = try Self.occurrenceItem(itemID, expectedDay, db)
      guard let txn = try Txn.find(txnID).fetchOne(db) else { throw RepositoryError.notFound }
      return try ScheduledRules.pay(item: item, day: expectedDay, txn: txn, kind: kind, now: now, calendar: calendar, db)
    }
  }

  @discardableResult
  public func skip(itemID: ScheduledItem.ID, expectedDay: Day) async throws -> ScheduledOccurrence {
    let now = now()
    return try await database.write { db in
      let item = try Self.occurrenceItem(itemID, expectedDay, db)
      var rows = try ScheduledRules.rows(itemID: itemID, day: expectedDay, db)
      var row: ScheduledOccurrence
      if let first = rows.first {
        if first.status == .paid { throw ScheduledError.occurrenceAlreadyPaid }
        row = first
        rows.removeFirst()
      } else {
        row = ScheduledOccurrence(
          itemID: itemID, expectedDay: expectedDay.string, expectedAmountMinor: item.amountMinor, status: .skipped,
          resolvedAt: now)
      }
      for duplicate in rows { try ScheduledOccurrence.find(duplicate.id).delete().execute(db) }
      row.status = .skipped
      row.resolvedAt = now
      try ScheduledOccurrence.upsert { ScheduledOccurrence.Draft(row) }.execute(db)
      try ScheduledRules.endIfFinished(itemID, db)
      return row
    }
  }

  public func reopen(_ id: ScheduledOccurrence.ID) async throws {
    let now = now()
    try await database.write { db in
      guard let row = try ScheduledOccurrence.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      // An unlinked transaction is not taken again by automatic matching.
      if row.status == .paid, let txnID = row.txnID, let account = try Txn.find(txnID).fetchOne(db)?.accountID {
        let key = ScheduledRules.unlinkKey(txnID)
        if try SuggestionDismissal.where({ $0.key.eq(key) }).fetchCount(db) == 0 {
          try SuggestionDismissal.insert { SuggestionDismissal(accountID: account, key: key, dismissedAt: now) }.execute(db)
        }
      }
      let itemID = row.itemID
      let day = row.expectedDay
      try ScheduledOccurrence.where { $0.itemID.eq(itemID) && $0.expectedDay.eq(day) }.delete().execute(db)
      try ScheduledRules.reactivateUnfinished(db)
    }
  }

  /// The item, when `day` is one of its occurrences.
  static func occurrenceItem(_ itemID: ScheduledItem.ID, _ day: Day, _ db: Database) throws -> ScheduledItem {
    guard let item = try ScheduledItem.find(itemID).fetchOne(db) else { throw RepositoryError.notFound }
    guard item.schedule?.occurrences(from: day, through: day) == [day] else { throw ScheduledError.notAnOccurrence }
    return item
  }
}

// MARK: - Matching and the launch sweep

extension SQLiteScheduledStore: ScheduledMaintenance {
  /// Days before the grace period the launch sweep still matches transactions in (a statement
  /// imported a month late still resolves its missed occurrences).
  public static let sweepLookbackDays = 31

  @discardableResult
  public func matchTransaction(_ txnID: Txn.ID, matcher: any ScheduledMatching) async throws -> ScheduledOccurrence? {
    let now = now()
    let calendar = self.calendar
    return try await database.write { db in
      guard let txn = try Txn.find(txnID).fetchOne(db) else { throw RepositoryError.notFound }
      // Already linked: the link stays (spec §4, edited out of tolerance); actual day and amount follow.
      let linked = try ScheduledOccurrence.where { $0.txnID.eq(txnID) }.fetchAll(db)
      if var row = linked.first {
        row.actualDay = Day(txn.occurredAt, calendar: calendar).string
        row.actualAmountMinor = txn.amountMinor
        try ScheduledOccurrence.upsert { ScheduledOccurrence.Draft(row) }.execute(db)
        return row
      }
      guard try !Self.isUnlinked(txnID, db), let probe = matcher.probe(txn, calendar: calendar) else { return nil }
      let candidates = try Self.candidates(
        from: probe.day.plusDays(-matcher.dayWindow), through: probe.day.plusDays(matcher.dayWindow), db
      ).filter { $0.item.accountID == probe.accountID }
      guard let match = matcher.assign([probe], to: candidates).first,
        let candidate = candidates.first(where: { $0.item.id == match.itemID && $0.day == match.expectedDay })
      else { return nil }
      return try ScheduledRules.pay(
        item: candidate.item, day: candidate.day, txn: txn, kind: .auto,
        expectedAmountMinor: candidate.expectedAmountMinor, now: now, calendar: calendar, db)
    }
  }

  @discardableResult
  public func sweep(today: Day, matcher: any ScheduledMatching) async throws -> ScheduledSweepResult {
    let now = now()
    let calendar = self.calendar
    return try await database.write { db in
      var result = ScheduledSweepResult()

      // 1. Pause / resume by the accounts' archive state (R-REC-5).
      for var item in try ScheduledRules.items(db) {
        let archived = try ScheduledRules.anyArchived(item, db)
        if archived, item.status == .active {
          item.status = .paused
          item.pausedBecause = .accountArchived
          result.paused += 1
        } else if !archived, item.status == .paused, item.pausedBecause == .accountArchived {
          item.status = .active
          item.pausedBecause = nil
          try ScheduledRules.skipPausedGap(item, today: today, now: now, calendar: calendar, db)
          result.resumed += 1
        } else {
          continue
        }
        try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
      }

      // 2. Matches whose transaction is gone are expected again.
      result.reopened = try ScheduledRules.reopenOrphans(db)

      // 3. Match transactions not linked yet (abacus-import, later MCP writes; R-REC-7c).
      let grace = try ScheduledRules.graceDays(db)
      let window = matcher.dayWindow
      let from = today.plusDays(-grace - Self.sweepLookbackDays)
      let through = today.plusDays(window)
      let candidates = try Self.candidates(from: from, through: through, db)
      if !candidates.isEmpty {
        let accounts = Set(candidates.map(\.item.accountID))
        let bounds = DayBounds(calendar: calendar)
        let start = bounds.start(from.plusDays(-window))
        let end = bounds.end(through.plusDays(window))
        let linked = Set(try ScheduledOccurrence.where { $0.txnID.isNot(nil) }.fetchAll(db).compactMap(\.txnID))
        let unlinked = try Self.unlinkedTxns(db)
        var txns: [Txn.ID: Txn] = [:]
        var probes: [ScheduledProbe] = []
        for txn in try Txn.where({ $0.occurredAt >= start && $0.occurredAt < end }).order { ($0.occurredAt, $0.id) }.fetchAll(db)
        where accounts.contains(txn.accountID) && !linked.contains(txn.id) && !unlinked.contains(txn.id) {
          guard let probe = matcher.probe(txn, calendar: calendar) else { continue }
          txns[txn.id] = txn
          probes.append(probe)
        }
        let byKey = Dictionary(candidates.map { (OccurrenceKey(itemID: $0.item.id, day: $0.day), $0) }, uniquingKeysWith: { a, _ in a })
        for match in matcher.assign(probes, to: candidates) {
          guard let txnID = UUID(uuidString: match.probeKey), let txn = txns[txnID],
            let candidate = byKey[OccurrenceKey(itemID: match.itemID, day: match.expectedDay)]
          else { continue }
          try ScheduledRules.pay(
            item: candidate.item, day: candidate.day, txn: txn, kind: .auto,
            expectedAmountMinor: candidate.expectedAmountMinor, now: now, calendar: calendar, db)
          result.matched += 1
        }
      }

      // 4. Unresolved past the grace period → missed (R-REC-9). Occurrences before the item was
      // created are not generated (spec §4 "Item starts in the past").
      let items = try ScheduledRules.items(db).filter { $0.status == .active }
      let resolved = try ScheduledRules.resolvedKeys(db)
      for (item, day) in ScheduledOccurrences.missed(items: items, resolved: resolved, today: today, graceDays: grace)
      where day >= Day(item.createdAt, calendar: calendar) {
        try ScheduledOccurrence.insert {
          ScheduledOccurrence(
            itemID: item.id, expectedDay: day.string, expectedAmountMinor: item.amountMinor, status: .missed,
            resolvedAt: now)
        }.execute(db)
        result.missed += 1
      }

      // 5. Finite series whose last occurrence is resolved end.
      for item in try ScheduledRules.items(db) where item.status == .active {
        try ScheduledRules.endIfFinished(item.id, db)
        if try ScheduledItem.find(item.id).fetchOne(db)?.status == .ended { result.ended += 1 }
      }
      return result
    }
  }

  /// Occurrences a transaction may resolve, `from…through`: expected ones of active items on
  /// existing, non-archived accounts, and stored missed ones (a late statement still pays them).
  static func candidates(from: Day, through: Day, _ db: Database) throws -> [ScheduledCandidate] {
    let usable = Set(try Account.where { !$0.isArchived }.fetchAll(db).map(\.id))
    let stored = try ScheduledOccurrence.fetchAll(db)
    var byKey: [OccurrenceKey: ScheduledOccurrence] = [:]
    for row in stored.sorted(by: { ($0.resolvedAt, $0.id.uuidString) < ($1.resolvedAt, $1.id.uuidString) }) {
      guard let day = Day(row.expectedDay) else { continue }
      let key = OccurrenceKey(itemID: row.itemID, day: day)
      if byKey[key] == nil { byKey[key] = row }
    }
    var result: [ScheduledCandidate] = []
    for item in try ScheduledRules.items(db) where item.status == .active && usable.contains(item.accountID) {
      guard let schedule = item.schedule else { continue }
      for day in schedule.occurrences(from: from, through: through) {
        if let row = byKey[OccurrenceKey(itemID: item.id, day: day)] {
          if row.status == .missed, row.txnID == nil {
            result.append(ScheduledCandidate(item: item, day: day, expectedAmountMinor: row.expectedAmountMinor))
          }
        } else {
          result.append(ScheduledCandidate(item: item, day: day))
        }
      }
    }
    return result
  }

  static func unlinkedTxns(_ db: Database) throws -> Set<Txn.ID> {
    let prefix = ScheduledRules.unlinkKeyPrefix
    return Set(try SuggestionDismissal.fetchAll(db).compactMap { row in
      row.key.hasPrefix(prefix) ? UUID(uuidString: String(row.key.dropFirst(prefix.count))) : nil
    })
  }

  static func isUnlinked(_ txnID: Txn.ID, _ db: Database) throws -> Bool {
    let key = ScheduledRules.unlinkKey(txnID)
    return try SuggestionDismissal.where { $0.key.eq(key) }.fetchCount(db) > 0
  }
}

// MARK: - Import (R-REC-7a)

extension SQLiteImportStore: ScheduledImportMatching {
  public func scheduledCandidates(from: Day, through: Day) async throws -> [ScheduledCandidate] {
    try await database.read { db in try SQLiteScheduledStore.candidates(from: from, through: through, db) }
  }

  @discardableResult
  public func recordScheduledMatches(_ matches: [ScheduledImportMatch]) async throws -> Int {
    guard !matches.isEmpty else { return 0 }
    let calendar = self.calendar
    let now = Date()
    return try await database.write { db in
      var count = 0
      for match in matches {
        let keys = match.fingerprints
        guard !keys.isEmpty,
          let txnID = try ImportFingerprint.where({ $0.id.in(keys) }).fetchAll(db).first?.txnID,
          let txn = try Txn.find(txnID).fetchOne(db),
          let item = try ScheduledItem.find(match.itemID).fetchOne(db), item.status == .active
        else { continue }
        let rows = try ScheduledRules.rows(itemID: item.id, day: match.expectedDay, db)
        // Resolved meanwhile (other than missed) or the transaction is taken: leave it.
        if let first = rows.first, first.status != .missed { continue }
        if try ScheduledOccurrence.where({ $0.txnID.eq(txnID) }).fetchCount(db) > 0 { continue }
        try ScheduledRules.pay(
          item: item, day: match.expectedDay, txn: txn, kind: .auto, expectedAmountMinor: rows.first?.expectedAmountMinor,
          now: now, calendar: calendar, db)
        count += 1
      }
      return count
    }
  }
}
