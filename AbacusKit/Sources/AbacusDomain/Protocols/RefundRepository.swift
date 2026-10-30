import Foundation

public enum RefundError: Error, Equatable, Sendable {
  case notFound
  /// The transaction cannot be a refund: it must be an expense marked as a refund, or an income
  /// (which then becomes a refund), and not a balance correction, debt leg or transfer.
  case notRefundable
  /// The target must be an expense that is not itself a refund (nor a correction or debt leg).
  case invalidOriginal
  /// The linked refunds would exceed the original: `remainingMinor` (in the original's currency)
  /// is what can still be refunded.
  case exceedsOriginal(remainingMinor: Int64, currency: Currency)
  /// The refund is in another currency than the original and no rate is known for its date.
  case rateUnavailable
}

/// An expense a refund may be linked to, with how much of it is still open.
public struct RefundCandidate: Hashable, Identifiable, Sendable {
  public var txn: Txn
  /// The expense's currency.
  public var currency: Currency
  /// The linked refunds so far, in the expense's currency.
  public var refundedMinor: Int64
  /// Higher is a better match (same description, same amount, same currency, same account).
  public var score: Int
  public var id: Txn.ID { txn.id }
  public var remainingMinor: Int64 { max(0, txn.amountMinor - refundedMinor) }

  public init(txn: Txn, currency: Currency, refundedMinor: Int64, score: Int) {
    self.txn = txn
    self.currency = currency
    self.refundedMinor = refundedMinor
    self.score = score
  }
}

/// An incoming transaction (income, or an expense marked as refund) that may become the refund of
/// an expense.
public struct RefundTargetCandidate: Hashable, Identifiable, Sendable {
  public var txn: Txn
  public var currency: Currency
  public var score: Int
  public var id: Txn.ID { txn.id }

  public init(txn: Txn, currency: Currency, score: Int) {
    self.txn = txn
    self.currency = currency
    self.score = score
  }
}

/// What the list shows about refund links for a set of transactions (two aggregate reads, no
/// per-row queries).
public struct RefundLinkSummary: Hashable, Sendable {
  /// A linked refund of an expense on the page.
  public struct Refund: Hashable, Sendable {
    public var refundID: Txn.ID
    public var amountMinor: Int64
    public var currency: Currency
    public var occurredAt: Date

    public init(refundID: Txn.ID, amountMinor: Int64, currency: Currency, occurredAt: Date) {
      self.refundID = refundID
      self.amountMinor = amountMinor
      self.currency = currency
      self.occurredAt = occurredAt
    }
  }
  /// The original of a refund on the page.
  public struct Original: Hashable, Sendable {
    public var originalID: Txn.ID
    public var payee: String
    public var occurredAt: Date
    public var amountMinor: Int64
    public var currency: Currency

    public init(originalID: Txn.ID, payee: String, occurredAt: Date, amountMinor: Int64, currency: Currency) {
      self.originalID = originalID
      self.payee = payee
      self.occurredAt = occurredAt
      self.amountMinor = amountMinor
      self.currency = currency
    }
  }

  /// Original expense id → its linked refunds.
  public var refundsByOriginal: [Txn.ID: [Refund]]
  /// Refund id → its original.
  public var originalByRefund: [Txn.ID: Original]

  public init(refundsByOriginal: [Txn.ID: [Refund]] = [:], originalByRefund: [Txn.ID: Original] = [:]) {
    self.refundsByOriginal = refundsByOriginal
    self.originalByRefund = originalByRefund
  }
}

/// Links a refund to the expense it returns money for (R-TX-4, C30).
public protocol RefundRepository: Sendable {
  /// Links `refund` to `original`. An income becomes an expense marked as refund in the
  /// original's category; an expense refund takes the original's category too. Throws
  /// `notRefundable`, `invalidOriginal`, `exceedsOriginal` (the sum of linked refunds converted to
  /// the original's currency at each refund's date may not exceed its amount) or `rateUnavailable`.
  /// Re-linking moves the refund to the new original.
  func linkRefund(_ refund: Txn.ID, to original: Txn.ID) async throws
  /// The refund stays an expense refund with its category, unlinked (R-SET-3 applies again).
  func unlinkRefund(_ refund: Txn.ID) async throws
  /// Expenses `refund` may return, best first: same description, same amount, date within 60
  /// days before the refund, same currency first; fully refunded ones are left out. A non-empty
  /// `search` (description or note) drops the 60-day window and filters by text.
  func refundCandidates(for refund: Txn.ID, matching search: String, limit: Int) async throws -> [RefundCandidate]
  /// Incoming transactions on the original's account that may be its refund (income not yet
  /// refunding anything, or an unlinked expense refund), amount not above what remains, equal
  /// amounts first.
  func refundTargets(for original: Txn.ID, matching search: String, limit: Int) async throws -> [RefundTargetCandidate]
  /// Refund links of the transactions in `ids`.
  func refundLinks(for ids: [Txn.ID]) async throws -> RefundLinkSummary
}

extension RefundRepository {
  public func refundCandidates(for refund: Txn.ID, limit: Int) async throws -> [RefundCandidate] {
    try await refundCandidates(for: refund, matching: "", limit: limit)
  }

  public func refundTargets(for original: Txn.ID, limit: Int) async throws -> [RefundTargetCandidate] {
    try await refundTargets(for: original, matching: "", limit: limit)
  }
}
