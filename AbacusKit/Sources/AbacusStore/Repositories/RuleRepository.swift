import AbacusDomain
import Foundation
import SQLiteData

/// Categorisation rules (R-IMP-8): "description contains X → category Y".
public struct SQLiteRuleRepository: RuleRepository {
  public let database: any DatabaseWriter
  /// Calendar for the days of the transfers a debt rule makes (R-DEBT-12).
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
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
      try RefundLinks.repair(db)
    }
  }

  public func apply(_ rule: CategoryRule, records: [RuleApplication]) async throws {
    let calendar = self.calendar
    try await database.write { db in
      try CategoryRule.upsert { CategoryRule.Draft(rule) }.execute(db)
      if rule.action == .debt {
        try Self.applyDebtRule(rule, records: records, calendar: calendar, db)
        return
      }
      for record in records {
        guard let current = try Txn.find(record.txnID).fetchOne(db) else { throw RepositoryError.notFound }
        try Txn.upsert { Txn.Draft(record.after.applied(to: current)) }.execute(db)
        try RuleApplication.insert { RuleApplication.Draft(record) }.execute(db)
      }
      try RefundLinks.repair(db)
    }
  }

  /// R-DEBT-12, R-DEBT-19: each transaction becomes a transfer to the rule's person (the person's
  /// debt and virtual account in the account's currency), oldest first; the application records
  /// the transaction as the rule left it, so roll back can undo it.
  private static func applyDebtRule(
    _ rule: CategoryRule, records: [RuleApplication], calendar: Calendar, _ db: Database
  ) throws {
    guard let person = rule.debtPerson else { throw DebtRepositoryError.notLinkable }
    var items: [(RuleApplication, Txn)] = []
    for record in records {
      guard let current = try Txn.find(record.txnID).fetchOne(db) else { throw RepositoryError.notFound }
      items.append((record, current))
    }
    items.sort { ($0.1.occurredAt, $0.1.id.uuidString) < ($1.1.occurredAt, $1.1.id.uuidString) }
    for (record, current) in items {
      try DebtLinking.transfer(current.id, to: DebtLink(personName: person), db)
      guard let leg = try Txn.find(current.id).fetchOne(db) else { throw RepositoryError.notFound }
      var applied = record
      applied.before = RuleTxnState(current)
      applied.after = RuleTxnState(leg)
      try RuleApplication.insert { RuleApplication.Draft(applied) }.execute(db)
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
        // A debt rule's transfer goes back to the transaction it was (R-DEBT-19); a debt or
        // virtual account the rule created stays, empty.
        try Txn.upsert { Txn.Draft(restored) }.execute(db)
        result.restored += 1
      }
      try RuleApplication.where { $0.ruleID.eq(ruleID) }.delete().execute(db)
      try RefundLinks.repair(db)
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
