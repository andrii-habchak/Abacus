import Foundation

public enum DebtRepositoryError: Error, Equatable, Sendable {
  /// R-DEBT-16: another debt already has this person (the id of that debt).
  case personExists(Debt.ID)
  /// R-DEBT-17: the account already belongs to a debt (the id of that debt).
  case accountLinkedElsewhere(Debt.ID)
  /// A record needs a positive-or-zero amount and a valid day.
  case invalidRecord
  /// Only an expense or income that is not yet a transfer can be turned into a transfer to a
  /// debt account (R-DEBT-19), and its own account must not belong to a debt.
  case notLinkable
  /// The person's account is in another currency than the transaction's and no amount in it was
  /// given or known (the transaction's original amount).
  case amountUnknown
  /// The target account is not a linked account of the debt.
  case notDebtAccount
  /// The transaction is not a transfer between an own account and a debt account.
  case notDebtTransfer
}

/// Where a payment of mine goes (R-DEBT-19): the person's debt and the account of theirs that
/// takes it. Input of `DebtRepository.transferToDebt`, of the import row action, rules and
/// "Transfer to debt account…".
public struct DebtLink: Hashable, Sendable {
  /// The person; used when `debtID` is nil. A missing debt is created.
  public var personName: String
  /// The debt (wins over `personName`); nil = the person's debt by name.
  public var debtID: Debt.ID?
  /// The debt's linked account that takes or gives the money; nil = the debt's **virtual**
  /// account in `currency` (created when there is none, R-DEBT-17).
  public var accountID: Account.ID?
  /// The currency of the virtual account to find or create (used when `accountID` is nil);
  /// the transaction's account currency when nil.
  public var currency: Currency?
  /// The amount on the person's side, in that account's currency; nil = the transaction's amount
  /// (same currency), else the transaction's original amount when it is in that currency.
  public var amountMinor: Int64?

  public init(
    personName: String, debtID: Debt.ID? = nil, accountID: Account.ID? = nil, currency: Currency? = nil,
    amountMinor: Int64? = nil
  ) {
    self.personName = personName
    self.debtID = debtID
    self.accountID = accountID
    self.currency = currency
    self.amountMinor = amountMinor
  }
}

/// What `transferToDebt` did.
public struct DebtTransferResult: Hashable, Sendable {
  public let txnID: Txn.ID
  public let debtID: Debt.ID
  /// The person's account on the other side of the transfer.
  public let accountID: Account.ID
  /// The debt was created by this call.
  public let createdDebt: Bool
  /// The virtual account was created by this call.
  public let createdAccount: Bool

  public init(txnID: Txn.ID, debtID: Debt.ID, accountID: Account.ID, createdDebt: Bool, createdAccount: Bool) {
    self.txnID = txnID
    self.debtID = debtID
    self.accountID = accountID
    self.createdDebt = createdDebt
    self.createdAccount = createdAccount
  }
}

/// A transaction an import commit turns into a transfer to a debt account right after
/// inserting it.
public struct ImportDebtLink: Hashable, Sendable {
  public var txnID: Txn.ID
  public var link: DebtLink

  public init(txnID: Txn.ID, link: DebtLink) {
    self.txnID = txnID
    self.link = link
  }
}

/// Debts, their linked accounts and manual records (R-DEBT-16…20, docs/status/C19.md).
///
/// A payment is **not** a record: it is a transaction on a linked account (R-DEBT-18, R-DEBT-19).
/// Records are manual only (forgive, adjustments).
public protocol DebtRepository: Sendable {
  /// Every debt with its links, linked accounts, their transactions and manual records.
  func book() async throws -> DebtBook

  /// Inserts or updates (create, edit, rename: R-DEBT-16). Throws `personExists` when another
  /// debt already has this person (key match).
  func save(_ debt: Debt) async throws
  /// Deletes the debt, its manual records and its links. Its accounts and their transactions stay
  /// (they are ordinary accounts again), so no balance of mine changes.
  func delete(_ id: Debt.ID) async throws

  /// Inserts or updates a manual record. A flagged record (`reportKind`) without a category gets
  /// the "Debts" category of that kind (found or created).
  func save(_ record: DebtRecord) async throws
  func deleteRecord(_ id: DebtRecord.ID) async throws

  /// R-DEBT-17: links an existing account to the debt. Throws `accountLinkedElsewhere` when it
  /// belongs to another debt; linking it again to the same debt only updates the role.
  func link(_ accountID: Account.ID, to debtID: Debt.ID, role: DebtAccountRole) async throws
  /// Removes the link; the account and its transactions stay. No-op for an account without link.
  func unlink(_ accountID: Account.ID) async throws
  /// R-DEBT-17: a new `.debt`-kind account in `currency`, linked as `virtual`. `name` nil =
  /// "<person> (<CCY>)"; the opening balance is that account's own (R-DEBT-18).
  @discardableResult
  func createVirtualAccount(
    for debtID: Debt.ID, currency: Currency, name: String?, openingBalanceMinor: Int64
  ) async throws -> Account

  /// R-DEBT-19: turns an expense/income on my own account into a transfer between it and the
  /// person's account, **in place** (same id, date, description, event, attached records,
  /// fingerprints, import batch): money out → my account to theirs (they owe me more), money in →
  /// theirs to mine. Missing debt/virtual account are created.
  @discardableResult
  func transferToDebt(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtTransferResult
  /// The reverse: the transfer becomes an expense (money out) or income (money in) on my account
  /// again, without category.
  func unlinkTransfer(_ txnID: Txn.ID) async throws

  /// R-DEBT-16: person names for autocomplete, prefix matches first (every name for blank text).
  func personNames(matching text: String) async throws -> [String]
}

extension DebtRepository {
  /// Fakes without transfers.
  @discardableResult
  public func transferToDebt(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtTransferResult {
    throw DebtRepositoryError.notLinkable
  }

  public func unlinkTransfer(_ txnID: Txn.ID) async throws { throw DebtRepositoryError.notDebtTransfer }

  public func personNames(matching text: String) async throws -> [String] {
    try await book().personNames(matching: text)
  }

  @discardableResult
  public func createVirtualAccount(for debtID: Debt.ID, currency: Currency) async throws -> Account {
    try await createVirtualAccount(for: debtID, currency: currency, name: nil, openingBalanceMinor: 0)
  }
}
