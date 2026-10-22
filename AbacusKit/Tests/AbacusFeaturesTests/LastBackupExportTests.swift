import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

@MainActor
@Suite("Last backup export in the database (C2)")
struct LastBackupExportTests {
  @Test("R-SET-2 the last export day is read from SettingKey.lastBackupExport")
  func readsSetting() async {
    let setup = B1Fixture.setup(settings: [.lastBackupExport: "2026-10-14"])
    let data = DataSettingsModel(environment: setup.environment)
    await data.load()
    #expect(data.lastExport == Day(year: 2026, month: 10, day: 14))
    #expect(data.backupNote.hasSuffix("Last export: 14 Oct 2026."))
  }

  @Test("R-SET-2 a date left in UserDefaults moves into the database once")
  func migratesLegacyValue() async {
    let legacy = LegacyLastExport.inMemory(B1Fixture.at(20, day: 12))
    let setup = B1Fixture.setup(legacyLastExport: legacy)
    let data = DataSettingsModel(environment: setup.environment)
    await data.load()
    #expect(data.lastExport == Day(year: 2026, month: 10, day: 12))
    #expect(await setup.settings.values[.lastBackupExport] == "2026-10-12")
    #expect(legacy.load() == nil)
    // A second launch reads the database only.
    await data.load()
    #expect(data.lastExport == Day(year: 2026, month: 10, day: 12))
    #expect(await setup.settings.writes == 1)
  }

  @Test("R-SET-2 a value already in the database wins over a stale UserDefaults one")
  func databaseWins() async {
    let legacy = LegacyLastExport.inMemory(B1Fixture.at(20, day: 2))
    let setup = B1Fixture.setup(settings: [.lastBackupExport: "2026-10-14"], legacyLastExport: legacy)
    let data = DataSettingsModel(environment: setup.environment)
    await data.load()
    #expect(data.lastExport == Day(year: 2026, month: 10, day: 14))
    #expect(legacy.load() == nil)
    #expect(await setup.settings.writes == 0)
  }

  @Test("R-SET-2 UserDefaults migration reads and removes the old key")
  func userDefaultsMigration() async throws {
    let suite = "abacus-c2-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(B1Fixture.at(9, day: 3), forKey: LegacyLastExport.defaultsKey)
    let setup = B1Fixture.setup(legacyLastExport: .userDefaults(defaults))
    let data = DataSettingsModel(environment: setup.environment)
    await data.load()
    #expect(data.lastExport == Day(year: 2026, month: 10, day: 3))
    #expect(defaults.object(forKey: LegacyLastExport.defaultsKey) == nil)
  }

  @Test("R-SET-2 an export through the live store is remembered in the app database")
  func liveExportPersists() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "c2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = try AbacusDatabase.open(at: nil)
    let first = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await first.start()
    await first.app.data.export(to: folder.appending(path: "backup.abacus"))
    first.stop()
    #expect(try await SQLiteSettingsRepository(database: database).value(.lastBackupExport) == "2026-10-21")

    let second = AppSession.live(
      database: database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(16) }, formats: B1Fixture.formats)
    await second.start()
    defer { second.stop() }
    #expect(second.app.data.lastExport == B1Fixture.today)
  }
}
