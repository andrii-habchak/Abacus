import AbacusDomain
import Foundation
import Testing

@testable import AbacusFX

/// Today in these tests: Tuesday 2024-01-16, 10:00 UTC.
private struct Harness {
  let clock = TestClock(at("2024-01-16 10:00"))
  let store: InMemoryRateStore
  let source: ScriptedSource
  let refresher: RateRefresher

  init(
    cached: [FXRate] = [], overrides: [FXOverride] = [],
    published: [FXRate] = businessDays(from: d("2023-11-01"), to: d("2024-01-17")),
    autoRefresh: Bool = true
  ) {
    store = InMemoryRateStore(rates: cached, overrides: overrides)
    source = ScriptedSource(published)
    refresher = RateRefresher(
      store: store, source: source, autoRefresh: autoRefresh, calendar: utc, now: clock.closure)
  }
}

@Suite("RateRefresher (R-FX-1, R-FX-4, R-NF-1)")
struct RateRefresherTests {
  @Test("R-FX-1: launch with auto-refresh loads the latest rates and caches them")
  func launch() async throws {
    let h = Harness()
    await h.refresher.start()
    let status = await h.refresher.status
    let table = await h.refresher.table
    #expect(h.source.calls.count == 1)
    #expect(table.latestDay == d("2024-01-16"))
    #expect(status.latestDay == d("2024-01-16"))
    #expect(status.lastUpdate == at("2024-01-16 10:00"))
    #expect(status.failure == nil)
    #expect(status.isRefreshing == false)
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-13")) != nil)  // weekend in range
    let stored = await h.store.rows.values.map(\.day)
    #expect(stored.contains("2024-01-16"))
    // Rates published for tomorrow are not taken yet.
    #expect(!stored.contains("2024-01-17"))
  }

  @Test("R-NF-1: auto-refresh off → no network on launch or for lazy days; Refresh rates still works")
  func autoRefreshOff() async throws {
    let cached = businessDays(from: d("2024-01-08"), to: d("2024-01-12"))
    let h = Harness(cached: cached, autoRefresh: false)
    await h.refresher.start()
    #expect(h.source.calls.isEmpty)
    #expect(await h.refresher.table.latestDay == d("2024-01-12"))  // works offline from cache
    #expect(await h.refresher.refreshIfDue() == false)

    await h.refresher.ensureRates(for: [d("2023-12-05")])
    #expect(h.source.calls.isEmpty)
    #expect(await h.refresher.status.pendingDays == 1)

    await h.refresher.refreshNow()
    #expect(h.source.calls.count == 2)  // latest window + the pending day
    #expect(await h.refresher.status.pendingDays == 0)
    #expect(await h.refresher.table.rate(from: .EUR, to: .UAH, on: d("2023-12-05")) != nil)
    #expect(await h.refresher.table.latestDay == d("2024-01-16"))
  }

  @Test("R-FX-4: a failed fetch keeps the last known rates and exposes the failure until a retry succeeds")
  func failureKeepsLastKnown() async throws {
    let cached = businessDays(from: d("2024-01-08"), to: d("2024-01-12"))
    let h = Harness(cached: cached)
    h.source.setFailing(true)
    await h.refresher.start()

    let failed = await h.refresher.snapshot
    #expect(failed.status.failure?.kind == .network)
    #expect(failed.status.failure?.message.contains("offline") == true)
    #expect(failed.status.lastUpdate == cached.map(\.fetchedAt).max())
    #expect(failed.status.latestDay == d("2024-01-12"))  // "Amounts use the last known rates, from …"
    #expect(failed.table.latestRate(from: .EUR, to: .UAH) == failed.table.rate(from: .EUR, to: .UAH, on: d("2024-01-12")))
    #expect(failed.table.convertAtLatest(Money(minorUnits: 100, currency: .EUR), to: .UAH) != nil)

    // The daily check waits `retryAfter` (15 min) before trying again.
    h.source.setFailing(false)
    h.clock.advance(hours: 0.1)
    #expect(await h.refresher.refreshIfDue() == false)
    h.clock.advance(hours: 0.5)
    #expect(await h.refresher.refreshIfDue() == true)
    let recovered = await h.refresher.status
    #expect(recovered.failure == nil)
    #expect(recovered.latestDay == d("2024-01-16"))
  }

  @Test("R-FX-1: daily refresh runs once per day while auto-refresh is on")
  func daily() async throws {
    let h = Harness()
    await h.refresher.start()
    h.clock.set(at("2024-01-16 18:00"))
    #expect(await h.refresher.refreshIfDue() == false)
    h.clock.set(at("2024-01-17 08:00"))
    #expect(await h.refresher.refreshIfDue() == true)
    #expect(h.source.calls.count == 2)
    #expect(await h.refresher.table.latestDay == d("2024-01-17"))
    await h.refresher.setAutoRefresh(false)
    h.clock.set(at("2024-01-18 08:00"))
    #expect(await h.refresher.refreshIfDue() == false)
    #expect(h.source.calls.count == 2)
  }

  @Test("R-FX-1: lazy history fetches only uncovered days, once, in merged ranges")
  func lazyHistory() async throws {
    let h = Harness()
    await h.refresher.start()
    #expect(h.source.calls.count == 1)

    // Covered already: a day in the latest window and a weekend inside it.
    await h.refresher.ensureRates(for: [d("2024-01-12"), d("2024-01-13")])
    #expect(h.source.calls.count == 1)

    // Three close days → one range, started early so Friday covers the Saturday.
    await h.refresher.ensureRates(for: [d("2023-12-02"), d("2023-12-05"), d("2023-12-08")])
    #expect(h.source.calls.count == 2)
    #expect(h.source.calls.last == d("2023-11-26")...d("2023-12-08"))
    let table = await h.refresher.table
    #expect(table.quote(from: .PLN, to: .UAH, on: d("2023-12-02"))?.day == d("2023-12-01"))

    // Asking again costs nothing; nor does a weekend between fetched days in a new session.
    await h.refresher.ensureRates(for: [d("2023-12-02"), d("2023-12-05")])
    #expect(h.source.calls.count == 2)
    let next = RateRefresher(store: h.store, source: h.source, calendar: utc, now: h.clock.closure)
    await next.ensureRates(for: [d("2023-12-03"), d("2023-12-02"), d("2023-12-06")])
    #expect(h.source.calls.count == 2)
    // Future days are never fetched.
    await next.ensureRates(for: [d("2024-02-01")])
    #expect(h.source.calls.count == 2)
  }

  @Test("R-FX-1: repeated refreshes update cached rows instead of duplicating them")
  func noDuplicateRows() async throws {
    let h = Harness()
    await h.refresher.start()
    let count = await h.store.rows.count
    h.clock.advance(hours: 1)
    await h.refresher.refreshNow()
    #expect(await h.store.rows.count == count)
    #expect(await h.refresher.status.failure == nil)
    // A new session over the same cache too.
    let next = RateRefresher(store: h.store, source: h.source, calendar: utc, now: h.clock.closure)
    await next.start()
    #expect(await h.store.rows.count == count)
    #expect(await next.status.failure == nil)
    #expect(await next.status.lastUpdate == at("2024-01-16 11:00"))
  }

  @Test("R-FX-4: a cache write failure is reported but the fetched rates are used")
  func storageFailure() async throws {
    let h = Harness()
    await h.store.setFailSaves(true)
    await h.refresher.start()
    let snapshot = await h.refresher.snapshot
    #expect(snapshot.status.failure?.kind == .storage)
    #expect(snapshot.table.latestDay == d("2024-01-16"))
  }

  @Test("R-FX-2: overrides are saved and removed through the store and apply at once")
  func overrides() async throws {
    let h = Harness()
    await h.refresher.start()
    let manual = FXOverride.from(d("2024-01-15"), base: .EUR, quote: .UAH, rate: 40)
    try await h.refresher.saveOverride(manual)
    #expect(await h.store.overrideRows[manual.id] == manual)
    #expect(await h.refresher.table.rate(from: .EUR, to: .UAH, on: d("2024-01-16")) == 40)

    let reloaded = RateRefresher(store: h.store, source: h.source, autoRefresh: false, calendar: utc, now: h.clock.closure)
    await reloaded.start()
    #expect(await reloaded.table.latestRate(from: .EUR, to: .UAH) == 40)

    try await h.refresher.deleteOverride(manual.id)
    #expect(await h.store.overrideRows.isEmpty)
    #expect(await h.refresher.table.rate(from: .EUR, to: .UAH, on: d("2024-01-16")) != 40)
  }

  @Test("R-FX-4: observers get the current snapshot, then updates")
  func updates() async throws {
    let h = Harness()
    let stream = await h.refresher.updates()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.status.latestDay == nil)
    await h.refresher.start()
    var last: RateRefresher.Snapshot?
    // bufferingNewest(1): the latest state is always delivered.
    last = await iterator.next()
    #expect(last?.status.latestDay == d("2024-01-16"))
    #expect(last?.status.isRefreshing == false)
  }

  @Test("R-FX-1: end to end over HTTP stubs — Frankfurter down, NBU fallback day by day")
  func endToEndFallback() async throws {
    let network = StubNetwork()
    network.fail(host: Fixtures.Frankfurter.host)
    network.route { url in
      guard url.host == Fixtures.NBU.host, let date = url.queryValue("date"), date.count == 8 else { return nil }
      let day = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
      return .success((200, Fixtures.NBU.day(day, usd: "37.5", eur: "41.25", pln: "9.5")))
    }
    let clock = TestClock(at("2024-01-16 10:00"))
    let store = InMemoryRateStore(rates: businessDays(from: d("2024-01-01"), to: d("2024-01-05")))
    let refresher = RateRefresher(
      store: store, source: FallbackRateSource.standard(session: network.session), calendar: utc,
      now: clock.closure)
    await refresher.start()
    let snapshot = await refresher.snapshot
    #expect(snapshot.status.failure == nil)
    #expect(network.requests(host: Fixtures.NBU.host).count == 8)  // 2024-01-09 … 2024-01-16
    #expect(snapshot.table.rate(from: .EUR, to: .USD, on: d("2024-01-16")) == Decimal(string: "41.25")! / Decimal(string: "37.5")!)
    #expect(snapshot.table.quote(from: .EUR, to: .UAH, on: d("2024-01-14"))?.source == .official(provider: "NBU"))
  }
}
