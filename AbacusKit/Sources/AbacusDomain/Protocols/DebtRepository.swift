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
}
