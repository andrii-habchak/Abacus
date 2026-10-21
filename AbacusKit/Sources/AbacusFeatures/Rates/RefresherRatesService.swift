import AbacusDomain
import AbacusFX
import Foundation

/// `RatesService` over the real `RateRefresher` (WP A2): what the app uses once wired.
/// Overrides go through the refresher so its in-memory table (the app's converter) updates too.
public struct RefresherRatesService: RatesService {
  public let refresher: RateRefresher

  public init(refresher: RateRefresher) {
    self.refresher = refresher
  }

  public func status() async -> RatesStatus {
    let status = await refresher.status
    return RatesStatus(
      autoRefresh: status.autoRefresh, isRefreshing: status.isRefreshing, lastUpdate: status.lastUpdate,
      latestDay: status.latestDay, failedAt: status.failure?.at)
  }

  public func refreshNow() async { await refresher.refreshNow() }

  public func setAutoRefresh(_ on: Bool) async { await refresher.setAutoRefresh(on) }

  public func saveOverride(_ override: FXOverride) async throws { try await refresher.saveOverride(override) }

  public func deleteOverride(_ id: FXOverride.ID) async throws { try await refresher.deleteOverride(id) }
}
