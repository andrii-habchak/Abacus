import AbacusDomain
import Foundation

/// A pending PKO hold the new file should have settled and did not (R-CLR-8): the bank has
/// probably released it, so it stays pending forever unless the owner decides.
public struct StaleHold: Hashable, Sendable, Identifiable {
  public var txn: Txn
  /// The purchase day of the hold.
  public var valueDay: Day
  /// Days between the hold's value day and the file's last booked day.
  public var daysBehind: Int
  public var id: Txn.ID { txn.id }
}

/// What the owner decides for a stale hold (all commit with the import).
public enum StaleHoldDecision: Hashable, Sendable {
  /// No change; asked again at the next import while it still qualifies.
  case keep
  /// The payment went through: no longer pending, still uncleared (no bank row confirms it).
  case markSettled
  /// Delete the transaction (undo of the import brings it back).
  case delete
  /// Change the amount or purchase day; `stillPending: false` also clears the pending mark. It stays
  /// uncleared.
  case edit(StaleHoldEdit)
}

public struct StaleHoldEdit: Hashable, Sendable {
  public var amountMinor: Int64
  public var day: Day
  public var stillPending: Bool

  public init(amountMinor: Int64, day: Day, stillPending: Bool = true) {
    self.amountMinor = amountMinor
    self.day = day
    self.stillPending = stillPending
  }
}

public enum StaleHolds {
  /// A hold is stale when its value day is at least this many days before the file's last booked
  /// day: settled rows are booked 1–3 days after the purchase and matched within ± 3 days
  /// (`PendingSettlement.dayWindow`), so by day 5 the settled row would be in the file.
  public static let staleDays = 5
  /// The file covers a hold whose value day is not more than this many days before its first booked
  /// day (the same window as `PendingSettlement`).
  public static let coverageDays = PendingSettlement.dayWindow

  /// The booked-day range the file covers (holds have no booking day).
  public static func bookedRange(of rows: [NormalizedRow], calendar: Calendar) -> ClosedRange<Day>? {
    let days = rows.filter { !$0.isPending }.compactMap { $0.bookedDay ?? $0.valueDay }
    guard let first = days.min(), let last = days.max() else { return nil }
    return first...last
  }

  /// The search window for holds: value days from `coverageDays` before the file's first booked
  /// day to `staleDays` before its last.
  public static func window(for range: ClosedRange<Day>, calendar: Calendar) -> ClosedRange<Day>? {
    let from = range.lowerBound.adding(days: -coverageDays, calendar: calendar)
    let to = range.upperBound.adding(days: -staleDays, calendar: calendar)
    return from <= to ? from...to : nil
  }

  /// The stale holds among `pending` (pending PKO holds of the target account), skipping any hold
  /// that a row of the file settles, links to or lists again (`claimed`).
  public static func find(
    pending: [Txn], claimed: Set<Txn.ID>, range: ClosedRange<Day>, calendar: Calendar
  ) -> [StaleHold] {
    guard let window = window(for: range, calendar: calendar) else { return [] }
    return pending.compactMap { txn in
      guard txn.isPendingAtBank, txn.source == .pko, !claimed.contains(txn.id) else { return nil }
      let day = Day(txn.occurredAt, calendar: calendar)
      guard window.contains(day) else { return nil }
      let behind = calendar.dateComponents([.day], from: day.date(calendar: calendar), to: range.upperBound.date(calendar: calendar)).day ?? 0
      return StaleHold(txn: txn, valueDay: day, daysBehind: behind)
    }.sorted { ($0.valueDay, $0.txn.id.uuidString) < ($1.valueDay, $1.txn.id.uuidString) }
  }
}
