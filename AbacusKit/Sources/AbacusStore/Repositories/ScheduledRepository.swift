import AbacusDomain
import Foundation
import SQLiteData

/// Scheduled items, their resolved occurrences and dismissed suggestions (N5, R-REC-1…9, 16).
/// One value implements the item, occurrence, dismissal and maintenance contracts; the matching
/// rule is passed in (`ScheduledMatching`, from `AbacusImport`).
///
/// The tables have no UNIQUE and no cascade relied on (CloudKit rules), so identity of an
/// occurrence (item, expected day) is guarded here, and every read tolerates the duplicates a
/// sync could produce (first by `resolvedAt` wins).
public struct SQLiteScheduledStore: ScheduledItemRepository, ScheduledOccurrenceRepository, SuggestionDismissalRepository {
  public let database: any DatabaseWriter
  /// Turns `Txn.occurredAt` into a day (once per transaction; occurrence days are plain days).
  public let calendar: Calendar
  public let now: @Sendable () -> Date

  public init(database: any DatabaseWriter, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
    self.database = database
    self.calendar = calendar
    self.now = now
  }

  // MARK: - Items (R-REC-1, R-REC-5)

  public func items() async throws -> [ScheduledItem] {
    try await database.read { db in try ScheduledRules.items(db) }
  }

  public func item(_ id: ScheduledItem.ID) async throws -> ScheduledItem? {
    try await database.read { db in try ScheduledItem.find(id).fetchOne(db) }
  }

  public func save(_ item: ScheduledItem) async throws {
    try await database.write { db in
      var item = item
      try ScheduledRules.validate(item, db)
      // An active item on an archived account is paused for that reason (R-REC-5).
      if item.status == .active, try ScheduledRules.isArchived(item.accountID, db) {
        item.status = .paused
        item.pausedBecause = .accountArchived
      }
      if item.status != .paused { item.pausedBecause = nil }
      try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
    }
  }

  public func setPaused(_ id: ScheduledItem.ID, _ paused: Bool, today: Day) async throws {
    let calendar = self.calendar
    let now = now()
    try await database.write { db in
      guard var item = try ScheduledItem.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      if paused {
        guard item.status == .active else { return }
        item.status = .paused
        item.pausedBecause = .owner
      } else {
        guard item.status == .paused, try !ScheduledRules.isArchived(item.accountID, db) else { return }
        item.status = .active
        item.pausedBecause = nil
        try ScheduledRules.skipPausedGap(item, today: today, now: now, calendar: calendar, db)
      }
      try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
    }
  }

  public func delete(_ id: ScheduledItem.ID) async throws {
    try await database.write { db in
      try ScheduledItem.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  // MARK: - Dismissed suggestions (R-REC-16)

  public func dismissals() async throws -> [SuggestionDismissal] {
    try await database.read { db in
      try SuggestionDismissal.order { ($0.dismissedAt, $0.id) }.fetchAll(db)
        .filter { !$0.key.hasPrefix(ScheduledRules.unlinkKeyPrefix) }
    }
  }

  public func dismiss(accountID: Account.ID, key: String) async throws {
    let now = now()
    try await database.write { db in
      let existing = try SuggestionDismissal.where { $0.accountID.eq(accountID) && $0.key.eq(key) }.fetchCount(db)
      guard existing == 0 else { return }
      try SuggestionDismissal.insert { SuggestionDismissal(accountID: accountID, key: key, dismissedAt: now) }.execute(db)
    }
  }

  /// Restores the suggestion: every row with the same (account, key) goes, so a synced duplicate
  /// cannot keep it hidden.
  public func restore(_ id: SuggestionDismissal.ID) async throws {
    try await database.write { db in
      guard let row = try SuggestionDismissal.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      let accountID = row.accountID
      let key = row.key
      try SuggestionDismissal.where { $0.accountID.eq(accountID) && $0.key.eq(key) }.delete().execute(db)
    }
  }
}

/// Database-level rules shared by the scheduled store and the hooks in other repositories
/// (account archive / delete / currency, transaction delete, import undo).
public enum ScheduledRules {
  /// Dismissal rows with this key prefix remember a transaction the owner unlinked, so automatic
  /// matching never takes it again (no schema change needed; hidden from `dismissals()`).
  public static let unlinkKeyPrefix = "unlinked-txn|"

  static func unlinkKey(_ txnID: Txn.ID) -> String { unlinkKeyPrefix + txnID.uuidString.lowercased() }

  static func items(_ db: Database) throws -> [ScheduledItem] {
    try ScheduledItem.order { ($0.createdAt, $0.id) }.fetchAll(db)
  }

  static func isArchived(_ accountID: Account.ID, _ db: Database) throws -> Bool {
    try Account.find(accountID).fetchOne(db)?.isArchived ?? false
  }

  /// R-REC-1 / R-REC-12 validation.
  static func validate(_ item: ScheduledItem, _ db: Database) throws {
    guard item.amountMinor > 0 else { throw ScheduledError.invalidItem("The amount must be above zero") }
    guard item.interval >= 1 else { throw ScheduledError.invalidItem("Repeat every 1 or more") }
    guard (0...100).contains(item.tolerancePercent) else { throw ScheduledError.invalidItem("Tolerance must be 0–100 %") }
    guard let start = Day(item.startDay) else { throw ScheduledError.invalidItem("Invalid start day") }
    switch item.endKind {
    case .never: break
    case .onDay:
      guard let end = item.endDay.flatMap(Day.init), end >= start else {
        throw ScheduledError.invalidItem("The end day must be on or after the start")
      }
    case .afterCount:
      guard let count = item.endCount, count >= 1 else { throw ScheduledError.invalidItem("End after 1 or more times") }
    }
    guard try Account.find(item.accountID).fetchCount(db) > 0 else { throw ScheduledError.invalidItem("Unknown account") }
    if item.type == .transfer {
      guard let to = item.toAccountID, to != item.accountID else {
        throw ScheduledError.invalidItem("A transfer needs two different accounts")
      }
      guard try Account.find(to).fetchCount(db) > 0 else { throw ScheduledError.invalidItem("Unknown account") }
    } else if item.toAccountID != nil || item.toAmountMinor != nil {
      throw ScheduledError.invalidItem("Only a transfer has a receiving account")
    }
    if let toAmount = item.toAmountMinor, toAmount <= 0 {
      throw ScheduledError.invalidItem("The received amount must be above zero")
    }
  }

  // MARK: Account hooks (R-REC-5)

  /// R-REC-5 / R-ACC-1: an account with scheduled items (either side) keeps its currency.
  public static func hasItems(onAccount accountID: Account.ID, _ db: Database) throws -> Bool {
    try ScheduledItem.where { $0.accountID.eq(accountID) || $0.toAccountID.eq(accountID) }.fetchCount(db) > 0
  }

  /// R-REC-5: archiving pauses the account's active items ("Account archived"); unarchiving
  /// resumes only those. Items on either side of a transfer count.
  public static func accountArchived(
    _ accountID: Account.ID, _ isArchived: Bool, today: Day, now: Date, calendar: Calendar, _ db: Database
  ) throws {
    for var item in try ScheduledItem.where({ $0.accountID.eq(accountID) || $0.toAccountID.eq(accountID) }).fetchAll(db) {
      if isArchived, item.status == .active {
        item.status = .paused
        item.pausedBecause = .accountArchived
      } else if !isArchived, item.status == .paused, item.pausedBecause == .accountArchived,
        try !anyArchived(item, db)
      {
        item.status = .active
        item.pausedBecause = nil
        try skipPausedGap(item, today: today, now: now, calendar: calendar, db)
      } else {
        continue
      }
      try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
    }
  }

  static func anyArchived(_ item: ScheduledItem, _ db: Database) throws -> Bool {
    if try isArchived(item.accountID, db) { return true }
    if let to = item.toAccountID, try isArchived(to, db) { return true }
    return false
  }

  /// R-REC-5: deleting an account deletes its items (either side); their history stays.
  public static func accountDeleted(_ accountID: Account.ID, _ db: Database) throws {
    try ScheduledItem.where { $0.accountID.eq(accountID) || $0.toAccountID.eq(accountID) }.delete().execute(db)
  }

  /// A resumed item does not report its paused period as missed (spec §4 "Account unarchived":
  /// the gap is not generated as overdue): unresolved occurrences older than the grace period are
  /// stored as skipped.
  static func skipPausedGap(_ item: ScheduledItem, today: Day, now: Date, calendar: Calendar, _ db: Database) throws {
    let grace = try graceDays(db)
    let resolved = try resolvedKeys(db)
    let gap = ScheduledOccurrences.missed(items: [item], resolved: resolved, today: today, graceDays: grace)
    for (item, day) in gap {
      try ScheduledOccurrence.insert {
        ScheduledOccurrence(
          itemID: item.id, expectedDay: day.string, expectedAmountMinor: item.amountMinor, status: .skipped,
          resolvedAt: now)
      }.execute(db)
    }
  }

  // MARK: Occurrences

  static func graceDays(_ db: Database) throws -> Int {
    let key = SettingKey.scheduledGraceDays.rawValue
    let raw = try AppSetting.where { $0.id.eq(key) }.fetchOne(db)?.value
    return raw.flatMap(Int.init).map { max(0, $0) } ?? ScheduledOccurrences.defaultGraceDays
  }

  static func resolvedKeys(_ db: Database) throws -> Set<OccurrenceKey> {
    Set(try ScheduledOccurrence.fetchAll(db).compactMap { o in
      Day(o.expectedDay).map { OccurrenceKey(itemID: o.itemID, day: $0) }
    })
  }

  /// The stored rows of one identity, first by `resolvedAt` (the winner of a sync clash) first.
  static func rows(itemID: ScheduledItem.ID, day: Day, _ db: Database) throws -> [ScheduledOccurrence] {
    let text = day.string
    return try ScheduledOccurrence.where { $0.itemID.eq(itemID) && $0.expectedDay.eq(text) }
      .order { ($0.resolvedAt, $0.id) }
      .fetchAll(db)
  }

  /// Writes (item, day) as paid by `txn`; a missed or skipped row of that identity becomes paid,
  /// a row paid by another transaction refuses. The transaction is only read.
  @discardableResult
  static func pay(
    item: ScheduledItem, day: Day, txn: Txn, kind: OccurrenceMatchKind, expectedAmountMinor: Int64? = nil,
    now: Date, calendar: Calendar, _ db: Database
  ) throws -> ScheduledOccurrence {
    let txnID = txn.id
    let elsewhere = try ScheduledOccurrence.where { $0.txnID.eq(txnID) }.fetchAll(db)
      .filter { !($0.itemID == item.id && $0.expectedDay == day.string) }
    if !elsewhere.isEmpty { throw ScheduledError.transactionAlreadyLinked }
    var rows = try rows(itemID: item.id, day: day, db)
    var row: ScheduledOccurrence
    if let first = rows.first {
      if first.status == .paid, let linked = first.txnID, linked != txn.id { throw ScheduledError.occurrenceAlreadyPaid }
      row = first
      rows.removeFirst()
    } else {
      row = ScheduledOccurrence(
        itemID: item.id, expectedDay: day.string, expectedAmountMinor: expectedAmountMinor ?? item.amountMinor,
        status: .paid, resolvedAt: now)
    }
    // Synced duplicates of the identity go.
    for duplicate in rows { try ScheduledOccurrence.find(duplicate.id).delete().execute(db) }
    row.status = .paid
    row.txnID = txn.id
    row.actualDay = Day(txn.occurredAt, calendar: calendar).string
    row.actualAmountMinor = txn.amountMinor
    row.matchKind = kind
    row.resolvedAt = now
    try ScheduledOccurrence.upsert { ScheduledOccurrence.Draft(row) }.execute(db)
    try endIfFinished(item.id, db)
    return row
  }

  /// R-REC-7 / spec §4: a paid occurrence whose transaction is gone (deleted, undone import,
  /// `ON DELETE SET NULL`) is expected again. Returns how many.
  @discardableResult
  public static func reopenOrphans(_ db: Database) throws -> Int {
    var count = 0
    for row in try ScheduledOccurrence.where({ $0.txnID.is(nil) }).fetchAll(db) where row.status == .paid {
      try ScheduledOccurrence.find(row.id).delete().execute(db)
      count += 1
    }
    if count > 0 { try reactivateUnfinished(db) }
    return count
  }

  /// Before the transactions of `txnIDs` are deleted: their occurrences become expected again.
  public static func reopen(paidBy txnIDs: [Txn.ID], _ db: Database) throws {
    for part in txnIDs.chunked(500) {
      let ids = part.map { Optional($0) }
      try ScheduledOccurrence.where { $0.txnID.in(ids) }.delete().execute(db)
    }
    try reactivateUnfinished(db)
  }

  /// R-REC-1 / spec §4 "End reached": an item with a finite series whose last occurrence is
  /// resolved (paid, skipped or missed) is ended.
  static func endIfFinished(_ itemID: ScheduledItem.ID, _ db: Database) throws {
    guard var item = try ScheduledItem.find(itemID).fetchOne(db), item.status == .active,
      let last = item.schedule?.lastOccurrence
    else { return }
    guard try !rows(itemID: itemID, day: last, db).isEmpty else { return }
    item.status = .ended
    try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
  }

  /// An ended item whose last occurrence became expected again (unlinked, transaction deleted) is
  /// active again.
  static func reactivateUnfinished(_ db: Database) throws {
    for var item in try ScheduledItem.fetchAll(db) where item.status == .ended {
      guard let last = item.schedule?.lastOccurrence, try rows(itemID: item.id, day: last, db).isEmpty else { continue }
      item.status = try anyArchived(item, db) ? .paused : .active
      item.pausedBecause = item.status == .paused ? .accountArchived : nil
      try ScheduledItem.upsert { ScheduledItem.Draft(item) }.execute(db)
    }
  }
}
