import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// The budget editor and the dashboard widget on one app database (C8 widget bug: the editor
/// showed Home in PLN while the widget read it in EUR).
@MainActor
@Suite("Budget · editor to dashboard over the store")
struct BudgetRoundTripTests {
  let eatingOut = AbacusDomain.Category(name: "Eating out", kind: .expense, position: 0)
  let home = AbacusDomain.Category(name: "Home", kind: .expense, position: 1)

  func session() async throws -> (AppSession, any DatabaseWriter) {
    let database = try AbacusDatabase.open(at: nil)
    let categories = SQLiteCategoryRepository(database: database)
    try await categories.save(eatingOut)
    try await categories.save(home)
    let session = AppSession.live(
      database: database, source: StubSource(rates: B1Fixture.rates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await session.start()
    await session.waitForLaunchFetch()
    return (session, database)
  }

  /// Eating out 400 EUR and Home 5 747 PLN, typed as the owner did: Home starts in the last
  /// used currency (EUR) and is switched to PLN.
  func enterOwnersLimits(_ editor: BudgetEditorModel) {
    editor.categoryToAdd = eatingOut.id
    editor.addLimit()
    editor.setCurrency(.EUR, for: eatingOut.id)
    editor.setLimit("400", for: eatingOut.id)
    editor.categoryToAdd = home.id
    editor.addLimit()
    editor.setLimit("5747", for: home.id)
    editor.setCurrency(.PLN, for: home.id)
  }

  @Test("C8: limits saved in EUR and PLN reach the dashboard in their own currencies; the totals agree")
  func savedLimitsReachDashboard() async throws {
    let (session, database) = try await session()
    defer { session.stop() }
    await session.budget.load()
    enterOwnersLimits(session.budget)
    await session.budget.save()
    #expect(session.budget.errorMessage == nil)

    // Stored as typed.
    let stored = try #require(try await SQLiteBudgetRepository(database: database).plan(for: B1Fixture.today.yearMonth))
    #expect(Set(stored.allocations.map(\.limit)) == [
      Money(minorUnits: 400_00, currency: .EUR), Money(minorUnits: 5_747_00, currency: .PLN),
    ])
    #expect(stored.plan.total == nil)

    await session.sectionAppeared(.dashboard)
    await session.dashboard.load()
    let widget = try #require(session.dashboard.budget)
    #expect(widget.rows.map(\.name) == ["Eating out", "Home"])
    #expect(widget.rows.map(\.limit) == [
      Money(minorUnits: 400_00, currency: .EUR), Money(minorUnits: 5_747_00, currency: .PLN),
    ])
    #expect(widget.currency == .UAH)
    #expect(widget.limit.minorUnits == session.budget.totalMinor)

    // A total in its own currency: the widget's headline is that total in the display currency.
    session.budget.totalLimit = "2000"
    session.budget.totalCurrency = .EUR
    await session.budget.save()
    await session.dashboard.load()
    let withTotal = try #require(session.dashboard.budget)
    #expect(withTotal.total?.limit == Money(minorUnits: 2_000_00, currency: .EUR))
    #expect(withTotal.limit.minorUnits == session.budget.totalMinor)
    #expect(withTotal.unallocated?.limit.currency == .EUR)
  }

  @Test("C8: unsaved edits survive a section switch and are not on the dashboard until saved")
  func unsavedEditsAreKept() async throws {
    let (session, _) = try await session()
    defer { session.stop() }
    await session.budget.load()
    enterOwnersLimits(session.budget)
    await session.budget.save()

    session.budget.setCurrency(.EUR, for: home.id)
    #expect(session.budget.isDirty)
    await session.sectionAppeared(.dashboard)
    await session.dashboard.load()
    #expect(session.dashboard.budget?.rows.last?.limit.currency == .PLN)
    await session.sectionAppeared(.budget)
    #expect(session.budget.isDirty)
    #expect(session.budget.currency(home.id) == .EUR)
    await session.budget.save()
    await session.dashboard.load()
    #expect(session.dashboard.budget?.rows.last?.limit == Money(minorUnits: 5_747_00, currency: .EUR))
  }
}
