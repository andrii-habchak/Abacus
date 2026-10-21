import AbacusDomain
import Foundation
import SQLiteData

/// Key/value app settings (R-SET). Missing keys mean "default".
public struct SQLiteSettingsRepository: SettingsRepository {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  public func value(_ key: SettingKey) async throws -> String? {
    try await database.read { db in try Self.value(key, db) }
  }

  public func set(_ key: SettingKey, _ value: String) async throws {
    try await database.write { db in
      try AppSetting.upsert { AppSetting(key, value: value) }.execute(db)
    }
  }

  /// R-SET-3 / R-TX-4: off unless set to "true".
  public func refundsReduceSpending() async throws -> Bool {
    try await database.read { db in try Self.refundsReduceSpending(db) }
  }

  /// R-HOME-4 / R-SET-1: default UAH.
  public func displayCurrency() async throws -> Currency {
    let raw = try await value(.displayCurrency)
    return raw.flatMap(Currency.init(rawValue:)) ?? .UAH
  }

  /// R-FX-1: default on.
  public func ratesAutoRefresh() async throws -> Bool {
    try await value(.ratesAutoRefresh) != "false"
  }

  static func value(_ key: SettingKey, _ db: Database) throws -> String? {
    let id = key.rawValue
    return try AppSetting.where { $0.id.eq(id) }.fetchOne(db)?.value
  }

  static func refundsReduceSpending(_ db: Database) throws -> Bool {
    try value(.refundsReduceSpending, db) == "true"
  }
}
