import Foundation
import SQLiteData

// N5 (R-REC): scheduled items, resolved occurrences, forecast snapshots, dismissed suggestions.
// Tables of migration v18. Days are `YYYY-MM-DD` strings (`Day`), money is minor units as
// documented per field. No UNIQUE and no cascade relied on for correctness (CloudKit rules).

public enum ScheduleUnit: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case day, week, month, year
}

public enum ScheduleEndKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case never, onDay, afterCount
}

/// Only `remind` exists in v1 (R-REC-3); stored so an auto-create mode needs no migration.
public enum ScheduleMode: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case remind
}

public enum ScheduledItemStatus: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case active, paused, ended
}

public enum PausedBecause: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case owner, accountArchived
}

public enum OccurrenceStatus: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case paid, skipped, missed
}

public enum OccurrenceMatchKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case auto, linked, typed
}

@Table("scheduledItems")
public struct ScheduledItem: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var type: TxnType
  /// From-account for a transfer. Plain id (no foreign key).
  public var accountID: Account.ID
  public var toAccountID: Account.ID?
  /// Positive, in the account's currency.
  public var amountMinor: Int64
  public var toAmountMinor: Int64?
  public var categoryID: Category.ID?
  public var eventID: Event.ID?
  public var payee: String
  public var note: String
  public var unit: ScheduleUnit
  /// Every N units, at least 1.
  public var interval: Int
  /// `YYYY-MM-DD`, the anchor of every occurrence date (R-REC-2).
  public var startDay: String
  public var lastDayOfMonth: Bool
  public var endKind: ScheduleEndKind
  public var endDay: String?
  public var endCount: Int?
  public var mode: ScheduleMode
  public var tolerancePercent: Int
  public var status: ScheduledItemStatus
  public var pausedBecause: PausedBecause?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), type: TxnType, accountID: Account.ID, toAccountID: Account.ID? = nil,
    amountMinor: Int64, toAmountMinor: Int64? = nil, categoryID: Category.ID? = nil,
    eventID: Event.ID? = nil, payee: String = "", note: String = "", unit: ScheduleUnit = .month,
    interval: Int = 1, startDay: String, lastDayOfMonth: Bool = false, endKind: ScheduleEndKind = .never,
    endDay: String? = nil, endCount: Int? = nil, mode: ScheduleMode = .remind, tolerancePercent: Int = 5,
    status: ScheduledItemStatus = .active, pausedBecause: PausedBecause? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.type = type
    self.accountID = accountID
    self.toAccountID = toAccountID
    self.amountMinor = amountMinor
    self.toAmountMinor = toAmountMinor
    self.categoryID = categoryID
    self.eventID = eventID
    self.payee = payee
    self.note = note
    self.unit = unit
    self.interval = interval
    self.startDay = startDay
    self.lastDayOfMonth = lastDayOfMonth
    self.endKind = endKind
    self.endDay = endDay
    self.endCount = endCount
    self.mode = mode
    self.tolerancePercent = tolerancePercent
    self.status = status
    self.pausedBecause = pausedBecause
    self.createdAt = createdAt
  }
}

/// A resolved or missed occurrence. Expected ones are computed, never stored. Identity is
/// (`itemID`, `expectedDay`), guarded by the repository.
@Table("scheduledOccurrences")
public struct ScheduledOccurrence: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var itemID: ScheduledItem.ID
  public var expectedDay: String
  /// The template amount at the time (positive; the flow comes from the item type).
  public var expectedAmountMinor: Int64
  public var status: OccurrenceStatus
  public var txnID: Txn.ID?
  public var actualDay: String?
  public var actualAmountMinor: Int64?
  public var matchKind: OccurrenceMatchKind?
  public var resolvedAt: Date

  public init(
    id: UUID = UUID(), itemID: ScheduledItem.ID, expectedDay: String, expectedAmountMinor: Int64,
    status: OccurrenceStatus, txnID: Txn.ID? = nil, actualDay: String? = nil,
    actualAmountMinor: Int64? = nil, matchKind: OccurrenceMatchKind? = nil, resolvedAt: Date = Date()
  ) {
    self.id = id
    self.itemID = itemID
    self.expectedDay = expectedDay
    self.expectedAmountMinor = expectedAmountMinor
    self.status = status
    self.txnID = txnID
    self.actualDay = actualDay
    self.actualAmountMinor = actualAmountMinor
    self.matchKind = matchKind
    self.resolvedAt = resolvedAt
  }
}

@Table("forecastSnapshots")
public struct ForecastSnapshot: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var takenDay: String
  public var horizonDays: Int
  /// `{accountID: minor}` plus currencies, read whole.
  public var startBalancesJSON: String
  /// Rates used, `{"asOf": day, "EUR": ...}`; makes an old snapshot reproducible.
  public var ratesJSON: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), takenDay: String, horizonDays: Int = 90, startBalancesJSON: String,
    ratesJSON: String, createdAt: Date = Date()
  ) {
    self.id = id
    self.takenDay = takenDay
    self.horizonDays = horizonDays
    self.startBalancesJSON = startBalancesJSON
    self.ratesJSON = ratesJSON
    self.createdAt = createdAt
  }
}

@Table("forecastSnapshotItems")
public struct ForecastSnapshotItem: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var snapshotID: ForecastSnapshot.ID
  public var itemID: UUID?
  public var day: String
  public var accountID: Account.ID
  public var toAccountID: Account.ID?
  /// Signed effect on `accountID`.
  public var amountMinor: Int64
  /// Signed effect on `toAccountID`.
  public var toAmountMinor: Int64?

  public init(
    id: UUID = UUID(), snapshotID: ForecastSnapshot.ID, itemID: UUID? = nil, day: String,
    accountID: Account.ID, toAccountID: Account.ID? = nil, amountMinor: Int64, toAmountMinor: Int64? = nil
  ) {
    self.id = id
    self.snapshotID = snapshotID
    self.itemID = itemID
    self.day = day
    self.accountID = accountID
    self.toAccountID = toAccountID
    self.amountMinor = amountMinor
    self.toAmountMinor = toAmountMinor
  }
}

@Table("suggestionDismissals")
public struct SuggestionDismissal: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var accountID: Account.ID
  /// `SubscriptionDetector.key` (normalised description, type, currency).
  public var key: String
  public var dismissedAt: Date

  public init(id: UUID = UUID(), accountID: Account.ID, key: String, dismissedAt: Date = Date()) {
    self.id = id
    self.accountID = accountID
    self.key = key
    self.dismissedAt = dismissedAt
  }
}
