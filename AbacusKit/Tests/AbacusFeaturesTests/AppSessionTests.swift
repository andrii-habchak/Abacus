import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

@MainActor
@Suite("Live session over the app database (B1)")
struct AppSessionTests {
  func session(_ database: any DatabaseWriter, rates: [FXRate]? = nil) -> AppSession {
    AppSession.live(
      database: database, source: StubSource(rates: rates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
  }

  @Test("Sample data goes only into a database without accounts")
  func sampleDataOnlyWhenEmpty() async throws {
    let database = try AbacusDatabase.open(at: nil)
    #expect(try await SampleData.loadIfEmpty(into: database))
    #expect(try await SampleData.loadIfEmpty(into: database) == false)
    let (accounts, txns) = try await database.read { db in (try Account.fetchCount(db), try Txn.fetchCount(db)) }
    #expect(accounts == PreviewData.accounts.count)
    #expect(txns == PreviewData.txns.count)
  }

  @Test("Load Sample Data fills the screens; a second time it explains why not")
  func loadSampleData() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    await s.loadSampleData()
    #expect(s.sampleDataMessage?.hasPrefix("Sample data loaded") == true)
    #expect(s.dashboard.phase == .loaded)
    #expect(s.transactions.reference.accounts.count == PreviewData.accounts.count)
    await s.loadSampleData()
    #expect(s.sampleDataMessage?.hasPrefix("Abacus already has accounts") == true)
  }

  @Test("R-HOME-4 the display currency is stored in the app database")
  func displayCurrencyInDatabase() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let first = session(database)
    await first.start()
    await first.app.setDisplayCurrency(.USD).value
    first.stop()
    let second = session(database)
    await second.start()
    defer { second.stop() }
    #expect(second.app.displayCurrency == .USD)
    #expect(second.transactions.displayCurrency == .USD)
  }

  @Test("R-SET-3 changing the refunds setting reaches the transaction list")
  func refundsReachList() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    await s.app.setRefundsReduceSpending(true).value
    #expect(s.transactions.refundsReduceSpending)
    #expect(try await SQLiteSettingsRepository(database: database).value(.refundsReduceSpending) == "true")
  }

  @Test("R-FX-1 on launch the refresher fetches; the rates screen shows the stored rates")
  func launchFetch() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let fetched = [B1Fixture.rate("2026-10-21", .EUR, "48.80"), B1Fixture.rate("2026-10-21", .USD, "41.70")]
    let s = session(database, rates: fetched)
    await s.start()
    defer { s.stop() }
    await s.waitForLaunchFetch()
    await s.app.rates.load()
    let latest = try await SQLiteRateStore(database: database).latestRates()
    #expect(s.app.rates.rows.first { $0.currency == .EUR }?.rateText == "1 EUR = 48.8000 UAH")
    #expect(s.app.ratesAsOfLabel == "NBU rates · 21 Oct 2026")
    #expect(latest.count == 2)
  }

  @Test("R-FX-4 an unreachable rate service shows the offline banner on the live screen")
  func launchOffline() async throws {
    let database = try AbacusDatabase.open(at: nil)
    try await SQLiteRateStore(database: database).save(B1Fixture.rates)
    let s = session(database, rates: nil)
    await s.start()
    defer { s.stop() }
    await s.waitForLaunchFetch()
    await s.app.rates.load()
    #expect(s.app.rates.offlineMessage == "Couldn't reach the rate service. Amounts use the last known rates, from 20 Oct 2026.")
  }

  @Test("R-SET-2 restore through the live store reloads every screen")
  func restoreReloads() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "b1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let backupFile = folder.appending(path: "abacus-backup.abacus")

    // A backup with the sample data.
    let source = try AbacusDatabase.open(at: nil)
    _ = try await SampleData.loadIfEmpty(into: source)
    try await SQLiteBackup(database: source).export(to: backupFile)

    // An empty app restores it.
    let database = try AbacusDatabase.open(at: nil)
    let s = session(database)
    await s.start()
    defer { s.stop() }
    #expect(s.transactions.reference.accounts.isEmpty)
    s.app.data.askRestore(from: backupFile)
    await s.app.data.confirmRestore()
    #expect(s.app.data.messageIsError == false)
    #expect(s.transactions.reference.accounts.count == PreviewData.accounts.count)
  }
}
