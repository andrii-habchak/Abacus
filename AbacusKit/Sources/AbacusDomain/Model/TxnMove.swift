import Foundation
import SQLiteData

/// C48: the trace of an import batch moved to another account (C44): where a transaction came
/// from and when. One row per moved transaction and move; shown as "Moved from <account> · <date>"
/// on the transaction (list badge and editor). Moving the transaction back to the account of its
/// latest trace row removes that row, so Undo move leaves no trace. Append-only table (v17):
/// single primary key; the transaction's rows go with it (CASCADE, so Undo import clears them);
/// the batch reference is SET NULL, the accounts are plain ids (no foreign keys, CloudKit rules).
@Table("txnMoves")
public struct TxnMove: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var txnID: Txn.ID
  public var batchID: ImportBatch.ID?
  public var fromAccountID: Account.ID
  public var toAccountID: Account.ID
  public var movedAt: Date

  public init(
    id: UUID = UUID(), txnID: Txn.ID, batchID: ImportBatch.ID? = nil, fromAccountID: Account.ID,
    toAccountID: Account.ID, movedAt: Date
  ) {
    self.id = id
    self.txnID = txnID
    self.batchID = batchID
    self.fromAccountID = fromAccountID
    self.toAccountID = toAccountID
    self.movedAt = movedAt
  }
}

/// Reads the move trace of transactions (the list and the editor).
public protocol TxnMoveReading: Sendable {
  /// The latest trace of each of `txnIDs` that has one.
  func moves(for txnIDs: [Txn.ID]) async throws -> [Txn.ID: TxnMove]
}
