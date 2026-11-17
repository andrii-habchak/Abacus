import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData

/// What the Forecast tab reads and writes (R-REC-13…20).
///
/// Wiring (orchestrator): `live(database:refresher:)` on the store and the `RateRefresher`, the
/// same way `DashboardDependencies.live` is built; tests build it over an in-memory database.
public struct ForecastDependencies: Sendable {
  /// Every account, archived ones too (debt-linked accounts are recognised through `debts`).
  public var accounts: @Sendable () async throws -> [Account]
  /// End-of-day balances of every account (archived ones too) on `days` (R-ACC-3).
  public var balances: @Sendable ([Day]) async throws -> BalanceSeries
  public var items: any ScheduledItemRepository
  public var occurrences: any ScheduledOccurrenceRepository
  /// Past forecasts for "Compare with a past forecast" (R-REC-19); nil hides the picker.
  public var snapshots: (any ForecastSnapshotRepository)?
  /// Debts counted in net worth (R-REC-13, R-DEBT-7); nil = no debts.
  public var debts: (any DebtRepository)?
  public var settings: (any SettingsRepository)?
  /// The rates in memory now; nil before the first load (only same-currency values then).
  public var rates: @Sendable () async -> (any CurrencyConverter)?
  public var today: @Sendable () -> Day
  public var format: DashboardFormat

  public init(
    accounts: @escaping @Sendable () async throws -> [Account],
    balances: @escaping @Sendable ([Day]) async throws -> BalanceSeries,
    items: any ScheduledItemRepository, occurrences: any ScheduledOccurrenceRepository,
    snapshots: (any ForecastSnapshotRepository)? = nil, debts: (any DebtRepository)? = nil,
    settings: (any SettingsRepository)? = nil,
    rates: @escaping @Sendable () async -> (any CurrencyConverter)?,
    today: @escaping @Sendable () -> Day = { Day(Date()) }, format: DashboardFormat = DashboardFormat()
  ) {
    self.accounts = accounts
    self.balances = balances
    self.items = items
    self.occurrences = occurrences
    self.snapshots = snapshots
    self.debts = debts
    self.settings = settings
    self.rates = rates
    self.today = today
    self.format = format
  }
}

extension ForecastDependencies {
  /// The app database and the rate refresher.
  public static func live(
    database: any DatabaseWriter, refresher: RateRefresher?, format: DashboardFormat = DashboardFormat()
  ) -> ForecastDependencies {
    ForecastDependencies.database(database, rates: { await refresher?.snapshot.table }, format: format)
  }

  /// Over a database with a fixed rate source (tests, the DEBUG preview host).
  public static func database(
    _ database: any DatabaseWriter, rates: @escaping @Sendable () async -> (any CurrencyConverter)?,
    today: (@Sendable () -> Day)? = nil, format: DashboardFormat = DashboardFormat()
  ) -> ForecastDependencies {
    let calendar = format.calendar
    let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
    let reports = SQLiteReportQueries(database: database, calendar: calendar)
    let scheduled = SQLiteScheduledStore(database: database, calendar: calendar)
    return ForecastDependencies(
      accounts: { try await accounts.accounts(includeArchived: true) },
      balances: { days in try await reports.balances(on: days, includeArchived: true) },
      items: scheduled, occurrences: scheduled,
      snapshots: SQLiteForecastSnapshotRepository(database: database, calendar: calendar),
      debts: SQLiteDebtRepository(database: database, calendar: calendar),
      settings: SQLiteSettingsRepository(database: database), rates: rates,
      today: today ?? { Day(Date(), calendar: calendar) }, format: format)
  }
}
