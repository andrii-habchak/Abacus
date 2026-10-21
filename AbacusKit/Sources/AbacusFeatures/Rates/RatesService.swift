import AbacusDomain
import Foundation

/// What the UI needs to know about rate fetching (R-FX-1, R-FX-4, R-FX-5).
public struct RatesStatus: Hashable, Sendable {
  /// "Update rates automatically" (Settings › Rates).
  public var autoRefresh: Bool
  /// A fetch is running ("Refresh rates" is disabled meanwhile).
  public var isRefreshing: Bool
  /// When rates were last fetched successfully ("Updated today 09:00").
  public var lastUpdate: Date?
  /// The newest official day held ("NBU rates · 21 Oct 2026", "rates as of", R-FX-4).
  public var latestDay: Day?
  /// Set by a failed fetch, cleared by the next successful one (the offline banner).
  public var failedAt: Date?

  public init(
    autoRefresh: Bool = true, isRefreshing: Bool = false, lastUpdate: Date? = nil,
    latestDay: Day? = nil, failedAt: Date? = nil
  ) {
    self.autoRefresh = autoRefresh
    self.isRefreshing = isRefreshing
    self.lastUpdate = lastUpdate
    self.latestDay = latestDay
    self.failedAt = failedAt
  }

  public var isOffline: Bool { failedAt != nil }
}

/// Fetching and manual overrides, as the rates screen and settings use them. The real
/// implementation adapts WP A2's `RateRefresher` (`status`, `refreshNow()`, `setAutoRefresh`,
/// `saveOverride`, `deleteOverride`); overrides go through it so its in-memory table updates.
public protocol RatesService: Sendable {
  func status() async -> RatesStatus
  /// "Refresh rates" / "Try again": always fetches, whatever the auto-refresh flag says.
  func refreshNow() async
  func setAutoRefresh(_ on: Bool) async
  func saveOverride(_ override: FXOverride) async throws
  func deleteOverride(_ id: FXOverride.ID) async throws
}

/// `RateStore` in memory (previews, tests).
public actor InMemoryRateStore: RateStore {
  public private(set) var fetched: [FXRate]
  public private(set) var manual: [FXOverride]

  public init(rates: [FXRate] = [], overrides: [FXOverride] = []) {
    fetched = rates
    manual = overrides
  }

  public func rates(from: Day, to: Day) async throws -> [FXRate] {
    fetched.filter { $0.day >= from.string && $0.day <= to.string }
  }

  public func latestRates() async throws -> [FXRate] {
    guard let day = fetched.map(\.day).max() else { return [] }
    return fetched.filter { $0.day == day }
  }

  public func save(_ rates: [FXRate]) async throws {
    for rate in rates {
      fetched.removeAll { $0.id == rate.id || ($0.day == rate.day && $0.base == rate.base && $0.quote == rate.quote) }
      fetched.append(rate)
    }
  }

  public func overrides() async throws -> [FXOverride] { manual }

  public func save(_ override: FXOverride) async throws {
    manual.removeAll { $0.id == override.id }
    manual.append(override)
  }

  public func deleteOverride(_ id: FXOverride.ID) async throws {
    manual.removeAll { $0.id == id }
  }
}

/// A `RatesService` over a `RateStore` that simulates fetching: a refresh either "succeeds"
/// (stamps `lastUpdate`) or fails (sets `failedAt`, keeps every rate), after `delay`.
public actor PreviewRatesService: RatesService {
  private let store: any RateStore
  private var current: RatesStatus
  private let delay: Duration
  private let now: @Sendable () -> Date
  /// When true, every refresh fails as if the network were down.
  public var isOffline: Bool
  public private(set) var refreshCount = 0

  public init(
    store: any RateStore, status: RatesStatus, offline: Bool = false, delay: Duration = .zero,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.current = status
    self.isOffline = offline
    self.delay = delay
    self.now = now
    if offline, current.failedAt == nil { current.failedAt = now() }
  }

  public func setOffline(_ offline: Bool) { isOffline = offline }

  public func status() async -> RatesStatus {
    var status = current
    if let latest = try? await store.latestRates().first.flatMap({ Day($0.day) }) {
      status.latestDay = latest
    }
    return status
  }

  public func refreshNow() async {
    refreshCount += 1
    current.isRefreshing = true
    if delay > .zero { try? await Task.sleep(for: delay) }
    current.isRefreshing = false
    if isOffline {
      current.failedAt = now()
    } else {
      current.failedAt = nil
      current.lastUpdate = now()
    }
  }

  public func setAutoRefresh(_ on: Bool) async { current.autoRefresh = on }

  public func saveOverride(_ override: FXOverride) async throws { try await store.save(override) }

  public func deleteOverride(_ id: FXOverride.ID) async throws { try await store.deleteOverride(id) }
}
