import AbacusDomain
import Foundation

/// Keeps the in-memory `RateTable` filled from the cache (`RateStore`) and the network
/// (`OfficialRateSource`), R-FX-1/2/4:
///
/// - `start()` on launch: loads the cache, then refreshes when auto-refresh is on.
/// - `refreshIfDue()` / `runDailySchedule()`: once a day while auto-refresh is on.
/// - `refreshNow()`: "Refresh rates", always allowed; also fetches days left pending.
/// - `ensureRates(for:)`: lazy history for the days in use; only days the cache does not cover
///   are fetched, in as few ranges as possible. With auto-refresh off nothing goes to the
///   network: the days wait for the next `refreshNow()` (R-NF-1).
/// - A failed fetch keeps every known rate and sets `status.failure` until a fetch succeeds
///   (R-FX-4); automatic fetches (daily, lazy) then hold off for `retryAfter`, "Refresh rates"
///   does not. Storage is reached only through `RateStore`.
public actor RateRefresher {
  public struct Failure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
      /// No provider answered ("Couldn't reach the rate service").
      case network
      /// Rates were fetched but the cache could not be read or written.
      case storage
    }

    public var kind: Kind
    public var at: Date
    public var message: String
  }

  public struct Status: Sendable, Equatable {
    public var autoRefresh: Bool
    /// A fetch is running ("Refresh rates" is disabled meanwhile).
    public var isRefreshing = false
    /// When rates were last fetched successfully; after launch, the newest cached `fetchedAt`
    /// ("Updated today 09:00", R-FX-5).
    public var lastUpdate: Date?
    public var lastAttempt: Date?
    /// Set by a failed fetch, cleared by the next successful one (R-FX-4 warning).
    public var failure: Failure?
    /// Days in use whose rates are not fetched yet (auto-refresh off, or a failed fetch).
    public var pendingDays = 0
    /// The newest official day held ("rates as of", R-FX-4).
    public var latestDay: Day?
  }

  public struct Snapshot: Sendable, Equatable {
    public var table: RateTable
    public var status: Status
  }

  public private(set) var table: RateTable
  public private(set) var status: Status
  public var snapshot: Snapshot { Snapshot(table: table, status: status) }

  private let store: any RateStore
  private let source: any OfficialRateSource
  private let currencies: [Currency]
  private let calendar: Calendar
  private let now: @Sendable () -> Date
  private let latestWindow: Int
  private let gap: Int
  private let retryAfter: TimeInterval

  private var cacheLoaded = false
  private var stored: [StoredKey: UUID] = [:]
  private var fetchedThisSession: Set<Day> = []
  private var inFlightDays: Set<Day> = []
  private var pending: Set<Day> = []
  private var running = 0
  private var latestTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

  /// - Parameters:
  ///   - currencies: currencies to keep rates for (UAH is implied).
  ///   - autoRefresh: `SettingKey.ratesAutoRefresh`; change it later with `setAutoRefresh`.
  ///   - calendar: decides what "today" is (the user's calendar).
  ///   - latestWindow: days back fetched by each refresh, covering weekends and missed days.
  ///   - gap: longest run of days without rates treated as a weekend/holiday gap.
  ///   - retryAfter: seconds before the daily check retries after a failure.
  public init(
    store: any RateStore, source: any OfficialRateSource = FallbackRateSource.standard(),
    currencies: [Currency] = Currency.allCases, autoRefresh: Bool = true,
    calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
    latestWindow: Int = 7, gap: Int = 6, retryAfter: TimeInterval = 15 * 60
  ) {
    self.store = store
    self.source = source
    self.currencies = currencies.filter { $0 != AbacusFX.pivot }
    self.calendar = calendar
    self.now = now
    self.latestWindow = latestWindow
    self.gap = gap
    self.retryAfter = retryAfter
    self.table = RateTable(today: Day(now(), calendar: calendar))
    self.status = Status(autoRefresh: autoRefresh)
  }

  public var today: Day { Day(now(), calendar: calendar) }

  // MARK: Lifecycle

  /// On launch: loads the cache, then refreshes if auto-refresh is on.
  public func start() async {
    await loadCache()
    if status.autoRefresh { await refreshLatest(includePending: true) }
  }

  /// Reads every cached rate and override from the store. Safe to call again (reload).
  public func loadCache() async {
    do {
      let rates = try await store.rates(from: Day(year: 1900, month: 1, day: 1), to: Day(year: 9999, month: 12, day: 31))
      let overrides = try await store.overrides()
      table = RateTable(rates: rates, overrides: overrides, today: today)
      stored = Dictionary(rates.map { (StoredKey($0), $0.id) }) { a, _ in a }
      status.lastUpdate = rates.map(\.fetchedAt).max()
      cacheLoaded = true
    } catch {
      status.failure = Failure(kind: .storage, at: now(), message: "\(error)")
    }
    publish()
  }

  public func setAutoRefresh(_ on: Bool) {
    status.autoRefresh = on
    publish()
  }

  /// Whether the daily refresh should run now: auto-refresh on, no fetch today yet (or days
  /// pending), and no failure within `retryAfter`.
  public var isDue: Bool {
    guard status.autoRefresh, !recentlyFailed else { return false }
    guard let last = status.lastUpdate else { return true }
    return Day(last, calendar: calendar) < today || !pending.isEmpty
  }

  /// A network failure within `retryAfter`: automatic fetches hold off until then.
  private var recentlyFailed: Bool {
    guard let failure = status.failure, failure.kind == .network else { return false }
    return now().timeIntervalSince(failure.at) < retryAfter
  }

  /// The daily check. Returns whether a refresh ran.
  @discardableResult
  public func refreshIfDue() async -> Bool {
    if !cacheLoaded { await loadCache() }
    guard isDue else { return false }
    await refreshLatest(includePending: true)
    return true
  }

  /// "Refresh rates" (on demand): runs regardless of the auto-refresh flag.
  public func refreshNow() async {
    if !cacheLoaded { await loadCache() }
    await refreshLatest(includePending: true)
  }

  /// Checks `refreshIfDue()` every `interval` until the calling task is cancelled.
  public func runDailySchedule(checkEvery interval: Duration = .seconds(3600)) async {
    while !Task.isCancelled {
      do { try await Task.sleep(for: interval) } catch { return }
      await refreshIfDue()
    }
  }

  // MARK: Lazy history

  /// Makes sure rates for `days` are loaded, fetching only what the cache does not cover.
  /// With auto-refresh off the days are remembered for the next `refreshNow()`.
  public func ensureRates(for days: some Sequence<Day> & Sendable) async {
    if !cacheLoaded { await loadCache() }
    let missing = missingDays(days)
    guard !missing.isEmpty else { return }
    // Auto-refresh off, or the network failed moments ago: wait for the next refresh.
    guard status.autoRefresh, !recentlyFailed else {
      pending.formUnion(missing)
      status.pendingDays = pending.count
      publish()
      return
    }
    await fetch(days: missing)
  }

  /// Days among `days` that need a fetch: not after today, not in the cache or a
  /// weekend/holiday gap inside it, not fetched or being fetched this session.
  public func missingDays(_ days: some Sequence<Day> & Sendable) -> [Day] {
    let today = today
    return Set(days).filter { day in
      day <= today && !fetchedThisSession.contains(day) && !inFlightDays.contains(day)
        && !table.covers(day, gap: gap)
    }.sorted()
  }

  // MARK: Overrides (R-FX-2)

  public func saveOverride(_ override: FXOverride) async throws {
    try await store.save(override)
    var overrides = table.overrides.filter { $0.id != override.id }
    overrides.append(override)
    table.setOverrides(overrides)
    publish()
  }

  public func deleteOverride(_ id: FXOverride.ID) async throws {
    try await store.deleteOverride(id)
    table.setOverrides(table.overrides.filter { $0.id != id })
    publish()
  }

  // MARK: Observation

  /// Current snapshot first, then one per change.
  public func updates() -> AsyncStream<Snapshot> {
    let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    continuation.yield(snapshot)
    return stream
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }

  private func publish() {
    table.today = today
    status.latestDay = table.latestDay
    let snapshot = snapshot
    for continuation in continuations.values { continuation.yield(snapshot) }
  }

  // MARK: Fetching

  /// Latest days (plus pending ones), coalescing concurrent calls into one fetch.
  private func refreshLatest(includePending: Bool) async {
    if let task = latestTask {
      await task.value
      return
    }
    let task = Task { await self.performLatest(includePending: includePending) }
    latestTask = task
    await task.value
    latestTask = nil
  }

  private func performLatest(includePending: Bool) async {
    let today = today
    let windowStart = today.adding(days: -latestWindow, calendar: .fxDays)
    // The latest window is always fetched again (a refresh means "ask again"); older pending
    // days only while the cache still does not cover them.
    var older: [Day] = []
    if includePending {
      older = missingDays(pending.filter { $0 < windowStart })
      pending = pending.filter { $0 >= windowStart || older.contains($0) }
    }
    await fetch(days: HTTP.days(from: windowStart, to: today, calendar: .fxDays) + older)
  }

  private func fetch(days: [Day]) async {
    let today = today
    let wanted = Set(days.filter { $0 <= today }).subtracting(inFlightDays)
    guard !wanted.isEmpty else { return }
    inFlightDays.formUnion(wanted)
    running += 1
    status.isRefreshing = true
    publish()

    var failed = false
    for range in ranges(for: wanted.sorted(), today: today) {
      do {
        let rates = try await source.uahRates(for: currencies, from: range.lowerBound, to: range.upperBound)
        await persist(rates.filter { $0.day <= today.string })
        status.lastUpdate = now()
        let covered = Set(HTTP.days(from: range.lowerBound, to: range.upperBound, calendar: .fxDays))
        fetchedThisSession.formUnion(covered)
        pending.subtract(covered)
      } catch is CancellationError {
        failed = true
        pending.formUnion(wanted.filter { range.contains($0) })
      } catch {
        failed = true
        pending.formUnion(wanted.filter { range.contains($0) })
        status.failure = Failure(kind: .network, at: now(), message: "\(error)")
      }
    }

    inFlightDays.subtract(wanted)
    running -= 1
    status.isRefreshing = running > 0
    status.lastAttempt = now()
    if !failed {
      if status.failure?.kind == .network { status.failure = nil }
    }
    status.pendingDays = pending.count
    publish()
  }

  /// Sorted days → fetch ranges: days closer than `gap` share a range. A range whose first
  /// day has no known rate within `gap` days before it starts `gap` days early, so a weekend
  /// or holiday at its start still gets the preceding business day's rate.
  private func ranges(for days: [Day], today: Day) -> [ClosedRange<Day>] {
    var result: [ClosedRange<Day>] = []
    for day in days {
      if let last = result.last, day <= last.upperBound.adding(days: gap + 1, calendar: .fxDays) {
        result[result.count - 1] = last.lowerBound...max(last.upperBound, day)
      } else {
        result.append(day...day)
      }
    }
    return result.map { range in
      let padded = range.lowerBound.adding(days: -gap, calendar: .fxDays)
      let start = table.hasOfficialDay(from: padded, before: range.lowerBound) ? range.lowerBound : padded
      return start...min(range.upperBound, today)
    }
  }

  /// Saves fetched rates stamped with the refresher's clock (re-using the id of a cached row
  /// with the same key, so the store updates instead of duplicating) and merges them into the
  /// table.
  private func persist(_ rates: [FXRate]) async {
    guard !rates.isEmpty else { return }
    let fetchedAt = now()
    let rows = rates.map { rate in
      FXRate(
        id: stored[StoredKey(rate)] ?? rate.id, day: rate.day, base: rate.base, quote: rate.quote,
        rateE8: rate.rateE8, provider: rate.provider, fetchedAt: fetchedAt)
    }
    table.merge(rows)
    do {
      try await store.save(rows)
      for row in rows { stored[StoredKey(row)] = row.id }
      if status.failure?.kind == .storage { status.failure = nil }
    } catch {
      status.failure = Failure(kind: .storage, at: now(), message: "\(error)")
    }
  }

  private struct StoredKey: Hashable {
    var day: String
    var base: Currency
    var quote: Currency
    var provider: String

    init(_ rate: FXRate) {
      day = rate.day
      base = rate.base
      quote = rate.quote
      provider = rate.provider
    }
  }
}
