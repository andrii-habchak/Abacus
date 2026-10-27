import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

@MainActor
@Suite("Default categories on first launch (C2)")
struct DefaultCategoriesTests {
  func session(_ database: any DatabaseWriter) -> AppSession {
    AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
  }

  func categories(_ database: any DatabaseWriter) async throws -> [AbacusDomain.Category] {
    try await SQLiteCategoryRepository(database: database).categories(kind: nil, includeArchived: true)
  }

  /// "Parent › Child" or "Name" for every category.
  func paths(_ list: [AbacusDomain.Category]) -> Set<String> {
    let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    return Set(list.map { category in
      category.parentID.flatMap { byID[$0] }.map { "\($0.name) › \(category.name)" } ?? category.name
    })
  }

  @Test("R-CAT-4 the first launch on an empty database seeds the default set")
  func seedsOnFirstLaunch() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    let list = try await categories(database)
    #expect(list.count == 22)
    #expect(paths(list).isSuperset(of: [
      "Food › Groceries", "Food › Eating out", "Housing › Rent", "Housing › Utilities", "Transport › Fuel",
      "Transport › Taxi", "Transport › Public transport", "Health", "Bills › Mobile", "Bills › Internet", "Shopping",
      "Travel", "Fees", "Gifts", "Salary", "Cashback", "Refunds", "Other income",
    ]))
    #expect(Set(list.filter { $0.kind == .income }.map(\.name)) == ["Salary", "Cashback", "Refunds", "Other income"])
    #expect(list.allSatisfy { !ColorPalette.needsColor($0.colorHex) && !$0.isArchived && $0.importBatchID == nil })
    // The categories screen shows them.
    await s.categories.load()
    #expect(s.categories.phase == .loaded)
  }

  @Test("R-CAT-4 a database with any category is left alone, and edits survive the next launch")
  func onlyWhenEmpty() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let first = session(database)
    await first.start()
    first.stop()
    let repository = SQLiteCategoryRepository(database: database)
    var food = try #require(try await categories(database).first { $0.name == "Food" })
    food.name = "Food & drinks"
    try await repository.save(food)

    let second = session(database)
    await second.start()
    defer { second.stop() }
    let list = try await categories(database)
    #expect(list.count == 22)
    #expect(list.contains { $0.name == "Food & drinks" })
    #expect(!list.contains { $0.name == "Food" })

    // One archived category is enough to skip seeding.
    let other = try AbacusDatabase.open(at: nil)
    try await SQLiteCategoryRepository(database: other).save(
      AbacusDomain.Category(name: "Old", kind: .expense, isArchived: true))
    #expect(try await DefaultCategories.seedIfEmpty(other) == false)
    #expect(try await categories(other).count == 1)
  }

  @Test("R-CAT-4 Load Sample Data on a database with only the defaults reuses them by name")
  func sampleDataReusesDefaults() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    let defaults = try await categories(database)
    await s.loadSampleData()
    #expect(s.sampleDataMessage?.hasPrefix("Sample data loaded") == true)

    let list = try await categories(database)
    // Only "Clothing" and the sample debts' "Debts" category (C14) are new; nothing is duplicated.
    #expect(list.count == defaults.count + 2)
    #expect(paths(list).count == list.count)
    #expect(list.contains { $0.name == "Clothing" && $0.parentID == nil })

    // Sample transactions, lines and budget limits point at the default categories.
    let groceries = try #require(defaults.first { $0.name == "Groceries" })
    let cashback = try #require(defaults.first { $0.name == "Cashback" })
    let (lidl, line, limits) = try await database.read { db in
      (
        try Txn.where { $0.id.eq(PreviewData.id(411)) }.fetchOne(db),
        try AttachedRecord.where { $0.id.eq(PreviewData.id(502)) }.fetchOne(db),
        try BudgetAllocation.fetchAll(db)
      )
    }
    #expect(lidl?.categoryID == groceries.id)
    #expect(line?.categoryID == cashback.id)
    #expect(limits.contains { $0.categoryID == groceries.id })
    let ids = Set(list.map(\.id))
    #expect(limits.allSatisfy { ids.contains($0.categoryID) })
    #expect(s.transactions.reference.accounts.count == PreviewData.accounts.count)
  }

  @Test("R-CAT-4 sample categories keep their ids on an empty database, and never reuse a taken id")
  func sampleMappingIDs() {
    let sample = [
      AbacusDomain.Category(id: PreviewData.id(1), name: "Food", kind: .expense),
      AbacusDomain.Category(id: PreviewData.id(2), name: "Groceries", kind: .expense, parentID: PreviewData.id(1)),
      AbacusDomain.Category(id: PreviewData.id(3), name: "Salary", kind: .income),
    ]
    let (fresh, identity) = SampleData.categoriesToInsert(sample, existing: [])
    #expect(Set(fresh.map(\.id)) == Set(sample.map(\.id)))
    #expect(identity[PreviewData.id(2)] == PreviewData.id(2))

    // "Food" exists under another id; id 3 is taken by a renamed category; "food" matches
    // case-insensitively, an expense "Salary" does not match the income one.
    let existing = [
      AbacusDomain.Category(id: PreviewData.id(9), name: "food", kind: .expense),
      AbacusDomain.Category(id: PreviewData.id(3), name: "Wages", kind: .income),
      AbacusDomain.Category(name: "Salary", kind: .expense),
    ]
    let (inserts, mapping) = SampleData.categoriesToInsert(sample, existing: existing)
    #expect(mapping[PreviewData.id(1)] == PreviewData.id(9))
    let groceries = inserts.first { $0.name == "Groceries" }
    #expect(groceries?.parentID == PreviewData.id(9))
    let salary = inserts.first { $0.name == "Salary" }
    #expect(salary != nil && salary?.id != PreviewData.id(3))
    #expect(mapping[PreviewData.id(3)] == salary?.id)
  }
}
