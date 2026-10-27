import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Colours (R-MGMT-7)")
struct ColorTests {
  typealias F = StoreFixture

  // MARK: Palette

  @Test("The palette is distinct, valid and has no grey")
  func palette() {
    #expect(Set(ColorPalette.colors).count == ColorPalette.colors.count)
    #expect(ColorPalette.colors.allSatisfy { ColorPalette.normalized($0) == $0 && !ColorPalette.needsColor($0) })
    #expect(ColorPalette.needsColor(nil))
    #expect(ColorPalette.needsColor("#8E8E93"))
    #expect(ColorPalette.needsColor("#808080"))
    #expect(ColorPalette.needsColor("not a colour"))
    #expect(!ColorPalette.needsColor("#e5484d"))
    #expect(ColorPalette.normalized("e5484d") == "#E5484D")
  }

  @Test("A pick avoids the colours already used until the palette runs out")
  func pickAvoidsUsed() {
    var used: [String?] = []
    for _ in ColorPalette.colors {
      used.append(ColorPalette.pick(avoiding: used))
    }
    #expect(Set(used.compactMap { $0 }) == Set(ColorPalette.colors))
    // All used once: the next pick is any palette colour, and one used less wins.
    let lessUsed = ColorPalette.colors[4]
    let twice = ColorPalette.colors.filter { $0 != lessUsed }.map(Optional.some) + used
    #expect(ColorPalette.pick(avoiding: twice) == lessUsed)
  }

  // MARK: Creation

  @Test("Saving a category, account or event without a colour gives it a palette colour; a set colour is kept")
  func randomColourOnCreate() async throws {
    let f = try F()
    try await f.accounts.save(F.bank)
    var card = F.card
    card.colorHex = "#123456"
    try await f.accounts.save(card)
    try await f.categories.save(F.food)
    try await f.categories.save(F.groceries)
    try await f.categories.save(F.eatingOut)
    try await f.events.save(F.trip)

    let accounts = try await f.accounts.accounts(includeArchived: true)
    #expect(accounts.first { $0.id == F.bank.id }?.colorHex.map(ColorPalette.colors.contains) == true)
    #expect(accounts.first { $0.id == F.card.id }?.colorHex == "#123456")
    let categories = try await f.categories.categories(kind: nil, includeArchived: true)
    let colors = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.colorHex) })
    #expect(categories.allSatisfy { $0.colorHex.map(ColorPalette.colors.contains) == true })
    // Siblings and the parent stay apart.
    #expect(Set([colors[F.food.id], colors[F.groceries.id], colors[F.eatingOut.id]]).count == 3)
    let trip = try await f.events.events(includeArchived: true).first
    #expect(trip?.colorHex.map(ColorPalette.colors.contains) == true)

    // An edit that keeps the colour does not change it.
    var food = try #require(categories.first { $0.id == F.food.id })
    food.name = "Food & drink"
    try await f.categories.save(food)
    let after = try await f.categories.categories(kind: nil, includeArchived: true).first { $0.id == F.food.id }
    #expect(after?.colorHex == colors[F.food.id])
  }

  @Test("Siblings created one by one get different colours")
  func siblingsDistinct() async throws {
    let f = try F()
    for n in 0..<ColorPalette.colors.count {
      try await f.categories.save(AbacusDomain.Category(id: F.id(100 + n), name: "C\(n)", kind: .expense, position: n))
    }
    let colors = try await f.categories.categories(kind: .expense, includeArchived: true).compactMap(\.colorHex)
    #expect(Set(colors).count == ColorPalette.colors.count)
  }

  @Test("An import commit colours the accounts, categories and events it creates")
  func importCommitColours() async throws {
    let f = try F()
    let batch = ImportBatch(id: F.id(900), source: .saldo, fileName: "saldo.csv")
    try await f.imports.commit(
      ImportCommit(
        batch: batch, newAccounts: [F.bank], newCategories: [F.food, F.groceries], newEvents: [F.trip]))
    let (accounts, categories, events) = try await f.database.read { db in
      (try Account.fetchAll(db), try AbacusDomain.Category.fetchAll(db), try Event.fetchAll(db))
    }
    #expect(accounts.allSatisfy { !ColorPalette.needsColor($0.colorHex) })
    #expect(categories.allSatisfy { !ColorPalette.needsColor($0.colorHex) })
    #expect(events.allSatisfy { !ColorPalette.needsColor($0.colorHex) })
  }

  // MARK: Migration "v4: colours"

  static let v3 = "v3: importBatchID on accounts, categories, events"

  /// A database at the schema before colours, with uncoloured, grey and coloured rows.
  static func preV4Database(at url: URL? = nil) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try url.map { try DatabaseQueue(path: $0.path, configuration: configuration) }
      ?? DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: v3)
    try queue.write { db in
      let categories: [(String, String, String?, String?)] = [
        ("c-food", "expense", nil, nil),
        ("c-fees", "expense", nil, "#8E8E93"),
        ("c-uncat", "expense", nil, "#E5484D"),
        ("c-groceries", "expense", "c-food", nil),
        ("c-eating", "expense", "c-food", nil),
        ("c-salary", "income", nil, "#5C7B99"),
      ]
      // Ids as the store writes them (lower-case UUID text); the tests look rows up by name.
      func uuid(_ n: Int) -> String { F.id(n).uuidString.lowercased() }
      let ids = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.0, uuid(500 + $0)) })
      for (index, (name, kind, parent, color)) in categories.enumerated() {
        try db.execute(
          sql: #"INSERT INTO "categories" ("id", "name", "kind", "parentID", "colorHex", "position") VALUES (?, ?, ?, ?, ?, ?)"#,
          arguments: [ids[name], name, kind, parent.flatMap { ids[$0] }, color, index])
      }
      for (index, color) in [nil, "#8E8E93", "#0A64D6"].enumerated() {
        try db.execute(
          sql: #"""
            INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingDate", "colorHex", "position")
            VALUES (?, ?, 'PLN', 'bank', '2026-01-01 00:00:00.000', ?, ?)
            """#,
          arguments: [uuid(600 + index), "Account \(index)", color, index])
      }
      for index in 0..<3 {
        try db.execute(
          sql: #"INSERT INTO "events" ("id", "name") VALUES (?, ?)"#, arguments: [uuid(700 + index), "Event \(index)"])
      }
    }
    return queue
  }

  static func colours(_ db: Database, _ table: String) throws -> [String: String?] {
    let lines = try String.fetchAll(db, sql: #"SELECT "name" || '=' || coalesce("colorHex", '') FROM "\#(table)""#)
    return Dictionary(uniqueKeysWithValues: lines.map { line in
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (String(parts[0]), parts[1].isEmpty ? nil : String(parts[1]))
    })
  }

  @Test("v4 adds the event colour and fills uncoloured and grey rows once; set colours stay")
  func migrationFill() throws {
    let queue = try Self.preV4Database()
    try AbacusDatabase.migrator().migrate(queue)
    try queue.read { db in
      #expect(try db.columns(in: "events").contains { $0.name == "colorHex" })
      let categories = try Self.colours(db, "categories")
      #expect(categories.values.allSatisfy { !ColorPalette.needsColor($0) })
      #expect(categories["c-uncat"] == "#E5484D")
      #expect(categories["c-salary"] == "#5C7B99")  // slate is a colour, not grey
      #expect(categories["c-fees"] != "#8E8E93")
      // Top-level expense siblings, and a parent with its children, stay apart.
      #expect(Set([categories["c-food"], categories["c-fees"], categories["c-uncat"]]).count == 3)
      #expect(Set([categories["c-food"], categories["c-groceries"], categories["c-eating"]]).count == 3)

      let accounts = try Self.colours(db, "accounts")
      #expect(accounts["Account 2"] == "#0A64D6")
      #expect(accounts.values.allSatisfy { !ColorPalette.needsColor($0) })
      #expect(Set(accounts.values).count == 3)

      let events = try Self.colours(db, "events")
      #expect(events.values.allSatisfy { !ColorPalette.needsColor($0) })
      #expect(Set(events.values).count == 3)
    }

    // Idempotent: migrating again or re-running the fill changes nothing.
    let before = try queue.read { db in try Self.colours(db, "categories") }
    try AbacusDatabase.migrator().migrate(queue)
    try queue.write { db in try ColorFill.fillAll(db, replacingGrey: true) }
    #expect(try queue.read { db in try Self.colours(db, "categories") } == before)
  }

  @Test("v4 on a pre-colour database file, then the app's repositories read every entity")
  func migrationOnFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-v4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "old.sqlite")
    try Self.preV4Database(at: url).close()

    let database = try AbacusDatabase.open(at: url)
    let events = try await SQLiteEventRepository(database: database).events(includeArchived: true)
    #expect(events.count == 3 && events.allSatisfy { !ColorPalette.needsColor($0.colorHex) })
    let categories = try await SQLiteCategoryRepository(database: database).categories(kind: nil, includeArchived: true)
    #expect(categories.count == 6 && categories.allSatisfy { !ColorPalette.needsColor($0.colorHex) })
    let applied = try await database.read { db in try AbacusDatabase.migrator().appliedIdentifiers(db) }
    #expect(applied.contains("v4: colours"))
  }
}
