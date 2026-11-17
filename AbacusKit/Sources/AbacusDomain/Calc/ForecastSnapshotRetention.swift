import Foundation

/// R-REC-18: which snapshot days to keep. Daily for the last `dailyDays` days (age 0 to
/// `dailyDays - 1`), then the first snapshot of each ISO week (Monday to Sunday) up to
/// `maxAgeDays` old, older ones deleted. Future days (clock moved back) are kept.
public enum ForecastSnapshotRetention {
  public static let dailyDays = 120
  public static let maxAgeDays = 730

  public static func keep(_ days: some Sequence<Day>, today: Day, dailyDays: Int = dailyDays, maxAgeDays: Int = maxAgeDays) -> Set<Day> {
    var kept: Set<Day> = []
    var firstOfWeek: [Int: Day] = [:]
    for day in Set(days) {
      let age = day.daysUntil(today)
      if age < dailyDays {
        kept.insert(day)
      } else if age <= maxAgeDays {
        let week = isoWeekStart(day)
        if let current = firstOfWeek[week], current <= day { continue }
        firstOfWeek[week] = day
      }
    }
    kept.formUnion(firstOfWeek.values)
    return kept
  }

  /// Ordinal of the Monday that starts `day`'s ISO week (1970-01-01 was a Thursday).
  static func isoWeekStart(_ day: Day) -> Int {
    let ordinal = Civil.ordinal(day)
    let sinceMonday = ((ordinal + 3) % 7 + 7) % 7
    return ordinal - sinceMonday
  }
}
