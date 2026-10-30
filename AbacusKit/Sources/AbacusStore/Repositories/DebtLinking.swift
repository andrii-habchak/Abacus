import AbacusDomain
import Foundation
import SQLiteData

/// Turns an existing transaction into a debt record's leg (R-DEBT-9…12; docs/status/C17.md),
/// inside the caller's database transaction: the import commit (row action, rules), "Update
/// existing transactions" of a debt rule and "Convert to debt record" in the list all end here.
public enum DebtLinking {
  /// Converts `txnID`. The record gets the transaction's day, note and import batch; the
  /// transaction keeps its id, date, description, event, attached records, fingerprints and
  /// batch and becomes the leg as C14's `leg()` shapes it (unflagged: a one-sided transfer,
  /// `isRefund` = money in; flagged: an expense/income in "Debts").
  @discardableResult
  public static func convert(_ txnID: Txn.ID, to link: DebtLink, calendar: Calendar, _ db: Database) throws -> DebtRecord {
    guard var txn = try Txn.find(txnID).fetchOne(db) else { throw RepositoryError.notFound }
    guard txn.debtRecordID == nil, txn.type != .transfer else { throw DebtRepositoryError.notLinkable }
    let inflow = (txn.type == .income) != txn.isRefund
    let personName = link.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !personName.isEmpty, let account = try Account.find(txn.accountID).fetchOne(db) else {
      throw DebtRepositoryError.notLinkable
    }

    // The debt: the given one, else the person's debt in the currency (an unsettled one first),
    // else a new one that undo of the transaction's import removes again.
    var debt: Debt
    if let id = link.debtID {
      guard let found = try Debt.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      debt = found
    } else {
      let key = Debt.personKey(personName)
      let currency = link.currency
      let same = try Debt.where { $0.currency.eq(currency) }.fetchAll(db).filter { $0.personKey == key }
        .sorted { ($0.isSettled ? 1 : 0, $0.createdAt) < ($1.isSettled ? 1 : 0, $1.createdAt) }
      if let found = same.first {
        debt = found
      } else {
        debt = Debt(personName: personName, currency: currency, importBatchID: txn.importBatchID)
        try Debt.insert { debt }.execute(db)
      }
    }
    if debt.isSettled {
      // A settled debt that gets money again is open again (else it hides in Settled).
      debt.isSettled = false
      try Debt.upsert { Debt.Draft(debt) }.execute(db)
    }

    let amount: Int64
    if let given = link.amountMinor {
      amount = given
    } else if debt.currency == account.currency {
      amount = txn.amountMinor
    } else if let original = txn.originalAmountMinor, txn.originalCurrencyCode == debt.currency.rawValue {
      amount = original
    } else {
      throw DebtRepositoryError.amountUnknown
    }
    guard amount >= 0 else { throw DebtRepositoryError.invalidLeg }

    let kind: DebtRecordKind
    if let given = link.kind {
      kind = given
    } else {
      let debtID = debt.id
      let balance = try DebtRecord.where { $0.debtID.eq(debtID) }.fetchAll(db).reduce(0) { $0 + $1.balanceEffect }
      kind = .suggested(inflow: inflow, balance: balance)
    }
    guard kind.movesMoney, kind.isInflow == inflow else { throw DebtRepositoryError.notLinkable }

    var record = DebtRecord(
      debtID: debt.id, kind: kind, day: Day(txn.occurredAt, calendar: calendar).string, amountMinor: amount,
      note: txn.note, importBatchID: txn.importBatchID)
    if link.countsInReports, let reportKind = kind.offeredReportKind {
      record.reportKind = reportKind
      record.categoryID = try SQLiteDebtRepository.debtsCategory(reportKind, db)
    }
    try DebtRecord.insert { record }.execute(db)

    // The leg in place, shaped like `SQLiteDebtRepository.leg` (description, original amount
    // and the rest of the transaction kept).
    let flagged: CategoryKind? =
      switch (record.reportKind, kind.isInflow) {
      case (.expense, false): .expense
      case (.income, true): .income
      default: nil
      }
    if let flagged {
      txn.type = flagged == .expense ? .expense : .income
      txn.categoryID = record.categoryID
      txn.isRefund = false
    } else {
      txn.type = .transfer
      txn.categoryID = nil
      txn.isRefund = inflow
    }
    txn.toAccountID = nil
    txn.toAmountMinor = nil
    txn.debtRecordID = record.id
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
    return record
  }

  /// R-DEBT-12 roll back: the leg goes back to `restored` (no longer a leg) and its record is
  /// deleted (in that order: deleting the record first would delete the transaction).
  static func unlink(_ restored: Txn, _ db: Database) throws {
    guard let current = try Txn.find(restored.id).fetchOne(db), let recordID = current.debtRecordID else { return }
    var plain = restored
    plain.debtRecordID = nil
    try Txn.upsert { Txn.Draft(plain) }.execute(db)
    try DebtRecord.find(recordID).delete().execute(db)
  }
}

extension SQLiteDebtRepository {
  @discardableResult
  public func convert(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtRecord {
    let calendar = self.calendar
    return try await database.write { db in try DebtLinking.convert(txnID, to: link, calendar: calendar, db) }
  }
}
