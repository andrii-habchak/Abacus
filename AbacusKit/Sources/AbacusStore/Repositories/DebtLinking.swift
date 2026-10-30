import AbacusDomain
import Foundation
import SQLiteData

/// Turns an expense/income on one of my accounts into a transfer to a person's account
/// (R-DEBT-19; docs/status/C19.md), inside the caller's database transaction: the import commit
/// (row action, rules), "Update existing transactions" of a debt rule and "Transfer to debt
/// account…" in the list all end here. Replaces C17's record-leg conversion.
public enum DebtLinking {
  /// Converts `txnID` **in place**: same id, date, description, event, original amount,
  /// fingerprints and import batch. Money out → `account` = mine, `toAccount` = the person's
  /// (they owe me more); money in → `account` = the person's, `toAccount` = mine. The debt is the
  /// given one, else the person's by name, else a new one; the person's account is the given
  /// linked account, else the debt's virtual account in `link.currency` (default: my account's
  /// currency), created when missing. New debts and accounts carry the transaction's import
  /// batch, so undoing that import removes them again when they are empty.
  ///
  /// Throws `notLinkable` for transfers and for transactions on an account that belongs to a
  /// debt itself, `amountUnknown` across currencies without an amount, `notDebtAccount` when the
  /// given account is not linked to the debt.
  @discardableResult
  public static func transfer(_ txnID: Txn.ID, to link: DebtLink, _ db: Database) throws -> DebtTransferResult {
    guard var txn = try Txn.find(txnID).fetchOne(db) else { throw RepositoryError.notFound }
    guard txn.type != .transfer else { throw DebtRepositoryError.notLinkable }
    guard let own = try Account.find(txn.accountID).fetchOne(db),
      try DebtAccountLink.find(own.id).fetchCount(db) == 0
    else { throw DebtRepositoryError.notLinkable }
    let inflow = (txn.type == .income) != txn.isRefund

    // The debt: the given one, else the person's (an unsettled one first), else a new one.
    var debt: Debt
    var createdDebt = false
    if let id = link.debtID {
      guard let found = try Debt.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      debt = found
    } else {
      let name = link.personName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw DebtRepositoryError.notLinkable }
      let key = Debt.personKey(name)
      let same = try Debt.fetchAll(db).filter { $0.personKey == key }
        .sorted { ($0.isSettled ? 1 : 0, $0.createdAt) < ($1.isSettled ? 1 : 0, $1.createdAt) }
      if let found = same.first {
        debt = found
      } else {
        debt = Debt(personName: name, importBatchID: txn.importBatchID)
        try Debt.insert { debt }.execute(db)
        createdDebt = true
      }
    }
    if debt.isSettled {
      // A settled debt that gets money again is open again (else it hides in Settled).
      debt.isSettled = false
      try Debt.upsert { Debt.Draft(debt) }.execute(db)
    }

    // The person's account.
    var theirs: Account
    var createdAccount = false
    if let accountID = link.accountID {
      guard let found = try Account.find(accountID).fetchOne(db),
        try DebtAccountLink.find(accountID).fetchOne(db)?.debtID == debt.id
      else { throw DebtRepositoryError.notDebtAccount }
      theirs = found
    } else {
      let currency = link.currency ?? own.currency
      let debtID = debt.id
      let links = try DebtAccountLink.where { $0.debtID.eq(debtID) && $0.role.eq(DebtAccountRole.virtual) }
        .order { ($0.createdAt, $0.accountID) }.fetchAll(db)
      var match: Account?
      for item in links {
        if let account = try Account.find(item.accountID).fetchOne(db), account.currency == currency {
          match = account
          break
        }
      }
      if let match {
        theirs = match
      } else {
        theirs = try SQLiteDebtRepository.createVirtualAccount(
          for: debt.id, currency: currency, name: nil, importBatchID: txn.importBatchID, db)
        createdAccount = true
      }
    }
    if theirs.isArchived {
      theirs.isArchived = false
      try Account.upsert { Account.Draft(theirs) }.execute(db)
    }

    // The amount on the person's side.
    let their: Int64
    if let given = link.amountMinor {
      their = given
    } else if theirs.currency == own.currency {
      their = txn.amountMinor
    } else if let original = txn.originalAmountMinor, txn.originalCurrencyCode == theirs.currency.rawValue {
      their = original
    } else {
      throw DebtRepositoryError.amountUnknown
    }
    guard their >= 0 else { throw DebtRepositoryError.invalidRecord }
    let same = theirs.currency == own.currency && their == txn.amountMinor

    if inflow {
      // Attached records hit the source account, which is the person's now: they become
      // transactions of their own on my account.
      let id = txn.id
      let lines = try AttachedRecord.where { $0.txnID.eq(id) }.order { ($0.position, $0.id) }.fetchAll(db)
      for line in lines {
        let split = Txn(
          type: line.kind == .expense ? .expense : .income, occurredAt: txn.occurredAt, accountID: own.id,
          amountMinor: line.amountMinor, categoryID: line.categoryID, originalAmountMinor: line.originalAmountMinor,
          originalCurrencyCode: line.originalCurrencyCode, payee: txn.payee, note: line.note, eventID: txn.eventID,
          source: txn.source, importBatchID: txn.importBatchID)
        try Txn.insert { split }.execute(db)
      }
      if !lines.isEmpty { try AttachedRecord.where { $0.txnID.eq(id) }.delete().execute(db) }
      txn.toAmountMinor = same ? nil : txn.amountMinor
      txn.accountID = theirs.id
      txn.toAccountID = own.id
      txn.amountMinor = their
    } else {
      txn.toAccountID = theirs.id
      txn.toAmountMinor = same ? nil : their
    }
    txn.type = .transfer
    txn.categoryID = nil
    txn.isRefund = false
    txn.refundOfID = nil
    txn.debtRecordID = nil
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
    try RefundLinks.repair(db)
    return DebtTransferResult(
      txnID: txn.id, debtID: debt.id, accountID: theirs.id, createdDebt: createdDebt, createdAccount: createdAccount)
  }

  /// The reverse of `transfer`: an expense (money out) or income (money in) on my account again,
  /// without category. Throws `notDebtTransfer` unless exactly one side is a linked account.
  public static func unlinkTransfer(_ txnID: Txn.ID, _ db: Database) throws {
    guard var txn = try Txn.find(txnID).fetchOne(db) else { throw RepositoryError.notFound }
    guard txn.type == .transfer, let to = txn.toAccountID else { throw DebtRepositoryError.notDebtTransfer }
    let sourceLinked = try DebtAccountLink.find(txn.accountID).fetchCount(db) > 0
    let targetLinked = try DebtAccountLink.find(to).fetchCount(db) > 0
    guard sourceLinked != targetLinked else { throw DebtRepositoryError.notDebtTransfer }
    if targetLinked {
      txn.type = .expense
    } else {
      txn.amountMinor = txn.toAmountMinor ?? txn.amountMinor
      txn.accountID = to
      txn.type = .income
    }
    txn.toAccountID = nil
    txn.toAmountMinor = nil
    txn.categoryID = nil
    txn.isRefund = false
    txn.refundOfID = nil
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
    try RefundLinks.repair(db)
  }
}

extension SQLiteDebtRepository {
  @discardableResult
  public func transferToDebt(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtTransferResult {
    try await database.write { db in try DebtLinking.transfer(txnID, to: link, db) }
  }

  public func unlinkTransfer(_ txnID: Txn.ID) async throws {
    try await database.write { db in try DebtLinking.unlinkTransfer(txnID, db) }
  }
}
