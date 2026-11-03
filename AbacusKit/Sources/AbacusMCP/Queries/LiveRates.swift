import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData

/// The app's rate table, read from the database on every call (the same load the app's rate
/// refresher does), so a long-running server sees rates fetched meanwhile.
public enum LiveRates {
  public static let source: RateSource = { database in
    let store = SQLiteRateStore(database: database)
    let rates = try await store.rates(from: Day(year: 1900, month: 1, day: 1), to: Day(year: 9999, month: 12, day: 31))
    return RateTable(rates: rates, overrides: try await store.overrides(), today: Day(Date()))
  }
}
