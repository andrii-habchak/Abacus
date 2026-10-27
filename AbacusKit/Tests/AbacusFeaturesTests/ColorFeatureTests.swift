import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

@MainActor
@Suite("Colours on screens (R-MGMT-7)")
struct ColorFeatureTests {
  func session(_ database: any DatabaseWriter) -> AppSession {
    AppSession.live(
      database: database, source: StubSource(rates: B1Fixture.rates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
  }

  @Test("A category's new colour reaches the transaction list without a relaunch")
  func colourChangeReachesList() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    await s.loadSampleData()
    await s.transactions.load()
    let item = try #require(s.transactions.rows.first { $0.txn.type == .expense && $0.txn.categoryID != nil })
    let categoryID = try #require(item.txn.categoryID)
    func icon() -> String? {
      s.transactions.content.days.flatMap(\.rows).first { $0.id == item.txn.id }?.icon.colorHex
    }
    #expect(icon().map(ColorPalette.colors.contains) == true)

    await s.categories.load()
    let category = try #require(s.categories.category(categoryID))
    s.categories.setKind(category.kind)
    s.categories.select(categoryID)
    s.categories.draft?.colorHex = "#123456"
    await s.categories.save()
    #expect(s.categories.category(categoryID)?.colorHex == "#123456")

    // The list re-reads its categories in the background.
    for _ in 0..<100 where icon() != "#123456" {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(icon() == "#123456")
  }

  @Test("A subcategory without its own colour shows its parent's")
  func childFallsBackToParent() {
    let parent = AbacusDomain.Category(name: "Food", kind: .expense, colorHex: "#E07B14")
    let child = AbacusDomain.Category(name: "Snacks", kind: .expense, parentID: parent.id)
    let tree = TransactionCategoryTree([parent, child])
    #expect(tree.color(child.id) == "#E07B14")
    #expect(tree.color(nil) == nil)
  }

  @Test("New accounts and events start with a palette colour apart from the others; edits save it")
  func newDraftsGetColours() async throws {
    let deps = ManageDependencies.preview()
    let accounts = AccountsModel(dependencies: deps)
    await accounts.load()
    accounts.newAccount(currency: .PLN)
    let accountColor = try #require(accounts.draft?.colorHex)
    #expect(ColorPalette.colors.contains(accountColor))
    accounts.draft?.name = "Wallet"
    accounts.draft?.colorHex = "#C93B6E"
    await accounts.save()
    #expect(accounts.accounts.first { $0.name == "Wallet" }?.colorHex == "#C93B6E")

    let events = EventsModel(dependencies: deps)
    await events.load()
    events.newEvent()
    let eventColor = try #require(events.draft?.colorHex)
    #expect(ColorPalette.colors.contains(eventColor))
    #expect(!events.events.compactMap(\.colorHex).contains(eventColor))
    events.draft?.name = "Ski week"
    await events.save()
    #expect(events.events.first { $0.name == "Ski week" }?.colorHex == eventColor)
    #expect(events.rows.first { $0.name == "Ski week" }?.colorHex == eventColor)
  }

  @Test("Saving on a manage screen tells the session")
  func manageSaveNotifies() async {
    let model = EventsModel(dependencies: .preview())
    await model.load()
    var calls = 0
    model.onDataChange = { calls += 1 }
    model.newEvent()
    model.draft?.name = "Holiday"
    await model.save()
    #expect(calls == 1)
  }
}
