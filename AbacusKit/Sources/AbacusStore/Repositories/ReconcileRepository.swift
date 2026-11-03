import AbacusDomain
import Foundation
import SQLiteData

/// N6 (R-CLR): the cleared flag, mark-settled and finished reconciliations.
public struct SQLiteReconcileRepository: ReconcileRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar
  let now: @Sendable () -> Date

  public init(database: any DatabaseWriter, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
    self.database = database
    self.calendar = calendar
    self.now = now
  }

  public func lastReconciliations() async throws -> [Account.ID: Reconciliation] {
    try await database.read { db in
      var result: [Account.ID: Reconciliation] = [:]
      for item in try Reconciliation.order { ($0.statementDay, $0.finishedAt) }.fetchAll(db) {
        result[item.accountID] = item
      }
      return result
    }
  }

  public func setCleared(_ ids: [Txn.ID], _ cleared: Bool, on accountID: Account.ID) async throws {
    try await database.write { db in
      for id in ids {
        guard var txn = try Txn.find(id).fetchOne(db) else { continue }
        if txn.isPendingAtBank { continue }
        txn.setCleared(cleared, on: accountID)
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
    }
  }

  public func markSettled(_ ids: [Txn.ID]) async throws {
    try await database.write { db in
      for id in ids {
        guard var txn = try Txn.find(id).fetchOne(db), txn.isPendingAtBank else { continue }
        txn.isPendingAtBank = false
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
    }
  }

  public func finish(_ f: ReconcileFinish) async throws {
    let calendar = self.calendar
    let finishedAt = now()
    try await database.write { db in
      guard let account = try Account.find(f.accountID).fetchOne(db) else { throw RepositoryError.notFound }
      for id in f.deletions {
        guard let txn = try Txn.find(id).fetchOne(db) else { continue }
        // A bank-file row is never deleted from here.
        guard txn.source == .manual || txn.isPendingAtBank else { throw RepositoryError.notFound }
        try Txn.find(id).delete().execute(db)
      }
      for edit in f.edits where try Txn.find(edit.id).fetchCount(db) > 0 {
        try Txn.upsert { Txn.Draft(edit) }.execute(db)
      }
      for id in f.settleIDs {
        guard var txn = try Txn.find(id).fetchOne(db) else { continue }
        txn.isPendingAtBank = false
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
      for var added in f.additions {
        added.setCleared(true, on: f.accountID)
        try Txn.insert { added }.execute(db)
      }
      for id in f.clearIDs {
        guard var txn = try Txn.find(id).fetchOne(db), !txn.isPendingAtBank else { continue }
        txn.setCleared(true, on: f.accountID)
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
      if f.correctionMinor != 0 {
        // Same mechanism as D34 / R-ACC-4: income or expense flagged as a balance correction, not
        // counted in reports, cleared (it restates the bank balance).
        let correction = Txn(
          type: f.correctionMinor > 0 ? .income : .expense,
          occurredAt: f.statementDay.date(calendar: calendar), accountID: account.id,
          amountMinor: abs(f.correctionMinor), payee: "Balance correction",
          note: "Reconciliation to \(f.statementDay.string)", source: .manual, createdAt: finishedAt,
          isBalanceCorrection: true, isCleared: true)
        try Txn.insert { correction }.execute(db)
      }
      let record = Reconciliation(
        accountID: f.accountID, statementDay: f.statementDay.string, closingMinor: f.closingMinor,
        correctionMinor: f.correctionMinor, finishedAt: finishedAt)
      try Reconciliation.insert { record }.execute(db)
    }
  }
}
