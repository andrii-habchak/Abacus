import AbacusDomain
import Foundation
import SQLiteData

/// Accounts (R-ACC). Archive instead of delete when the account has history.
public struct SQLiteAccountRepository: AccountRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  public func accounts(includeArchived: Bool) async throws -> [Account] {
    try await database.read { db in
      try Account
        .where { if !includeArchived { !$0.isArchived } }
        .order { ($0.position, $0.name) }
        .fetchAll(db)
    }
  }

  /// Inserts or updates. The currency cannot change once the account has transactions (R-ACC-1).
  public func save(_ account: Account) async throws {
    try await database.write { db in
      if let existing = try Account.find(account.id).fetchOne(db),
        existing.currency != account.currency,
        try Self.hasTransactions(account.id, db)
      {
        throw StoreError.currencyLocked
      }
      try Account.upsert { Account.Draft(account) }.execute(db)
      // R-MGMT-7: an account saved without a colour gets one apart from the other accounts'.
      if ColorPalette.rgb(account.colorHex) == nil { try ColorFill.fillAccounts(db) }
    }
  }

  /// R-ACC-4: archived accounts keep their history; callers confirm a non-zero balance first.
  public func setArchived(_ id: Account.ID, _ isArchived: Bool) async throws {
    try await database.write { db in
      try Account.find(id).update { $0.isArchived = isArchived }.execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  /// R-ACC-5: only an account without transactions (either side of a transfer) can be deleted.
  /// Its categorisation rules go with it; remembered import mappings to it are forgotten.
  public func delete(_ id: Account.ID) async throws {
    try await database.write { db in
      guard try Account.find(id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
      if try Self.hasTransactions(id, db) { throw RepositoryError.accountHasTransactions }
      try ImportMapping
        .where { $0.kind.eq(MappingKind.account) && $0.targetID.eq(id) }
        .delete().execute(db)
      try Account.find(id).delete().execute(db)
    }
  }

  /// R-ACC-3: balance of every account at the end of `day` (opening balance + effects), in the
  /// account's currency.
  public func balances(asOf day: Day) async throws -> [Account.ID: Int64] {
    let series = try await SQLiteReportQueries(database: database, calendar: calendar)
      .balances(on: [day], includeArchived: true)
    return series.balances.mapValues { $0.first ?? 0 }
  }

  static func hasTransactions(_ id: Account.ID, _ db: Database) throws -> Bool {
    try Txn.where { $0.accountID.eq(id) || $0.toAccountID.eq(id) }.fetchCount(db) > 0
  }
}
