import AbacusDomain
import Foundation

// C40: the transfer popup of the import review. A transfer row (made by the user, by a transfer
// rule, or given by the file) shows its From and To accounts, what made it a transfer, and lets
// the user change both accounts:
// - the statement side (the account the file belongs to) may move to another account in the same
//   currency (the row's amount is in that currency); `Decisions.ownAccounts`;
// - the other side may be any active own account: an expense/income turned transfer goes through
//   the usual "Transfer to my account" decision, a Needs review row through its review choice, a
//   transfer the file gives through `Decisions.counterAccounts`. When the amount on the new account
//   is unknown (another currency), the caller opens "Find the other side…" for it.

/// Which end of a transfer.
public enum ImportTransferEnd: Hashable, Sendable { case from, to }

/// What made a row a transfer, or what it is tied to (shown in the transfer popup).
public struct ImportTransferRelation: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// The row takes over an existing transaction of the other account (`txn`).
    case absorbs
    /// The amount on the other account was typed by the user (`amountMinor`).
    case typedAmount
    /// The amount on the other account is estimated at the day's rate (`amountMinor`).
    case estimatedAmount
    /// The row completes a transaction imported earlier from the other account (`txn`).
    case completesImported
    /// Two halves of this file were paired into this transfer.
    case pairedHalves
    /// Paired by the user with another row of this file (`rowID`).
    case pairedRow
    /// The other own account was recognised by its account number in the file.
    case accountNumber
    /// A transfer rule made it a transfer (`ruleLabel`).
    case rule
    /// The user chose the other account.
    case chosen
  }

  public var kind: Kind
  public var txn: Txn?
  public var rowID: String?
  public var amountMinor: Int64?
  public var ruleLabel: String?

  public init(kind: Kind, txn: Txn? = nil, rowID: String? = nil, amountMinor: Int64? = nil, ruleLabel: String? = nil) {
    self.kind = kind
    self.txn = txn
    self.rowID = rowID
    self.amountMinor = amountMinor
    self.ruleLabel = ruleLabel
  }
}

/// The two ends of a transfer row and what it is related to.
public struct ImportTransferSides: Hashable, Sendable {
  public var rowID: String
  public var from: AccountRef
  public var to: AccountRef
  /// The end the file's account is on (money out → from, money in → to).
  public var statementEnd: ImportTransferEnd
  /// The currency of the statement side (the row's amount).
  public var statementCurrency: Currency?
  public var day: Day
  public var relations: [ImportTransferRelation]

  public var statementAccount: AccountRef { statementEnd == .from ? from : to }
  public var otherAccount: AccountRef { statementEnd == .from ? to : from }
}

/// The result of changing a transfer's accounts.
public enum ImportTransferEditOutcome: Hashable, Sendable {
  case done
  /// The amount on this account is unknown: find the other side, type or estimate it (the
  /// statement side, when it changed, is already applied).
  case needsCounterpart(Account.ID)
  /// Nothing changed; the reason for the user.
  case refused(String)
}

extension ImportPreview {
  /// The account the row's statement side is on: the user's choice (C40) or the file's mapping.
  func statementAccount(of source: NormalizedRow) -> AccountRef {
    decisions.ownAccounts[source.id].map(AccountRef.existing) ?? accountRef(source.account)
  }

  private func parsedIndex(_ id: String) -> Int? { parsedRows.firstIndex { $0.id == id } }

  /// A transfer the file itself gives (Saldo transfer or paired halves, own account recognised by
  /// its number), not an expense/income turned into one.
  func fileGivesTransfer(_ id: String) -> Bool {
    guard let i = parsedIndex(id), i < analysis.count, row(id)?.review == nil else { return false }
    let source = parsedRows[i]
    return analysis[i].ownTransfer != nil || source.kind == .transfer || source.kind == .transferHalf
  }

  /// Whether the transfer popup can change the row: a transfer between own accounts that this
  /// import creates (or that takes over an existing transaction).
  public func canEditTransfer(row id: String) -> Bool {
    guard let row = row(id), row.type == .transfer, row.debt == nil, row.estimateLink == nil, row.counterAccount != nil,
      let i = parsedIndex(id), i < plans.count
    else { return false }
    switch plans[i] {
    case .create, .convert: return true
    case .nothing, .openingBalance, .settle, .link, .completeEstimate: return false
    }
  }

  /// The existing transaction the row itself turns into its transfer (taken over or completed).
  func convertedTxnID(forRow id: String) -> Txn.ID? {
    guard let i = parsedIndex(id), i < plans.count, case .convert(let txn, _) = plans[i] else { return nil }
    return txn.id
  }

  /// The From and To of a transfer row with what it is related to; nil for other rows.
  public func transferSides(forRow id: String) -> ImportTransferSides? {
    guard canEditTransfer(row: id), let row = row(id), let counter = row.counterAccount else { return nil }
    let statementEnd: ImportTransferEnd = row.isInflow ? .to : .from
    return ImportTransferSides(
      rowID: id, from: row.isInflow ? counter : row.account, to: row.isInflow ? row.account : counter,
      statementEnd: statementEnd, statementCurrency: currency(of: row.account),
      day: Day(row.source.occurredAt, calendar: calendar), relations: transferRelations(forRow: id))
  }

  /// What made the row a transfer and the transactions it is tied to.
  public func transferRelations(forRow id: String) -> [ImportTransferRelation] {
    guard let row = row(id), let i = parsedIndex(id), i < analysis.count else { return [] }
    let found = analysis[i]
    var result: [ImportTransferRelation] = []
    if let counterpart = row.counterpart {
      switch counterpart.kind {
      case .existing(let txn): result.append(ImportTransferRelation(kind: .absorbs, txn: row.absorbedTxn ?? txn))
      case .manual: result.append(ImportTransferRelation(kind: .typedAmount, amountMinor: counterpart.amountMinor))
      case .estimated: result.append(ImportTransferRelation(kind: .estimatedAmount, amountMinor: counterpart.amountMinor))
      }
    }
    if i < plans.count, case .convert(let txn, _) = plans[i], row.absorbedTxn == nil {
      result.append(ImportTransferRelation(kind: .completesImported, txn: txn))
    }
    if case .pair(let other)? = row.review?.choice {
      result.append(ImportTransferRelation(kind: .pairedRow, rowID: other))
    }
    let source = parsedRows[i]
    if row.review == nil, source.kind == .transfer, source.fingerprints.count == 2 {
      result.append(ImportTransferRelation(kind: .pairedHalves))
    }
    let chosen = decisions.counterAccounts[id] != nil || decisions.transfers[id] != nil
      || { if case .transfer? = row.review?.choice { return true } else { return false } }()
    if found.ownTransfer != nil, decisions.counterAccounts[id] == nil {
      result.append(ImportTransferRelation(kind: .accountNumber))
    }
    if i < plans.count, !chosen, case .create(let shape) = plans[i], let ruleID = shape.ruleID,
      let rule = context.rules.first(where: { $0.id == ruleID })
    {
      result.append(ImportTransferRelation(kind: .rule, ruleLabel: rule.label))
    }
    if chosen { result.append(ImportTransferRelation(kind: .chosen)) }
    return result
  }

  /// Accounts the statement side may move to: active, existing, in the statement's currency.
  public func statementAccountOptions(forRow id: String) -> [Account] {
    guard let row = row(id), let own = currency(of: row.account) else { return [] }
    return context.accounts.filter { !$0.isArchived && $0.currency == own }
  }

  /// Accounts the other side may be: every active account except the statement side's.
  public func otherAccountOptions(forRow id: String) -> [Account] {
    guard let row = row(id) else { return [] }
    return context.accounts.filter { !$0.isArchived && row.account != .existing($0.id) }
  }

  /// Changes the From and To of a transfer row. The statement side must stay in its currency;
  /// the other side may be any active own account. Returns `.needsCounterpart` when the amount on
  /// the new other account is unknown (the statement side is applied already).
  @discardableResult
  public mutating func setTransferAccounts(from: Account.ID, to: Account.ID, forRow id: String) -> ImportTransferEditOutcome {
    guard let sides = transferSides(forRow: id), let row = row(id), let i = parsedIndex(id) else {
      return .refused("This row is not a transfer that can be changed.")
    }
    guard from != to else { return .refused("From and To must be different accounts.") }
    let newStatement = sides.statementEnd == .from ? from : to
    let newOther = sides.statementEnd == .from ? to : from
    for accountID in [from, to] {
      guard let account = context.account(accountID) else { return .refused("That account no longer exists.") }
      if account.isArchived, AccountRef.existing(accountID) != sides.from, AccountRef.existing(accountID) != sides.to {
        return .refused("“\(account.name)” is archived.")
      }
    }
    let statementChanged = sides.statementAccount != .existing(newStatement)
    let otherChanged = sides.otherAccount != .existing(newOther)
    guard statementChanged || otherChanged else { return .done }

    if statementChanged {
      guard let account = context.account(newStatement), account.currency == sides.statementCurrency else {
        let code = sides.statementCurrency?.rawValue ?? "the statement's currency"
        return .refused("The \(sides.statementEnd == .from ? "From" : "To") account must be in \(code), like this statement.")
      }
    }
    let before = self
    if statementChanged {
      let fileAccount = accountRef(parsedRows[i].account)
      decisions.ownAccounts[id] = fileAccount == .existing(newStatement) ? nil : newStatement
    }
    var outcome = ImportTransferEditOutcome.done
    if otherChanged {
      outcome = changeOtherAccount(to: newOther, forRow: id, statementAccount: .existing(newStatement), source: row.source)
    }
    if case .refused = outcome {
      self = before
      return outcome
    }
    recompute()
    return outcome
  }

  /// The other side becomes `accountID`; no recompute (the caller does it).
  private mutating func changeOtherAccount(
    to accountID: Account.ID, forRow id: String, statementAccount: AccountRef, source: NormalizedRow
  ) -> ImportTransferEditOutcome {
    guard let other = context.account(accountID), statementAccount != .existing(accountID) else {
      return .refused("From and To must be different accounts.")
    }
    let ownCurrency = currency(of: statementAccount)
    var known = other.currency == ownCurrency || Self.knownAmount(of: source, in: other.currency, accountCurrency: ownCurrency) != nil
    if fileGivesTransfer(id), let counter = row(id)?.counterAccount, currency(of: counter) == other.currency { known = true }
    if decisions.counterparts[id]?.accountID == accountID { known = true }
    if row(id)?.review != nil {
      if known {
        if decisions.counterparts[id]?.accountID != accountID { decisions.counterparts[id] = nil }
        applyReviewChoice(.transfer(accountID: accountID), forRow: id)
        return .done
      }
      return .needsCounterpart(accountID)
    }
    guard known else { return .needsCounterpart(accountID) }
    if decisions.counterparts[id]?.accountID != accountID { decisions.counterparts[id] = nil }
    if fileGivesTransfer(id) {
      decisions.counterAccounts[id] = accountID
    } else {
      decisions.transfers[id] = accountID
      decisions.categories[id] = nil
      decisions.debts[id] = nil
    }
    return .done
  }
}
