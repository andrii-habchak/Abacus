import AbacusDomain
import Foundation
import SQLiteData

/// Categorisation rules (R-IMP-8): "description contains X → category Y".
public struct SQLiteRuleRepository: RuleRepository {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  /// In evaluation order: `position`, then the most used first.
  public func rules() async throws -> [CategoryRule] {
    try await database.read { db in
      try CategoryRule
        .order { ($0.position, $0.hitCount.desc(), $0.pattern) }
        .fetchAll(db)
    }
  }

  public func save(_ rule: CategoryRule) async throws {
    try await database.write { db in
      try CategoryRule.upsert { CategoryRule.Draft(rule) }.execute(db)
    }
  }

  public func save(_ rule: CategoryRule?, updating txns: [Txn]) async throws {
    try await database.write { db in
      if let rule { try CategoryRule.upsert { CategoryRule.Draft(rule) }.execute(db) }
      for txn in txns {
        guard try Txn.find(txn.id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
    }
  }

  public func apply(_ rule: CategoryRule, records: [RuleApplication]) async throws {
    try await database.write { db in
      try CategoryRule.upsert { CategoryRule.Draft(rule) }.execute(db)
      for record in records {
        guard let current = try Txn.find(record.txnID).fetchOne(db) else { throw RepositoryError.notFound }
        try Txn.upsert { Txn.Draft(record.after.applied(to: current)) }.execute(db)
        try RuleApplication.insert { RuleApplication.Draft(record) }.execute(db)
      }
    }
  }

  public func applications(of ruleID: CategoryRule.ID) async throws -> [RuleApplication] {
    try await database.read { db in
      try RuleApplication.where { $0.ruleID.eq(ruleID) }.order { $0.appliedAt.desc() }.fetchAll(db)
    }
  }

  public func rollBack(_ ruleID: CategoryRule.ID) async throws -> RuleRollback {
    try await database.write { db in
      // Newest first, so a transaction changed twice gets its oldest state back.
      let records = try RuleApplication.where { $0.ruleID.eq(ruleID) }.order { $0.appliedAt.desc() }.fetchAll(db)
      var result = RuleRollback()
      for record in records {
        guard let current = try Txn.find(record.txnID).fetchOne(db), let restored = record.restoring(current),
          try Self.referencesExist(restored, db)
        else {
          result.skipped += 1
          continue
        }
        try Txn.upsert { Txn.Draft(restored) }.execute(db)
        result.restored += 1
      }
      try RuleApplication.where { $0.ruleID.eq(ruleID) }.delete().execute(db)
      return result
    }
  }

  /// The category and accounts a restored transaction points at still exist.
  private static func referencesExist(_ txn: Txn, _ db: Database) throws -> Bool {
    if let categoryID = txn.categoryID, try AbacusDomain.Category.find(categoryID).fetchCount(db) == 0 { return false }
    for accountID in [txn.accountID] + (txn.toAccountID.map { [$0] } ?? []) {
      if try Account.find(accountID).fetchCount(db) == 0 { return false }
    }
    return true
  }

  public func delete(_ id: CategoryRule.ID) async throws {
    try await database.write { db in
      try CategoryRule.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  public func recordHit(_ id: CategoryRule.ID) async throws {
    try await database.write { db in
      try CategoryRule.find(id).update { $0.hitCount += 1 }.execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }
}
