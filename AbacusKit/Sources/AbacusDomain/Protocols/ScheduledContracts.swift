import Foundation

// N5 (R-REC): contracts of the scheduled-items repositories, the matching of real transactions to
// expected occurrences and the launch sweep. The store implements them; the matching rule itself
// lives in `AbacusImport` (`ScheduledMatch`) and is passed in as a `ScheduledMatching` value, so the
// store does not depend on the importer.

public enum ScheduledError: Error, Equatable, Sendable {
  /// R-REC-1 / R-REC-12: the item cannot be saved (the text says which rule).
  case invalidItem(String)
  /// The day is not an occurrence of the item.
  case notAnOccurrence
  /// Identity (item, expected day) is already paid with another transaction (R-REC-6).
  case occurrenceAlreadyPaid
  /// The transaction already resolves another occurrence (R-REC-6: one per occurrence).
  case transactionAlreadyLinked
}

// MARK: - Repositories

/// Scheduled items (R-REC-1, R-REC-5).
public protocol ScheduledItemRepository: Sendable {
  /// Every item, any status, oldest first.
  func items() async throws -> [ScheduledItem]
  func item(_ id: ScheduledItem.ID) async throws -> ScheduledItem?
  /// Inserts or updates after validation. Editing changes future occurrences only; resolved ones
  /// keep what they were expected with (R-REC-4).
  func save(_ item: ScheduledItem) async throws
  /// The owner's pause / resume. Resuming an item paused because of its archived account is
  /// refused while the account is archived (the item stays paused).
  func setPaused(_ id: ScheduledItem.ID, _ paused: Bool, today: Day) async throws
  /// Deletes the item; its stored occurrences and matched transactions stay (R-REC-1).
  func delete(_ id: ScheduledItem.ID) async throws
}

/// Resolved and missed occurrences (R-REC-3, R-REC-4, R-REC-9). Expected ones are computed.
public protocol ScheduledOccurrenceRepository: Sendable {
  /// Stored occurrences, of one item or of all (nil), by expected day.
  func occurrences(itemID: ScheduledItem.ID?) async throws -> [ScheduledOccurrence]
  /// (item, day) of every stored occurrence: what `ScheduledOccurrences.expected` skips.
  func resolvedKeys() async throws -> Set<OccurrenceKey>
  /// Paid by `txnID` ("Mark paid" saves a typed transaction, "Link existing…" a picked one).
  /// The transaction itself is never changed.
  @discardableResult
  func markPaid(
    itemID: ScheduledItem.ID, expectedDay: Day, txnID: Txn.ID, kind: OccurrenceMatchKind
  ) async throws -> ScheduledOccurrence
  /// "Skip this one".
  @discardableResult
  func skip(itemID: ScheduledItem.ID, expectedDay: Day) async throws -> ScheduledOccurrence
  /// Back to expected: unlinks a paid occurrence (the transaction is not matched automatically
  /// again) or undoes a skip / missed mark.
  func reopen(_ id: ScheduledOccurrence.ID) async throws
}

/// Dismissed subscription suggestions (R-REC-16).
public protocol SuggestionDismissalRepository: Sendable {
  /// Dismissed suggestions (internal unlink markers left out).
  func dismissals() async throws -> [SuggestionDismissal]
  func dismiss(accountID: Account.ID, key: String) async throws
  /// "Show dismissed" → restore.
  func restore(_ id: SuggestionDismissal.ID) async throws
}

// MARK: - Matching (R-REC-6, R-REC-7)

/// What matching needs to know about a real transaction or an import row.
public struct ScheduledProbe: Hashable, Sendable {
  /// The transaction id (`uuidString`) or the import row id.
  public var key: String
  /// The account the money leaves (expense, transfer) or arrives on (income).
  public var accountID: Account.ID
  public var type: TxnType
  public var amountMinor: Int64
  public var payee: String
  public var day: Day

  public init(key: String, accountID: Account.ID, type: TxnType, amountMinor: Int64, payee: String, day: Day) {
    self.key = key
    self.accountID = accountID
    self.type = type
    self.amountMinor = amountMinor
    self.payee = payee
    self.day = day
  }
}

/// An occurrence a transaction may resolve: expected (computed) or stored as missed.
public struct ScheduledCandidate: Hashable, Sendable {
  public var item: ScheduledItem
  public var day: Day
  /// The amount it is expected with (the template's now, or the one stored with a missed row).
  public var expectedAmountMinor: Int64

  public init(item: ScheduledItem, day: Day, expectedAmountMinor: Int64? = nil) {
    self.item = item
    self.day = day
    self.expectedAmountMinor = expectedAmountMinor ?? item.amountMinor
  }
}

/// One probe resolves one candidate.
public struct ScheduledAssignment: Hashable, Sendable {
  public var probeKey: String
  public var itemID: ScheduledItem.ID
  public var expectedDay: Day

  public init(probeKey: String, itemID: ScheduledItem.ID, expectedDay: Day) {
    self.probeKey = probeKey
    self.itemID = itemID
    self.expectedDay = expectedDay
  }
}

/// The matching rule (implemented by `AbacusImport.ScheduledMatch.rule`).
public protocol ScheduledMatching: Sendable {
  /// Days a transaction may lie before or after the expected day.
  var dayWindow: Int { get }
  /// The probe of a stored transaction; nil when it can never resolve an occurrence (refund,
  /// balance correction, money in on a transfer source…).
  func probe(_ txn: Txn, calendar: Calendar) -> ScheduledProbe?
  /// Pairs probes with candidates: at most one each way; nearer day, then nearer amount wins.
  func assign(_ probes: [ScheduledProbe], to candidates: [ScheduledCandidate]) -> [ScheduledAssignment]
}

/// What the import preview needs from the store (implemented by the SQLite import store).
public protocol ScheduledImportMatching: Sendable {
  /// Unresolved (or missed) occurrences of active items on non-archived accounts, `from…through`.
  func scheduledCandidates(from: Day, through: Day) async throws -> [ScheduledCandidate]
  /// After a commit: marks the occurrences paid by the batch's transactions (found by their
  /// fingerprints), skipping any that were resolved meanwhile. Returns how many were written.
  @discardableResult
  func recordScheduledMatches(_ matches: [ScheduledImportMatch]) async throws -> Int
}

/// An import row's match, kept by the preview until the commit.
public struct ScheduledImportMatch: Hashable, Sendable {
  public var fingerprints: [String]
  public var itemID: ScheduledItem.ID
  public var expectedDay: Day

  public init(fingerprints: [String], itemID: ScheduledItem.ID, expectedDay: Day) {
    self.fingerprints = fingerprints
    self.itemID = itemID
    self.expectedDay = expectedDay
  }
}

/// Store-level matching after a manual save or edit and the idempotent launch sweep (R-REC-7b/c,
/// R-REC-9, R-REC-5). None of them creates or changes a transaction (R-REC-3).
public protocol ScheduledMaintenance: Sendable {
  /// After a manual save or edit: matches the transaction to an expected occurrence (or refreshes
  /// the actual day and amount of the occurrence it already resolves). Returns the occurrence.
  @discardableResult
  func matchTransaction(_ txnID: Txn.ID, matcher: any ScheduledMatching) async throws -> ScheduledOccurrence?
  /// At launch: pause/resume by archive state, return orphaned matches to expected, match recent
  /// transactions, store missed occurrences, end finished items. Running it twice changes nothing.
  @discardableResult
  func sweep(today: Day, matcher: any ScheduledMatching) async throws -> ScheduledSweepResult
}

public struct ScheduledSweepResult: Hashable, Sendable {
  public var paused = 0
  public var resumed = 0
  public var reopened = 0
  public var matched = 0
  public var missed = 0
  public var ended = 0

  public init() {}

  public var isEmpty: Bool { self == ScheduledSweepResult() }
}
