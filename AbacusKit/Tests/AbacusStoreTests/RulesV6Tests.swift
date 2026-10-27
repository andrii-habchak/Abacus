import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Schema v6 (Saldo-like rules, R-IMP-8, D44) and applying a rule to existing transactions
/// (R-MGMT-6). Synthetic data only.
@Suite("Rules v6")
struct RulesV6Tests {
  typealias F = StoreFixture

  /// A database file at the schema before v6 with two learned rules, then migrated.
  @Test("R-IMP-8, D44: v6 keeps every existing rule as a \"contains\" category rule")
  func migratesExistingRules() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "old.sqlite")

    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let old = try DatabaseQueue(path: url.path, configuration: configuration)
    try AbacusDatabase.migrator().migrate(old, upTo: "v3: importBatchID on accounts, categories, events")
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO accounts (id, name, currency, kind, openingDate) \
          VALUES ('00000000-0000-0000-0000-000000000001', 'Bank', 'PLN', 'bank', '2026-01-01 00:00:00.000');
          INSERT INTO categories (id, name, kind) VALUES ('00000000-0000-0000-0000-000000000011', 'Groceries', 'expense');
          INSERT INTO categoryRules (id, pattern, accountID, categoryID, origin, hitCount, position, isEnabled) VALUES \
          ('00000000-0000-0000-0000-000000000101', 'grocery store', NULL, '00000000-0000-0000-0000-000000000011', 'imported', 7, 0, 1), \
          ('00000000-0000-0000-0000-000000000102', 'kiosk', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'manual', 0, 1, 0);
          """)
    }
    try old.close()

    let database = try AbacusDatabase.open(at: url)
    let rules = try await SQLiteRuleRepository(database: database).rules()
    #expect(rules.count == 2)
    let learned = try #require(rules.first)
    #expect(learned.id == F.id(101))
    #expect(learned.pattern == "grocery store")
    #expect(learned.matchKind == .contains)
    #expect(learned.action == .category)
    #expect(learned.categoryID == F.id(11))
    #expect(learned.amountComparison == nil && learned.amountMinor == nil && learned.transferAccountID == nil)
    #expect(learned.origin == .imported && learned.hitCount == 7 && learned.isEnabled)
    let scoped = try #require(rules.last)
    #expect(scoped.accountID == F.id(1))
    #expect(!scoped.isEnabled)

    try await database.read { db in
      let indexes = try db.indexes(on: "categoryRules").map(\.name)
      #expect(Set(indexes).isSuperset(of: ["idx_categoryRules_accountID", "idx_categoryRules_categoryID", "idx_categoryRules_transferAccountID"]))
      #expect(try db.columns(in: "categoryRules").first { $0.name == "categoryID" }?.isNotNull == false)
      #expect(try String.fetchAll(db, sql: "SELECT \"table\" FROM pragma_foreign_key_check").isEmpty)
    }
  }

  @Test("D44: a transfer rule is stored without a category and goes with its account")
  func transferRuleRoundTrip() async throws {
    let f = try F()
    try f.seedBasics()
    let rule = CategoryRule(
      pattern: "friend", matchKind: .exactly, amountComparison: .smallerThan, amountMinor: 50_00, action: .transfer,
      transferAccountID: F.loan.id)
    try await f.rules.save(rule)
    #expect(try await f.rules.rules() == [rule])
    // Deleting the account (unused) deletes the rule that points at it.
    try await f.accounts.delete(F.loan.id)
    #expect(try await f.rules.rules().isEmpty)
  }

  @Test("R-MGMT-6: saving a rule with its changes writes both in one transaction; a missing transaction rolls back")
  func saveUpdating() async throws {
    let f = try F()
    try f.seedBasics()
    let line = AttachedRecord(txnID: F.id(100), categoryID: F.fees.id, amountMinor: 1_00)
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, payee: "Shop"), lines: [line])
    var changed = try #require(try await f.txns.transaction(F.id(100))?.txn)
    changed.type = .transfer
    changed.categoryID = nil
    changed.toAccountID = F.loan.id
    changed.toAmountMinor = 10_00
    let rule = CategoryRule(pattern: "shop", action: .transfer, transferAccountID: F.loan.id)

    let missing = F.expense(999, "2026-03-02", 1_00, nil)
    await #expect(throws: RepositoryError.notFound) { try await f.rules.save(rule, updating: [changed, missing]) }
    #expect(try await f.rules.rules().isEmpty)
    #expect(try await f.txns.transaction(F.id(100))?.txn.type == .expense)

    try await f.rules.save(rule, updating: [changed])
    #expect(try await f.rules.rules().map(\.id) == [rule.id])
    let stored = try #require(try await f.txns.transaction(F.id(100)))
    #expect(stored.txn == changed)
    #expect(stored.lines.map(\.id) == [line.id])
  }
}
