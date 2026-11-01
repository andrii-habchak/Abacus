import Foundation

// MARK: - Moving an import batch to another account (C44)

extension ImportFingerprint {
  /// Prefix of a PKO fingerprint whose transaction was moved to another account by "Move to
  /// another account…" (C44).
  public static let movedPrefix = "moved:"

  /// The key a PKO fingerprint gets when its transaction is moved: the PKO key includes the
  /// account it was imported into, so after a move it would no longer match a re-import into the
  /// new account, and would block a fresh import into the old one. The moved key keeps the
  /// original key (ASCII, < 255 characters), is free of the old account's slot, and is found again
  /// by recomputing the file's keys for each account of its currency (`ImportPipeline`): it counts
  /// as "already imported" only for the account the transaction is on now. Keys that are not
  /// PKO keys (Saldo ids name no account) and keys already moved stay as they are.
  public static func movedID(_ id: String) -> String {
    id.hasPrefix("pko:") ? movedPrefix + id : id
  }
}

/// A stored fingerprint with the transaction it belongs to and the accounts that transaction is on
/// now (both sides of a transfer).
public struct FingerprintOwner: Hashable, Sendable {
  public var txnID: Txn.ID
  public var accountIDs: Set<Account.ID>

  public init(txnID: Txn.ID, accountIDs: Set<Account.ID>) {
    self.txnID = txnID
    self.accountIDs = accountIDs
  }
}

/// Why a transaction of the batch cannot move with it (C44).
public enum ImportMoveRefusal: Hashable, Sendable {
  /// Not the batch's own: a transaction that existed before the import, which the import linked
  /// to or settled (a pending payment). It stays where it is.
  case notOwn
  /// No longer on the account the batch is moved from (its account was changed after the import,
  /// or it was moved before).
  case notOnSource(accountIDs: [Account.ID])
  /// A debt record's leg, or a transfer to a debt account (R-DEBT-3/10).
  case debt
  /// A later import matched it too (linked a row to it, settled it, made it one side of a
  /// transfer, C38): moving it would leave that import's link on the wrong account.
  case laterImport(fileName: String?)
  /// A transfer whose other side is the target account itself.
  case transferToTarget
}

/// Something worth saying about a transaction that does move (C44).
public enum ImportMoveNote: Hashable, Sendable {
  /// A transfer: only the side on the source account moves; the other side stays.
  case transfer(otherAccountID: Account.ID)
  /// A refund linked to an expense, or an expense with linked refunds: the link is kept.
  case refundLink
  /// A pending payment (hold) not yet settled: a later statement settles it on the new account.
  case pending
}

/// One transaction of a batch in the "Move to another account" list (C44).
public struct ImportMoveCandidate: Identifiable, Hashable, Sendable {
  public var txn: Txn
  /// Nil when the transaction can move (to any account but the other side of its transfer).
  public var refusal: ImportMoveRefusal?
  public var notes: [ImportMoveNote]
  /// Category name (or the attached records' summary) for the list.
  public var categoryName: String?

  public var id: Txn.ID { txn.id }

  public init(txn: Txn, refusal: ImportMoveRefusal? = nil, notes: [ImportMoveNote] = [], categoryName: String? = nil) {
    self.txn = txn
    self.refusal = refusal
    self.notes = notes
    self.categoryName = categoryName
  }

  /// The other side of a transfer (not on the source account).
  public var otherAccountID: Account.ID? {
    for note in notes { if case .transfer(let id) = note { return id } }
    return nil
  }

  /// Whether it can move to `target` (a transfer cannot move onto its own other side).
  public func refusal(movingTo target: Account.ID?) -> ImportMoveRefusal? {
    if let refusal { return refusal }
    if let target, otherAccountID == target { return .transferToTarget }
    return nil
  }
}

/// What "Move to another account" offers for a batch (C44): the account its rows are on and every
/// transaction it created or touched.
public struct ImportMovePlan: Hashable, Sendable {
  public var batch: ImportBatch
  /// The account the batch's statement went into (PKO).
  public var sourceAccountID: Account.ID
  public var candidates: [ImportMoveCandidate]

  public init(batch: ImportBatch, sourceAccountID: Account.ID, candidates: [ImportMoveCandidate]) {
    self.batch = batch
    self.sourceAccountID = sourceAccountID
    self.candidates = candidates
  }
}

/// What a move did; moving `txnIDs` back from `to` to `from` undoes it.
public struct ImportMoveResult: Hashable, Sendable {
  public var batchID: ImportBatch.ID
  public var from: Account.ID
  public var to: Account.ID
  public var txnIDs: [Txn.ID]
  /// The batch now belongs to `to` (nothing of its own is left on `from`).
  public var batchMoved: Bool

  public init(batchID: ImportBatch.ID, from: Account.ID, to: Account.ID, txnIDs: [Txn.ID], batchMoved: Bool) {
    self.batchID = batchID
    self.from = from
    self.to = to
    self.txnIDs = txnIDs
    self.batchMoved = batchMoved
  }
}

public enum ImportMoveError: Error, Equatable, Sendable {
  /// Only a PKO statement's batch that is not undone can be moved.
  case notMovable
  /// The target is missing, archived, a debt account, the source itself, or in another currency.
  case invalidTarget
  /// Nothing selected.
  case nothingToMove
  /// Some selected transactions can no longer move (changed since the list was shown).
  case refused(count: Int)
  /// A selected row is already imported into the target account (a moved copy is there).
  case alreadyInTarget(count: Int)
}
