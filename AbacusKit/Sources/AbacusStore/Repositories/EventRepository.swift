import AbacusDomain
import Foundation
import SQLiteData

/// Events (R-EVT): trips, relocations — one optional event per transaction.
public struct SQLiteEventRepository: EventRepository {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  /// Newest first by start day; events without dates last, by name.
  public func events(includeArchived: Bool) async throws -> [Event] {
    try await database.read { db in
      try Event
        .where { if !includeArchived { !$0.isArchived } }
        .order { ($0.startDay.desc(nulls: .last), $0.name) }
        .fetchAll(db)
    }
  }

  public func save(_ event: Event) async throws {
    try await database.write { db in
      try Event.upsert { Event.Draft(event) }.execute(db)
      // R-MGMT-7: an event saved without a colour gets one apart from the other events'.
      if ColorPalette.rgb(event.colorHex) == nil { try ColorFill.fillEvents(db) }
    }
  }

  public func setArchived(_ id: Event.ID, _ isArchived: Bool) async throws {
    try await database.write { db in
      try Event.find(id).update { $0.isArchived = isArchived }.execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  /// Clears the event from its transactions, then deletes it.
  public func delete(_ id: Event.ID) async throws {
    try await database.write { db in
      guard try Event.find(id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
      try Txn.where { $0.eventID.eq(id) }.update { $0.eventID = #bind(nil) }.execute(db)
      try Event.find(id).delete().execute(db)
    }
  }

  /// R-EVT-2: the events whose date range contains `day` (for pre-selecting in the editor).
  public func activeEvents(on day: Day) async throws -> [Event] {
    let dayString = day.string
    return try await database.read { db in
      try Event
        .where {
          !$0.isArchived
            && #sql("\($0.startDay) <= \(bind: dayString) AND coalesce(\($0.endDay) >= \(bind: dayString), 1)")
        }
        .order { ($0.startDay.desc(), $0.name) }
        .fetchAll(db)
    }
  }
}
