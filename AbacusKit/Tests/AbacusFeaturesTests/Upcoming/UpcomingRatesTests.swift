import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import Observation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// The rate table the Upcoming dependencies hand out; replaced by the test like a rate refresh.
private actor RatesBox {
  var table: any CurrencyConverter = RateTable()
  func set(_ table: any CurrencyConverter) { self.table = table }
}

/// Set once any observed value read inside `read` changes (what makes a SwiftUI view redraw).
@MainActor
private final class ChangeFlag {
  var fired = false
  func track(_ read: () -> Void) {
    withObservationTracking(read) { [weak self] in
      MainActor.assumeIsolated { self?.fired = true }
    }
  }
}

/// QA-N2 H1 / L4: rates that arrive after the first load reach the totals, the converted lines
/// and the monthly average, and a trigger during a running sweep queues one more run.
@MainActor
@Suite("Upcoming rates and maintenance (N5b-fix)")
struct UpcomingRatesTests {
  @Test("R-REC-10: rates delivered after load convert the totals, rows and average, and notify the view")
  func ratesAfterLoad() async throws {
    let database = try UpcomingSample.database()
    let box = RatesBox()
    var dependencies = UpcomingDependencies.onDatabase(
      database, today: UpcomingTests.today, format: UpcomingTests.format)
    dependencies.converter = { await box.table }
    let model = UpcomingModel(dependencies: dependencies)
    await model.load()
    #expect(model.phase == .loaded)
    // No rates yet: foreign currencies are left out.
    let before = model.totals
    #expect(!before.unconverted.isEmpty)
    #expect(model.totalsNote.contains("No rate for"))
    let averageBefore = model.monthlyAverageText

    // What the views read; they must be told when the rates change.
    let totalsFlag = ChangeFlag()
    totalsFlag.track { _ = model.totals }
    let rowsFlag = ChangeFlag()
    rowsFlag.track { _ = model.groups }
    let averageFlag = ChangeFlag()
    averageFlag.track { _ = model.monthlyAverageText }

    await box.set(RateTable(rates: PreviewData.fxRates, today: PreviewData.today))
    await model.refreshRates()

    #expect(totalsFlag.fired)
    #expect(rowsFlag.fired)
    #expect(averageFlag.fired)
    let after = model.totals
    #expect(after.unconverted.isEmpty)
    #expect(!model.totalsNote.contains("No rate for"))
    #expect(after.outMinor > before.outMinor)
    #expect(model.monthlyAverageText != averageBefore)
    // Foreign rows now carry their "≈" line.
    #expect(model.groups.flatMap(\.rows).contains { $0.convertedText?.hasPrefix("≈") == true })
  }

  @Test("R-REC-10: a reload replaces the rates and notifies even when nothing else changed")
  func reloadNotifies() async throws {
    let database = try UpcomingSample.database()
    let model = UpcomingModel(
      dependencies: .onDatabase(database, today: UpcomingTests.today, format: UpcomingTests.format))
    await model.load()
    let version = model.ratesVersion
    let flag = ChangeFlag()
    flag.track { _ = model.totals }
    await model.load()
    #expect(flag.fired)
    #expect(model.ratesVersion == version + 1)
  }

  @Test("R-REC-7c: a trigger during a running sweep queues exactly one more run")
  func maintenanceRerun() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let session = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await session.start()
    defer { session.stop() }
    await session.runScheduledMaintenance().value
    let base = session.maintenanceRuns
    // Foreign writes arrive after the sweep has read the data: one extra run, however many
    // triggers; it is part of the same task.
    var triggered = false
    session.afterMaintenanceSweep = { [weak session] in
      guard let session, !triggered else { return }
      triggered = true
      session.runScheduledMaintenance()
      session.runScheduledMaintenance()
    }
    let running = session.runScheduledMaintenance()
    await running.value
    session.afterMaintenanceSweep = nil
    #expect(session.maintenanceRuns == base + 2)
    // Idle again: the next trigger starts a fresh single run.
    await session.runScheduledMaintenance().value
    #expect(session.maintenanceRuns == base + 3)
  }

  @Test("R-REC-7: the import badge shows the expected day like the Upcoming rows")
  func importBadgeDay() {
    let format = ImportFormat(calendar: UpcomingTests.calendar)
    #expect(format.shortDay(Day(year: 2026, month: 11, day: 12)) == "12 Nov")
    #expect(format.shortDay(Day(year: 2026, month: 3, day: 5)) == "5 Mar")
  }

  @Test("R-REC-9: Load Sample Data starts the items near today; the first sweep stores paid and missed, not dozens missed")
  func sampleNearToday() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let session = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await session.start()
    defer { session.stop() }
    await session.loadSampleData()
    await session.runScheduledMaintenance().value
    let (items, occurrences) = try await database.read { db in
      (try ScheduledItem.fetchAll(db), try ScheduledOccurrence.fetchAll(db))
    }
    #expect(items.count == UpcomingSample.items.count)
    // Started two months before today (21 Oct 2026): in August.
    #expect(items.allSatisfy { $0.startDay.hasPrefix("2026-08") })
    let paid = occurrences.filter { $0.status == .paid }.count
    let missed = occurrences.filter { $0.status == .missed }.count
    #expect(paid >= 6)
    #expect(missed > 0)
    #expect(missed < 15)
  }
}
