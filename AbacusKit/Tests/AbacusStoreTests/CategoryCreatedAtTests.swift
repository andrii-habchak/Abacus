import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Migration "v9: category createdAt" (R-MGMT-8): "Newest first" / "Oldest first" on the
/// Categories page need a creation date; existing rows keep their order.
@Suite("Categories · createdAt (v9)")
struct CategoryCreatedAtTests {
  typealias F = StoreFixture
  static let v6 = "v6: rules"

  /// A database at the schema before v9 (after v6), categories inserted out of name order.
  static func preV9Database(at url: URL? = nil) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try url.map { try DatabaseQueue(path: $0.path, configuration: configuration) }
      ?? DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: v6)
    try queue.write { db in
      #expect(try !db.columns(in: "categories").contains { $0.name == "createdAt" })
      // (name, kind, position): the custom order is Zoo, Apple, Mid for expenses.
      let rows: [(String, String, Int)] = [
        ("Apple", "expense", 1), ("Zoo", "expense", 0), ("Mid", "expense", 2), ("Salary", "income", 0),
      ]
      for (index, row) in rows.enumerated() {
        try db.execute(
          sql: #"INSERT INTO "categories" ("id", "name", "kind", "position", "colorHex") VALUES (?, ?, ?, ?, '#0A64D6')"#,
          arguments: [F.id(800 + index).uuidString.lowercased(), row.0, row.1, row.2])
      }
    }
    return queue
  }

  @Test("v9 adds createdAt in the current order; Oldest first starts as the custom order")
  func migration() async throws {
    let queue = try Self.preV9Database()
    try AbacusDatabase.migrator().migrate(queue)
    let repository = SQLiteCategoryRepository(database: queue)
    let expense = try await repository.categories(kind: .expense, includeArchived: true)
    let byAge = expense.sorted { $0.createdAt < $1.createdAt }.map(\.name)
    #expect(byAge == ["Zoo", "Apple", "Mid"])
    #expect(Set(expense.map(\.createdAt)).count == 3)
    // Stable values in the past: a category created now is newer than all of them.
    let year2000 = Date(timeIntervalSince1970: 946_684_800)
    #expect(expense.allSatisfy { $0.createdAt >= year2000 && $0.createdAt < year2000.addingTimeInterval(60) })
    let pets = AbacusDomain.Category(name: "Pets", kind: .expense)
    try await repository.save(pets)
    let saved = try #require(try await repository.categories(kind: .expense, includeArchived: true).first { $0.name == "Pets" })
    #expect(saved.createdAt > expense.map(\.createdAt).max()!)
    #expect(abs(saved.createdAt.timeIntervalSince(pets.createdAt)) < 0.01)
  }

  @Test("v9 on a database file; running the migrator again changes nothing")
  func onFileAndIdempotent() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-v9-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "old.sqlite")
    _ = try Self.preV9Database(at: url)
    let database = try AbacusDatabase.open(at: url)
    let first = try database.read { db in
      try String.fetchAll(db, sql: #"SELECT "name" || '@' || "createdAt" FROM "categories" ORDER BY "name""#)
    }
    #expect(first.contains("Zoo@2000-01-01 00:00:00.000"))
    #expect(first.contains("Apple@2000-01-01 00:00:01.000"))
    #expect(first.contains("Salary@2000-01-01 00:00:03.000"))
    try AbacusDatabase.migrator().migrate(database)
    let second = try database.read { db in
      try String.fetchAll(db, sql: #"SELECT "name" || '@' || "createdAt" FROM "categories" ORDER BY "name""#)
    }
    #expect(first == second)
  }
}
