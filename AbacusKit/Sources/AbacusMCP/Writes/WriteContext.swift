import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// The read-write side the write tools run against: the same repositories the app uses, so its
/// rules hold (an account with transactions is archived, never deleted; refunds stay within
/// their original; and so on).
struct WriteContext: Sendable {
  let database: any DatabaseWriter
  let calendar: Calendar
  let rates: RateSource
  let today: @Sendable () -> Day

  var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
  var categories: SQLiteCategoryRepository { SQLiteCategoryRepository(database: database) }
  var imports: SQLiteImportStore { SQLiteImportStore(database: database, calendar: calendar) }

  var txns: SQLiteTxnRepository {
    let database = self.database
    let rates = self.rates
    return SQLiteTxnRepository(
      database: database, calendar: calendar, converter: { try? await rates(database) })
  }

  func directory() async throws -> Directory {
    try await AbacusQueries(database: database, calendar: calendar, rates: rates, today: today).directory()
  }
}
