import Foundation

/// One resolved occurrence in the accuracy panel (R-REC-20).
public struct OccurrenceAccuracy: Hashable, Sendable, Identifiable {
  public let occurrence: ScheduledOccurrence
  public var id: ScheduledOccurrence.ID { occurrence.id }
  public var expectedDay: Day? { Day(occurrence.expectedDay) }
  public var actualDay: Day? { occurrence.actualDay.flatMap(Day.init) }
  /// Actual − expected day (+2 = two days late); nil unless paid with a day.
  public var dayDelta: Int? {
    guard occurrence.status == .paid, let e = expectedDay, let a = actualDay else { return nil }
    return e.daysUntil(a)
  }
  /// Actual − expected amount (positive minor units both, so + = paid more); nil unless paid with an amount.
  public var amountDeltaMinor: Int64? {
    guard occurrence.status == .paid, let actual = occurrence.actualAmountMinor else { return nil }
    return actual - occurrence.expectedAmountMinor
  }
  /// Amount difference in percent of the expected amount (+3.1 = 3.1 % more).
  public var amountDeltaPercent: Double? {
    guard let delta = amountDeltaMinor, occurrence.expectedAmountMinor != 0 else { return nil }
    return Double(delta) / Double(occurrence.expectedAmountMinor) * 100
  }
  /// |Δ day| ≤ 1 (R-REC-20).
  public var isOnTime: Bool? { dayDelta.map { abs($0) <= 1 } }
}

/// Counts and averages over a set of occurrences (one item, or the overall line).
public struct AccuracySummary: Hashable, Sendable {
  public let paid: Int
  public let skipped: Int
  public let missed: Int
  /// Share of paid occurrences with a known day that were on time (0…1); nil without any.
  public let onTimeShare: Double?
  /// Mean of |amount Δ %| over paid occurrences with a known amount; nil without any.
  public let averageAbsDeviationPercent: Double?

  init(_ rows: [OccurrenceAccuracy]) {
    paid = rows.filter { $0.occurrence.status == .paid }.count
    skipped = rows.filter { $0.occurrence.status == .skipped }.count
    missed = rows.filter { $0.occurrence.status == .missed }.count
    let timed = rows.compactMap(\.isOnTime)
    onTimeShare = timed.isEmpty ? nil : Double(timed.filter { $0 }.count) / Double(timed.count)
    let deviations = rows.compactMap(\.amountDeltaPercent).map(abs)
    averageAbsDeviationPercent = deviations.isEmpty ? nil : deviations.reduce(0, +) / Double(deviations.count)
  }
}

/// One scheduled item's row of the accuracy panel.
public struct ItemAccuracy: Hashable, Sendable, Identifiable {
  public let itemID: ScheduledItem.ID
  public var id: ScheduledItem.ID { itemID }
  /// Nil when the item was deleted (its occurrences are kept, R-REC-1).
  public let item: ScheduledItem?
  /// In scope, oldest expected day first.
  public let rows: [OccurrenceAccuracy]
  public let summary: AccuracySummary
  /// "Update amount to X" (R-REC-20): set when the last three paid amounts all differ from the
  /// template by more than 2 %; X is the latest paid amount.
  public let suggestedAmountMinor: Int64?
}

public struct ForecastAccuracy: Hashable, Sendable {
  public let items: [ItemAccuracy]
  /// The overall line over all items in scope.
  public let overall: AccuracySummary

  public static let suggestionThresholdPercent: Double = 2
  public static let suggestionPayments = 3

  /// R-REC-20. Data comes from resolved occurrences only, so it works without snapshots.
  /// `period` scopes the rows by expected day (a snapshot's day to today); nil = all time. The
  /// "Update amount" suggestion always looks at the item's last three payments of all time: it is
  /// about the template now, not about the chosen period.
  public static func report(
    items: [ScheduledItem], occurrences: [ScheduledOccurrence], period: ClosedRange<Day>? = nil
  ) -> ForecastAccuracy {
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let grouped = Dictionary(grouping: occurrences, by: \.itemID)
    var result: [ItemAccuracy] = []
    var allRows: [OccurrenceAccuracy] = []
    for (itemID, list) in grouped {
      let sorted = list.sorted { ($0.expectedDay, $0.id.uuidString) < ($1.expectedDay, $1.id.uuidString) }
      let rows = sorted
        .filter { occurrence in
          guard let period else { return true }
          guard let day = Day(occurrence.expectedDay) else { return false }
          return period.contains(day)
        }
        .map(OccurrenceAccuracy.init)
      let item = byID[itemID]
      let suggestion = item.flatMap { suggestedAmount(template: $0.amountMinor, occurrences: sorted) }
      guard !rows.isEmpty || suggestion != nil else { continue }
      allRows += rows
      result.append(ItemAccuracy(
        itemID: itemID, item: item, rows: rows, summary: AccuracySummary(rows), suggestedAmountMinor: suggestion))
    }
    result.sort { lhs, rhs in
      let l = (lhs.item?.payee ?? "", lhs.itemID.uuidString)
      let r = (rhs.item?.payee ?? "", rhs.itemID.uuidString)
      return l < r
    }
    return ForecastAccuracy(items: result, overall: AccuracySummary(allRows))
  }

  /// The latest paid amount when the last three paid amounts (by expected day) each differ from
  /// `template` by more than 2 %; nil otherwise.
  public static func suggestedAmount(template: Int64, occurrences: [ScheduledOccurrence]) -> Int64? {
    guard template > 0 else { return nil }
    let paid = occurrences
      .filter { $0.status == .paid && $0.actualAmountMinor != nil }
      .sorted { ($0.expectedDay, $0.resolvedAt) < ($1.expectedDay, $1.resolvedAt) }
      .suffix(suggestionPayments)
      .compactMap(\.actualAmountMinor)
    guard paid.count == suggestionPayments else { return nil }
    let drifting = paid.allSatisfy { amount in
      Double(abs(amount - template)) / Double(template) * 100 > suggestionThresholdPercent
    }
    guard drifting, let latest = paid.last, latest != template else { return nil }
    return latest
  }
}
