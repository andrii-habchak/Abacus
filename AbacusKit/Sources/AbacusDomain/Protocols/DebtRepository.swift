import Foundation

/// The money a debt record moves on my account (R-DEBT-3): the account and the amount in the
/// account's currency (equal to the record's amount when the currencies match).
public struct DebtLegInput: Hashable, Sendable {
  public var accountID: Account.ID
  public var amountMinor: Int64

  public init(accountID: Account.ID, amountMinor: Int64) {
    self.accountID = accountID
    self.amountMinor = amountMinor
  }
}

public enum DebtRepositoryError: Error, Equatable, Sendable {
  /// R-DEBT-1: a debt's currency is fixed once it has records.
  case currencyLocked
  /// A leg needs a money-moving record kind and a positive amount on an existing account.
  case invalidLeg
  /// Only an expense or income that is not a leg yet can become a debt record (R-DEBT-11).
  case notLinkable
  /// The debt's currency differs from the account's and no amount in it was given.
  case amountUnknown
}

/// Turns an existing transaction into a debt record's leg (R-DEBT-9…12, docs/status/C17.md):
/// one payment, one transaction. Used by the import row action, rules and "Convert to debt
/// record".
public struct DebtLink: Hashable, Sendable {
  public var personName: String
  /// The debt to add the record to; nil = the person's debt in `currency` (an unsettled one
  /// first), created when there is none.
  public var debtID: Debt.ID?
  /// The debt's currency (used when `debtID` is nil).
  public var currency: Currency
  /// nil = suggested from the money's direction and the debt's balance at that moment
  /// (`DebtRecordKind.suggested`).
  public var kind: DebtRecordKind?
  /// In the debt's currency; nil = the transaction's amount (same currency only).
  public var amountMinor: Int64?
  /// "Count as expense" / "Count as income" where the kind offers it (R-DEBT-4); off by default.
  public var countsInReports: Bool

  public init(
    personName: String, debtID: Debt.ID? = nil, currency: Currency, kind: DebtRecordKind? = nil,
    amountMinor: Int64? = nil, countsInReports: Bool = false
  ) {
    self.personName = personName
    self.debtID = debtID
    self.currency = currency
    self.kind = kind
    self.amountMinor = amountMinor
    self.countsInReports = countsInReports
  }
}

/// A transaction an import commit turns into a debt record's leg right after inserting it.
public struct ImportDebtLink: Hashable, Sendable {
  public var txnID: Txn.ID
  public var link: DebtLink

  public init(txnID: Txn.ID, link: DebtLink) {
    self.txnID = txnID
    self.link = link
  }
}

/// Debts and their records (R-DEBT). Saving a record writes its leg — or removes it — in the
/// same database transaction; deleting a record or a debt deletes the legs.
public protocol DebtRepository: Sendable {
  /// Every debt with every record and its leg.
  func book() async throws -> DebtBook
  /// Inserts or updates. Throws `currencyLocked` when the currency changes on a debt with records.
  func save(_ debt: Debt) async throws
  /// Deletes the debt, its records and their legs.
  func delete(_ id: Debt.ID) async throws
  /// Inserts or updates a record. `leg` nil (or a kind that moves no money) = no money moved
  /// through my accounts. A flagged record (`reportKind`) without a category gets the "Debts"
  /// category of that kind (found or created).
  func save(_ record: DebtRecord, leg: DebtLegInput?) async throws
  /// Deletes the record and its leg.
  func deleteRecord(_ id: DebtRecord.ID) async throws
  /// R-DEBT-11: the transaction becomes the leg of a new record in place (same id, date,
  /// description, attached records, fingerprints, import batch); no second transaction.
  /// Throws `notLinkable` for transfers and legs, `amountUnknown` across currencies without an
  /// amount.
  @discardableResult
  func convert(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtRecord
}

extension DebtRepository {
  /// Fakes without linking.
  @discardableResult
  public func convert(_ txnID: Txn.ID, to link: DebtLink) async throws -> DebtRecord {
    throw DebtRepositoryError.notLinkable
  }
}
