import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Schema v8 (rule applications, TA v1.6 rollback) and amount-only rules. Synthetic data only.
@Suite("Rules v8")
struct RuleApplicationsV8Tests {
  typealias F = StoreFixture

  /// A database file at the schema before v8 (v6) with a rule and a transaction, then migrated.
  @Test("TA v1.6: v8 adds the rule applications table to a database at the v6 schema and keeps its data")
  func migratesFromV6() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "old.sqlite")

    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let old = try DatabaseQueue(path: url.path, configuration: configuration)
    try AbacusDatabase.migrator().migrate(old, upTo: "v6: rules")
    try await old.write { db in
      #expect(try !db.tableExists("ruleApplications"))
      try db.execute(
        sql: """
          INSERT INTO accounts (id, name, currency, kind, openingDate) \
          VALUES ('00000000-0000-0000-0000-000000000001', 'Bank', 'PLN', 'bank', '2026-01-01 00:00:00.000');
          INSERT INTO categories (id, name, kind) VALUES ('00000000-0000-0000-0000-000000000011', 'Groceries', 'expense');
          INSERT INTO categoryRules (id, pattern, categoryID, origin, hitCount, position, isEnabled, matchKind, action) VALUES \
          ('00000000-0000-0000-0000-000000000101', 'grocery store', '00000000-0000-0000-0000-000000000011', 'imported', 7, 0, 1, 'contains', 'category');
          """)
    }
    try old.close()

    let database = try AbacusDatabase.open(at: url)
    let rules = try await SQLiteRuleRepository(database: database).rules()
    #expect(rules.map(\.pattern) == ["grocery store"])
    #expect(try await SQLiteRuleRepository(database: database).applications(of: F.id(101)).isEmpty)
    try await database.read { db in
      #expect(try db.tableExists("ruleApplications"))
      let columns = try db.columns(in: "ruleApplications").map(\.name)
      #expect(columns == ["id", "ruleID", "batchID", "txnID", "appliedAt", "before", "after"])
      let indexes = try db.indexes(on: "ruleApplications").map(\.name).filter { $0.hasPrefix("idx_") }
      #expect(Set(indexes) == ["idx_ruleApplications_ruleID", "idx_ruleApplications_txnID"])
      // CloudKit rules: no UNIQUE index, foreign keys cascade.
      #expect(try db.indexes(on: "ruleApplications").filter { $0.name.hasPrefix("idx_") }.allSatisfy { !$0.isUnique })
      let actions = try String.fetchAll(db, sql: #"SELECT "on_delete" FROM pragma_foreign_key_list('ruleApplications')"#)
      #expect(actions == ["CASCADE", "CASCADE"])
      #expect(try String.fetchAll(db, sql: "SELECT \"table\" FROM pragma_foreign_key_check").isEmpty)
    }
  }

  private func applied(_ f: F, rule: CategoryRule, _ ids: [Int], change: (inout Txn) -> Void, at date: Date = Date()) async throws
    -> [RuleApplication]
  {
    var originals: [Txn] = []
    var changes: [Txn] = []
    for n in ids {
      let txn = try #require(try await f.txns.transaction(F.id(n))?.txn)
      var changed = txn
      change(&changed)
      originals.append(txn)
      changes.append(changed)
    }
    let records = RuleApplication.records(ruleID: rule.id, originals: originals, changes: changes, at: date)
    try await f.rules.apply(rule, records: records)
    return records
  }

  @Test("TA v1.6: applying records what changed; roll back restores it after a restart, skipping transactions edited since")
  func applyAndRollBack() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, payee: "Shop one"))
    try await f.insert(F.expense(101, "2026-03-03", 20_00, nil, payee: "Shop two"))
    try await f.insert(F.expense(102, "2026-03-04", 30_00, F.fees, payee: "Shop three"))
    let rule = CategoryRule(pattern: "shop", categoryID: F.eatingOut.id)
    let records = try await applied(f, rule: rule, [100, 101, 102]) { $0.categoryID = F.eatingOut.id }
    #expect(try await f.rules.rules().map(\.id) == [rule.id])
    for n in [100, 101, 102] { #expect(try await f.txns.transaction(F.id(n))?.txn.categoryID == F.eatingOut.id) }
    #expect(try await f.rules.applications(of: rule.id).count == 3)
    #expect(Set(records.map(\.batchID)).count == 1)

    // The user edits one of them afterwards (category) and another one's note only.
    var edited = try #require(try await f.txns.transaction(F.id(102))?.txn)
    edited.categoryID = F.transport.id
    try await f.txns.save(edited, lines: [])
    var noted = try #require(try await f.txns.transaction(F.id(100))?.txn)
    noted.note = "kept"
    try await f.txns.save(noted, lines: [])

    // A new repository on the same database (as after a restart).
    let result = try await SQLiteRuleRepository(database: f.database).rollBack(rule.id)
    #expect(result == RuleRollback(restored: 2, skipped: 1))
    let restored = try #require(try await f.txns.transaction(F.id(100))?.txn)
    #expect(restored.categoryID == F.groceries.id)
    #expect(restored.note == "kept")
    #expect(try await f.txns.transaction(F.id(101))?.txn.categoryID == nil)
    #expect(try await f.txns.transaction(F.id(102))?.txn.categoryID == F.transport.id)
    #expect(try await f.rules.applications(of: rule.id).isEmpty)
    // The rule stays.
    #expect(try await f.rules.rules().map(\.id) == [rule.id])
  }

  @Test("TA v1.6: a transfer rule rolls back to the expense; two applications roll back newest first")
  func rollBackTransferAndTwice() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, payee: "Friend"))
    let rule = CategoryRule(pattern: "friend", categoryID: F.eatingOut.id)
    _ = try await applied(f, rule: rule, [100], change: { $0.categoryID = F.eatingOut.id }, at: F.at("2026-03-05"))
    var transfer = rule
    transfer.action = .transfer
    transfer.categoryID = nil
    transfer.transferAccountID = F.loan.id
    _ = try await applied(f, rule: transfer, [100], change: {
      $0.type = .transfer
      $0.categoryID = nil
      $0.toAccountID = F.loan.id
      $0.toAmountMinor = 10_00
    }, at: F.at("2026-03-06"))
    #expect(try await f.txns.transaction(F.id(100))?.txn.type == .transfer)
    #expect(try await f.rules.applications(of: rule.id).map(\.appliedAt) == [F.at("2026-03-06"), F.at("2026-03-05")])

    let result = try await f.rules.rollBack(rule.id)
    #expect(result == RuleRollback(restored: 2, skipped: 0))
    let back = try #require(try await f.txns.transaction(F.id(100))?.txn)
    #expect(back.type == .expense)
    #expect(back.categoryID == F.groceries.id)
    #expect(back.toAccountID == nil && back.toAmountMinor == nil)
  }

  @Test("TA v1.6: apply is all or nothing; deleting the rule or the transaction deletes its records")
  func atomicAndCascade() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, payee: "Shop"))
    try await f.insert(F.expense(101, "2026-03-03", 10_00, F.groceries, payee: "Shop"))
    let rule = CategoryRule(pattern: "shop", categoryID: F.eatingOut.id)
    let missing = F.expense(999, "2026-03-02", 1_00, nil)
    let present = try #require(try await f.txns.transaction(F.id(100))?.txn)
    var bad = RuleApplication.records(ruleID: rule.id, originals: [present], changes: [present])
    bad += RuleApplication.records(ruleID: rule.id, originals: [missing], changes: [missing])
    await #expect(throws: RepositoryError.notFound) { try await f.rules.apply(rule, records: bad) }
    #expect(try await f.rules.rules().isEmpty)
    #expect(try await f.rules.applications(of: rule.id).isEmpty)

    _ = try await applied(f, rule: rule, [100, 101]) { $0.categoryID = F.eatingOut.id }
    try await f.txns.delete(F.id(101))
    #expect(try await f.rules.applications(of: rule.id).map(\.txnID) == [F.id(100)])
    try await f.rules.delete(rule.id)
    let left = try await f.database.read { db in try RuleApplication.all.fetchCount(db) }
    #expect(left == 0)
  }

  @Test("TA v1.6: an amount-only rule (empty pattern) is stored and read back")
  func amountOnlyRoundTrip() async throws {
    let f = try F()
    try f.seedBasics()
    let rule = CategoryRule(pattern: "", amountComparison: .biggerThan, amountMinor: 500_00, categoryID: F.fees.id)
    try await f.rules.save(rule)
    let stored = try #require(try await f.rules.rules().first)
    #expect(stored == rule)
    #expect(!stored.hasDescriptionCondition && stored.hasAmountCondition && stored.hasCondition)
  }
}
