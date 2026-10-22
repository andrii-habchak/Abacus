import AbacusDomain
import AbacusFeatures
import Foundation

/// Synthetic fixtures for the B1 tests (shell, rates, settings).
enum B1Fixture {
  static let today = Day(year: 2026, month: 10, day: 21)

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }

  static let formats = Formats(locale: Locale(identifier: "en_GB"), calendar: calendar)

  /// 2026-10-21 at `hour:minute` in the current time zone.
  static func at(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  static func rate(_ day: String, _ base: Currency, _ value: String) -> FXRate {
    FXRate(day: day, base: base, quote: .UAH, rateE8: RateScale.scaled(Decimal(string: value)!), provider: "NBU")
  }

  /// Fri 16, Mon 19 and Tue 20 Oct; nothing for "today" (Wed 21) yet.
  static let rates: [FXRate] = [
    rate("2026-10-16", .EUR, "48.00"), rate("2026-10-16", .PLN, "11.00"), rate("2026-10-16", .USD, "41.00"),
    rate("2026-10-19", .EUR, "48.40"), rate("2026-10-19", .PLN, "11.20"), rate("2026-10-19", .USD, "41.50"),
    rate("2026-10-20", .EUR, "48.50"), rate("2026-10-20", .PLN, "11.30"), rate("2026-10-20", .USD, "41.60"),
  ]

  static func override(
    _ base: Currency, _ quote: Currency, _ value: String, from: String, until: String? = nil, note: String = ""
  ) -> FXOverride {
    FXOverride(
      base: base, quote: quote, rateE8: RateScale.scaled(Decimal(string: value)!), fromDay: from,
      untilDay: until, note: note)
  }

  struct Setup {
    let environment: AppEnvironment
    let settings: InMemorySettingsRepository
    let store: InMemoryRateStore
    let service: PreviewRatesService
    let backup: PreviewBackupService
    let location: PreviewDataLocationService
  }

  static func setup(
    settings: [SettingKey: String] = [:], overrides: [FXOverride] = [], offline: Bool = false,
    lastUpdate: Date? = at(9), now: Date = at(15), backupFailure: DataServiceError? = nil,
    legacyLastExport: LegacyLastExport = .none
  ) -> Setup {
    let settingsRepo = InMemorySettingsRepository(settings)
    let store = InMemoryRateStore(rates: rates, overrides: overrides)
    let service = PreviewRatesService(
      store: store, status: RatesStatus(autoRefresh: true, lastUpdate: lastUpdate), offline: offline,
      now: { now })
    let backup = PreviewBackupService(failure: backupFailure)
    let location = PreviewDataLocationService(
      url: URL(filePath: "/Users/someone/Library/Application Support/Abacus/abacus.sqlite"))
    let environment = AppEnvironment(
      settings: settingsRepo, rateStore: store, rates: service, backup: backup, dataLocation: location,
      legacyLastExport: legacyLastExport, today: { today }, now: { now }, formats: formats)
    return Setup(
      environment: environment, settings: settingsRepo, store: store, service: service, backup: backup,
      location: location)
  }
}
