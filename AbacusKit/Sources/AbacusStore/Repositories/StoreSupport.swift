import AbacusDomain
import Foundation
import SQLiteData

/// Store errors beyond the shared `RepositoryError` contract.
public enum StoreError: Error, Equatable, Sendable {
  /// R-ACC-1: an account's currency is fixed after its first transaction.
  case currencyLocked
  /// R-CAT-2: one level of subcategories — the parent must be an existing top-level category,
  /// and a category with children cannot become a child.
  case invalidParent
  /// R-SET-2: the file is not an Abacus backup.
  case invalidBackup
  /// R-SET-2: the backup was written by a newer version of the app.
  case backupFromNewerVersion
}

/// Day ↔ timestamp conversion. Transactions store an instant (`occurredAt`); filters and
/// reports work on calendar days of `calendar` (the user's calendar by default).
struct DayBounds: Sendable {
  var calendar: Calendar

  /// First instant of `day`.
  func start(_ day: Day) -> Date { day.date(calendar: calendar) }

  /// First instant after `day` (exclusive upper bound).
  func end(_ day: Day) -> Date { day.adding(days: 1, calendar: calendar).date(calendar: calendar) }

  func day(_ date: Date) -> Day { Day(date, calendar: calendar) }
}

extension Array {
  func chunked(_ size: Int) -> [ArraySlice<Element>] {
    stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
  }
}

/// `(a, b, c)` with each value bound as a parameter.
func sqlList<Value: QueryBindable>(_ values: some Sequence<Value>) -> QueryFragment {
  let items: [QueryFragment] = values.map { "\($0)" }
  return "(" + items.joined(separator: ", ") + ")"
}
