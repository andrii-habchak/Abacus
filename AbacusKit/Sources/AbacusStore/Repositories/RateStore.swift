import AbacusDomain
import Foundation
import SQLiteData

/// Rates cache and manual overrides (R-FX-1/2, storage only; lookup logic lives in AbacusFX).
public struct SQLiteRateStore: RateStore {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  /// Cached rates with `from <= day <= to`, by day.
  public func rates(from: Day, to: Day) async throws -> [FXRate] {
    let lower = from.string
    let upper = to.string
    return try await database.read { db in
      try FXRate
        .where { $0.day.gte(lower) && $0.day.lte(upper) }
        .order { ($0.day, $0.base, $0.quote, $0.provider) }
        .fetchAll(db)
    }
  }

  /// For every currency pair, the rates of the most recent day cached.
  public func latestRates() async throws -> [FXRate] {
    try await database.read { db in
      try FXRate
        .where { rate in
          #sql(
            """
            \(rate.day) = (SELECT max("l"."day") FROM "fxRates" AS "l" \
            WHERE "l"."base" = \(rate.base) AND "l"."quote" = \(rate.quote))
            """)
        }
        .order { ($0.base, $0.quote, $0.provider) }
        .fetchAll(db)
    }
  }

  /// Upserts by primary key (the refresher reuses the id of the cached row), and replaces any
  /// other row with the same (day, base, quote, provider), so a refetch under a new id cannot
  /// trip the unique index either. One transaction for the whole list.
  public func save(_ rates: [FXRate]) async throws {
    try await database.write { db in
      for rate in rates {
        try FXRate
          .where {
            $0.day.eq(rate.day) && $0.base.eq(rate.base) && $0.quote.eq(rate.quote)
              && $0.provider.eq(rate.provider) && $0.id.neq(rate.id)
          }
          .delete().execute(db)
        try FXRate.upsert { FXRate.Draft(rate) }.execute(db)
      }
    }
  }

  /// R-FX-2: overrides by pair, newest start first.
  public func overrides() async throws -> [FXOverride] {
    try await database.read { db in
      try FXOverride.order { ($0.base, $0.quote, $0.fromDay.desc()) }.fetchAll(db)
    }
  }

  public func save(_ override: FXOverride) async throws {
    try await database.write { db in
      try FXOverride.upsert { FXOverride.Draft(override) }.execute(db)
    }
  }

  public func deleteOverride(_ id: FXOverride.ID) async throws {
    try await database.write { db in
      try FXOverride.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }
}
