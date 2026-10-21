import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusImport
import AbacusStore
import AbacusTestSupport
import Foundation
import Testing

/// The owner's real exports, imported into an in-memory database the way the app gets them, then
/// every screen's model loaded through `AppSession.live` — the same code the app runs. Skipped
/// when the files are missing; prints counts, timings and failure flags only, never names,
/// amounts or descriptions (R-NF-6). Rates come from a stub (no network in tests).
@MainActor
@Suite(
  "App session on the real exports", .tags(.realData),
  .enabled(if: RealSamples.has(prefix: "saldo") && RealSamples.has(prefix: "pko")))
struct RealDataAppSessionTests {
  /// Synthetic constant UAH rates for every day the exports span.
  static func syntheticRates(from: Day, to: Day) -> [FXRate] {
    var rates: [FXRate] = []
    var day = from
    let perUAH: [(Currency, String)] = [(.PLN, "11.30"), (.EUR, "48.50"), (.USD, "41.60")]
    while day <= to {
      for (currency, rate) in perUAH {
        rates.append(FXRate(day: day.string, base: currency, quote: .UAH, rateE8: RateScale.scaled(Decimal(string: rate)!), provider: "NBU"))
      }
      day = day.adding(days: 1)
    }
    return rates
  }

  func failed(_ phase: ManagePhase) -> Bool {
    if case .failed = phase { return true }
    return false
  }

  @Test("R-NF-2, R-HOME-1…5, R-LIST-1, R-MGMT-1…6: every screen loads the real data without errors")
  func everyScreenLoads() async throws {
    let database = try AbacusDatabase.open(at: nil)
    let calendar = Calendar.current
    let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
    let pipeline = ImportPipeline(
      store: SQLiteImportStore(database: database, calendar: calendar), accounts: accounts,
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database), calendar: calendar)

    let saldo = try Data(contentsOf: try #require(RealSamples.file(prefix: "saldo")))
    _ = try await pipeline.commit(try await pipeline.preview(data: saldo, fileName: "saldo.csv").acceptingDefaults())
    let pko = try Data(contentsOf: try #require(RealSamples.file(prefix: "pko")))
    let target = try #require(try await accounts.accounts(includeArchived: true).first { $0.name == "PKO private" && $0.currency == .PLN })
    _ = try await pipeline.commit(try await pipeline.preview(data: pko, fileName: "pko.csv", targetAccountID: target.id).acceptingDefaults())

    let today = Day(Date(), calendar: calendar)
    let source = StubSource(rates: Self.syntheticRates(from: Day("2024-05-01")!, to: today))
    let session = AppSession.live(database: database, source: source, calendar: calendar)
    let clock = ContinuousClock()

    var start = clock.now
    await session.start()
    await session.waitForLaunchFetch()
    print("Real app session: start + launch fetch \(clock.now - start)")

    start = clock.now
    await session.dashboard.load()
    let dashboardTime = clock.now - start
    #expect(session.dashboard.phase == .loaded)
    print("Real dashboard: loaded \(session.dashboard.phase == .loaded) in \(dashboardTime)")

    start = clock.now
    await session.transactions.load()
    let listTime = clock.now - start
    #expect(session.transactions.errorMessage == nil)
    let totals = session.transactions.content.totals
    print("Real transactions (default last 30 days): \(totals.count) rows, \(session.transactions.content.days.count) days, unconverted buckets \(totals.unconverted), in \(listTime)")
    #expect(totals.count > 0)

    for (name, load, phase) in [
      ("accounts", { await session.accounts.load() }, { session.accounts.phase }),
      ("categories", { await session.categories.load() }, { session.categories.phase }),
      ("budget", { await session.budget.load() }, { session.budget.phase }),
      ("events", { await session.events.load() }, { session.events.phase }),
      ("rules", { await session.rules.load() }, { session.rules.phase }),
    ] as [(String, () async -> Void, () -> ManagePhase)] {
      start = clock.now
      await load()
      let time = clock.now - start
      #expect(!failed(phase()), "\(name) failed to load")
      print("Real \(name): failed \(failed(phase())) in \(time)")
    }
    session.stop()
  }
}
