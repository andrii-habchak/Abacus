import AbacusDomain
import Foundation
import SQLiteData

/// C38: the existing transactions an import row may be the other side of (`counterpartCandidates`),
/// the estimated transfers a later row may complete (`estimatedTransfers`), and the rules for
/// absorbing a transaction into a transfer, shared with the import commit.
public struct SQLiteTransferCounterpartRepository: TransferCounterpartRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  public func counterpartCandidates(accountID: Account.ID, from: Day, to: Day) async throws -> [TransferCounterpartCandidate] {
    let bounds = DayBounds(calendar: calendar)
    let start = bounds.start(from)
    let end = bounds.end(to)
    return try await database.read { db in
      guard let account = try Account.find(accountID).fetchOne(db) else { return [] }
      let txns = try Txn
        .where {
          $0.occurredAt >= start && $0.occurredAt < end && ($0.accountID.eq(accountID) || $0.toAccountID.eq(accountID))
            && !$0.isBalanceCorrection
        }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(db)
      return try txns.map { txn in
        TransferCounterpartCandidate(
          txn: txn, currency: account.currency, refusal: try TransferAbsorb.refusal(for: txn, db))
      }
    }
  }

  public func estimatedTransfers(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn] {
    let bounds = DayBounds(calendar: calendar)
    let start = bounds.start(from)
    let end = bounds.end(to)
    return try await database.read { db in
      try Txn
        .where {
          $0.occurredAt >= start && $0.occurredAt < end && $0.isEstimatedTransferAmount
            && ($0.accountID.eq(accountID) || $0.toAccountID.eq(accountID))
        }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(db)
    }
  }
}

/// Whether an existing transaction can be absorbed as one side of a transfer (C38): an income or
/// expense of an active account without attached records, refund link or debt.
enum TransferAbsorb {
  static func refusal(for txn: Txn, _ db: Database) throws -> TransferAbsorbRefusal? {
    if txn.type == .transfer { return .alreadyTransfer }
    if txn.isBalanceCorrection { return .balanceCorrection }
    if txn.debtRecordID != nil { return .debt }
    if txn.refundOfID != nil { return .refundLink }
    let id = txn.id
    if try AttachedRecord.where({ $0.txnID.eq(id) }).fetchCount(db) > 0 { return .attachedRecords }
    if try Txn.where({ $0.refundOfID.eq(id) }).fetchCount(db) > 0 { return .refundLink }
    let accountID = txn.accountID
    if try DebtAccountLink.where({ $0.accountID.eq(accountID) }).fetchCount(db) > 0 { return .debt }
    if let account = try Account.find(accountID).fetchOne(db), account.isArchived { return .archivedAccount }
    return nil
  }

  /// Checks what the commit absorbs or completes and keeps each transaction as it is now, so undo of
  /// the batch restores it (see `ImportTxnSnapshot`).
  static func keepOriginals(of commit: ImportCommit, batchID: ImportBatch.ID, _ db: Database) throws {
    for original in commit.absorbedOriginals {
      guard let current = try Txn.find(original.id).fetchOne(db) else {
        throw TransferCounterpartError.cannotAbsorb(original.id, .missing)
      }
      if let refusal = try refusal(for: current, db) {
        throw TransferCounterpartError.cannotAbsorb(original.id, refusal)
      }
      let snapshot = try ImportTxnSnapshot(batchID: batchID, txn: current)
      try ImportTxnSnapshot.insert { snapshot }.execute(db)
    }
    for original in commit.completedOriginals {
      guard let current = try Txn.find(original.id).fetchOne(db), current.type == .transfer,
        current.isEstimatedTransferAmount
      else { throw TransferCounterpartError.estimateGone(original.id) }
      let snapshot = try ImportTxnSnapshot(batchID: batchID, txn: current)
      try ImportTxnSnapshot.insert { snapshot }.execute(db)
    }
  }
}
