import AbacusDomain
import Foundation

/// The services the shell, the rates screen and the Settings window run on. The app builds one
/// at launch; until the store (A5) and FX (A2) packages are wired it uses `preview()`.
///
/// Wiring (orchestrator): `settings` = `SQLiteSettingsRepository`, `rateStore` =
/// `SQLiteRateStore`, `rates` = an adapter over `RateRefresher`, `backup` = `SQLiteBackup`,
/// `dataLocation` = the database location, `today` = `{ Day(Date()) }`.
public struct AppEnvironment: Sendable {
  public var settings: any SettingsRepository
  public var rateStore: any RateStore
  public var rates: any RatesService
  public var backup: any BackupService
  public var dataLocation: any DataLocationService
  /// A last-export date still in `UserDefaults` from before it moved into the database.
  public var legacyLastExport: LegacyLastExport
  public var today: @Sendable () -> Day
  public var now: @Sendable () -> Date
  public var formats: Formats

  public init(
    settings: any SettingsRepository, rateStore: any RateStore, rates: any RatesService,
    backup: any BackupService, dataLocation: any DataLocationService,
    legacyLastExport: LegacyLastExport = .none,
    today: @escaping @Sendable () -> Day = { Day(Date()) },
    now: @escaping @Sendable () -> Date = { Date() }, formats: Formats = Formats()
  ) {
    self.settings = settings
    self.rateStore = rateStore
    self.rates = rates
    self.backup = backup
    self.dataLocation = dataLocation
    self.legacyLastExport = legacyLastExport
    self.today = today
    self.now = now
    self.formats = formats
  }

  /// Synthetic data in memory (previews, the app before wiring). `offline` starts with a failed
  /// fetch and yesterday's rates as the last known ones (the amber banner).
  public static func preview(offline: Bool = false, refreshDelay: Duration = .milliseconds(900))
    -> AppEnvironment
  {
    let rates = offline ? PreviewRates.fxRates.filter { $0.day < PreviewRates.today.string } : PreviewRates.fxRates
    let store = InMemoryRateStore(rates: rates, overrides: PreviewRates.overrides)
    let lastUpdate = offline ? PreviewRates.lastUpdate.addingTimeInterval(-86_400) : PreviewRates.lastUpdate
    let service = PreviewRatesService(
      store: store,
      status: RatesStatus(autoRefresh: true, lastUpdate: lastUpdate),
      offline: offline, delay: refreshDelay)
    var settings: [SettingKey: String] = [.lastBackupExport: "2026-10-14"]
    for setting in PreviewData.settings {
      if let key = SettingKey(rawValue: setting.id) { settings[key] = setting.value }
    }
    return AppEnvironment(
      settings: InMemorySettingsRepository(settings), rateStore: store, rates: service,
      backup: PreviewBackupService(), dataLocation: PreviewDataLocationService(),
      today: { PreviewData.today })
  }
}
