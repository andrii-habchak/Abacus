import Foundation
import SQLiteData

// C38: the other side of a transfer to an own account in another currency. The import cannot know
// what arrived on the other account, so it finds the transaction that was imported from the other
// account's statement ("Find the other side…"), takes a typed amount or estimates one at the day's
// rate. A transfer with an estimated amount is flagged (`Txn.isEstimatedTransferAmount`); a later
// import row that matches it completes it.


/// What an import changed on an existing transaction that undo must put back (C38): the
/// transaction as it was before the batch absorbed it as one side of a transfer, or completed its
/// estimated amount. `json` is the encoded `Txn`; undo of the batch restores it and deletes the row.
/// A table of its own (append-only, v16): single primary key, deleted with its batch.
@Table("importTxnSnapshots")
public struct ImportTxnSnapshot: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var batchID: ImportBatch.ID
  public var txnID: Txn.ID
  public var json: String

  public init(id: UUID = UUID(), batchID: ImportBatch.ID, txnID: Txn.ID, json: String) {
    self.id = id
    self.batchID = batchID
    self.txnID = txnID
    self.json = json
  }

  public init(batchID: ImportBatch.ID, txn: Txn) throws {
    let data = try JSONEncoder().encode(txn)
    self.init(batchID: batchID, txnID: txn.id, json: String(decoding: data, as: UTF8.self))
  }

  public func txn() throws -> Txn {
    try JSONDecoder().decode(Txn.self, from: Data(json.utf8))
  }
}

/// A transaction on the other account that may be the other side of an import row's transfer.
public struct TransferCounterpartCandidate: Hashable, Identifiable, Sendable {
  public var txn: Txn
  /// The currency of the account the candidate is on.
  public var currency: Currency
  /// Why the transaction cannot be absorbed ("It has attached records."); nil = it can.
  public var refusal: TransferAbsorbRefusal?
  public var id: Txn.ID { txn.id }

  public init(txn: Txn, currency: Currency, refusal: TransferAbsorbRefusal? = nil) {
    self.txn = txn
    self.currency = currency
    self.refusal = refusal
  }
}

/// Lookups the import's transfer-counterpart features need (C38). Implemented by the SQLite store;
/// the pipeline works without one (no search, no estimated transfers to complete).
public protocol TransferCounterpartRepository: Sendable {
  /// Transactions that touch `accountID` on `from…to` (inclusive days), with the reason each
  /// cannot be absorbed (`TransferCounterpartCandidate.refusal`). Direction is not filtered here.
  func counterpartCandidates(accountID: Account.ID, from: Day, to: Day) async throws -> [TransferCounterpartCandidate]
  /// Transfers flagged `isEstimatedTransferAmount` that touch `accountID` on `from…to`.
  func estimatedTransfers(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn]
}

/// Why a transaction cannot be absorbed as one side of a transfer. The wording is shown in the
/// "Find the other side…" sheet and by the commit when it refuses.
public enum TransferAbsorbRefusal: Hashable, Sendable {
  case alreadyTransfer, balanceCorrection, attachedRecords, refundLink, debt, archivedAccount, missing

  public var message: String {
    switch self {
    case .alreadyTransfer: "It is already a transfer."
    case .balanceCorrection: "It is a balance correction."
    case .attachedRecords: "It has attached records (fees, cashback or split lines)."
    case .refundLink: "It is linked to a refund."
    case .debt: "It is part of a debt."
    case .archivedAccount: "Its account is archived."
    case .missing: "It no longer exists."
    }
  }
}

public enum TransferCounterpartError: Error, Equatable, Sendable, LocalizedError {
  /// The transaction an import wanted to absorb cannot be absorbed any more.
  case cannotAbsorb(Txn.ID, TransferAbsorbRefusal)
  /// The estimated transfer an import row completes is gone or no longer estimated.
  case estimateGone(Txn.ID)

  public var errorDescription: String? {
    switch self {
    case .cannotAbsorb(_, let refusal): "A transaction chosen as the other side of a transfer can't be used. " + refusal.message
    case .estimateGone: "A transfer with an estimated amount that this import completes has changed since the preview."
    }
  }
}
