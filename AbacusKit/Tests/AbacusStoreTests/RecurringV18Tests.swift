import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// N5: schema v18 (recurring transactions): migration from v17, CloudKit-safe shape.
@Suite("Recurring transactions schema (v18)")
struct RecurringV18Tests {
  static let tables = ["scheduledItems", "scheduledOccurrences", "forecastSnapshots", "forecastSnapshotItems", "suggestionDismissals"]

  @Test("v18 adds the five tables, keeps data, runs again; no UNIQUE, CASCADE / SET NULL only, TEXT primary key")
  func migration() throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: "v17: transaction moves")
    try queue.write { db in
      for table in Self.tables { #expect(try !db.tableExists(table)) }
      try db.execute(
        sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES ('a1', 'A', 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    try queue.write { db in
      for table in Self.tables {
        #expect(try db.tableExists(table))
        #expect(try db.primaryKey(table).columns == ["id"])
        #expect(try db.indexes(on: table).filter { $0.name.hasPrefix("idx_") }.allSatisfy { !$0.isUnique })
        let actions = try String.fetchAll(db, sql: "SELECT \"on_delete\" FROM pragma_foreign_key_list('\(table)')")
        #expect(actions.allSatisfy { $0 == "CASCADE" || $0 == "SET NULL" })
      }
      #expect(try Int.fetchOne(db, sql: #"SELECT count(*) FROM "accounts""#) == 1)
    }
  }

  @Test("entities round trip; a deleted snapshot takes its items, a deleted transaction clears the link, a deleted item keeps history")
  func roundTrip() throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue)
    let account = Account(name: "A", currency: .PLN, kind: .bank, openingBalanceMinor: 0, openingDate: Date())
    let item = ScheduledItem(
      type: .transfer, accountID: account.id, toAccountID: UUID(), amountMinor: 12_300, toAmountMinor: 3_000, payee: "Rent",
      unit: .month, interval: 2, startDay: "2026-01-31", lastDayOfMonth: true, endKind: .onDay, endDay: "2027-01-31",
      tolerancePercent: 8, status: .paused, pausedBecause: .accountArchived,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    let txn = Txn(type: .expense, occurredAt: Date(), accountID: account.id, amountMinor: 12_300)
    let occurrence = ScheduledOccurrence(
      itemID: item.id, expectedDay: "2026-02-28", expectedAmountMinor: 12_300, status: .paid, txnID: txn.id,
      actualDay: "2026-03-01", actualAmountMinor: 12_400, matchKind: .auto)
    let snapshot = ForecastSnapshot(takenDay: "2026-11-03", startBalancesJSON: "{}", ratesJSON: "{}")
    let snapshotItem = ForecastSnapshotItem(
      snapshotID: snapshot.id, itemID: item.id, day: "2026-11-05", accountID: account.id, amountMinor: -100)
    let dismissal = SuggestionDismissal(accountID: account.id, key: "streamly|expense|PLN")
    try queue.write { db in
      try Account.insert { account }.execute(db)
      try Txn.insert { txn }.execute(db)
      try ScheduledItem.insert { item }.execute(db)
      try ScheduledOccurrence.insert { occurrence }.execute(db)
      try ForecastSnapshot.insert { snapshot }.execute(db)
      try ForecastSnapshotItem.insert { snapshotItem }.execute(db)
      try SuggestionDismissal.insert { dismissal }.execute(db)
    }
    try queue.write { db in
      #expect(try ScheduledItem.find(item.id).fetchOne(db) == item)
      #expect(try ScheduledOccurrence.find(occurrence.id).fetchOne(db)?.matchKind == .auto)
      #expect(try SuggestionDismissal.fetchAll(db).count == 1)
      try db.execute(sql: #"DELETE FROM "txns""#)
      #expect(try ScheduledOccurrence.find(occurrence.id).fetchOne(db)?.txnID == nil)
      try db.execute(sql: #"DELETE FROM "forecastSnapshots""#)
      #expect(try ForecastSnapshotItem.fetchAll(db).isEmpty)
      try db.execute(sql: #"DELETE FROM "scheduledItems""#)
      #expect(try ScheduledOccurrence.fetchAll(db).count == 1)
    }
  }
}
