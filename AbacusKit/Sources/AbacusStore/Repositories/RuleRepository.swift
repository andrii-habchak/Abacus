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
