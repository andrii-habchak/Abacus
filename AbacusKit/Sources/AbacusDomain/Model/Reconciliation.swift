import Foundation
import SQLiteData

extension Txn {
  /// N6: whether the side of this transaction on `accountID` is cleared (a transfer has two sides).
  public func isCleared(on accountID: Account.ID) -> Bool {
    if self.accountID == accountID { return isCleared }
    if toAccountID == accountID { return isToCleared }
    return false
  }

  /// N6: sets the cleared flag of the side on `accountID`; other accounts change nothing.
  public mutating func setCleared(_ value: Bool, on accountID: Account.ID) {
    if self.accountID == accountID {
      isCleared = value
    } else if toAccountID == accountID {
      isToCleared = value
    }
  }

  /// N6: clears both flags, for a pending hold (never cleared) or a copy.
  public var hasNoClearedSide: Bool { !isCleared && !isToCleared }
}

/// N6: one finished reconciliation of an account against a statement: the statement day, the
/// closing balance the owner typed (account currency, minor units) and the correction booked to
/// reach it (0 when none). Append-only table (v19): single primary key, deleted with its account
/// (CASCADE), no UNIQUE (CloudKit rules). Used to show "Reconciled to <day>" and to notice drift.
@Table("reconciliations")
public struct Reconciliation: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var accountID: Account.ID
  /// `YYYY-MM-DD`.
  public var statementDay: String
  public var closingMinor: Int64
  public var correctionMinor: Int64
  public var finishedAt: Date

  public init(
    id: UUID = UUID(), accountID: Account.ID, statementDay: String, closingMinor: Int64,
    correctionMinor: Int64 = 0, finishedAt: Date = Date()
  ) {
    self.id = id
    self.accountID = accountID
    self.statementDay = statementDay
    self.closingMinor = closingMinor
    self.correctionMinor = correctionMinor
    self.finishedAt = finishedAt
  }
}
