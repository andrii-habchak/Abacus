import Foundation

/// Pure recurrence rules (R-REC-2). Everything works on `Day` values with proleptic Gregorian
/// arithmetic of its own, so no time zone, calendar or DST can move an occurrence.
///
/// Occurrence number `i` (0-based) is computed from the start day only, never from the previous
/// occurrence, so months of different length cannot make dates drift.
public struct Schedule: Hashable, Sendable {
  public enum End: Hashable, Sendable {
    case never
    case onDay(Day)
    case afterCount(Int)
  }

  public var unit: ScheduleUnit
  public var interval: Int
  public var startDay: Day
  /// Month unit only: every occurrence is the last day of its month.
  public var lastDayOfMonth: Bool
  public var end: End

  public init(unit: ScheduleUnit, interval: Int = 1, startDay: Day, lastDayOfMonth: Bool = false, end: End = .never) {
    self.unit = unit
    self.interval = max(1, interval)
    self.startDay = startDay
    self.lastDayOfMonth = lastDayOfMonth && unit == .month
    self.end = end
  }

  /// The occurrence number `index`, ignoring the end rule.
  func rawDay(at index: Int) -> Day {
    switch unit {
    case .day:
      return Civil.day(fromOrdinal: Civil.ordinal(startDay) + index * interval)
    case .week:
      return Civil.day(fromOrdinal: Civil.ordinal(startDay) + 7 * index * interval)
    case .month, .year:
      let months = (unit == .year ? 12 : 1) * interval * index
      let target = startDay.yearMonth.adding(months: months)
      let length = Civil.daysInMonth(year: target.year, month: target.month)
      let dayOfMonth = lastDayOfMonth ? length : min(startDay.day, length)
      return Day(year: target.year, month: target.month, day: dayOfMonth)
    }
  }

  /// The day of occurrence `index`, or nil when the end rule stops the series before it.
  public func occurrence(at index: Int) -> Day? {
    guard index >= 0 else { return nil }
    if case .afterCount(let count) = end, index >= count { return nil }
    let day = rawDay(at: index)
    if case .onDay(let last) = end, day > last { return nil }
    return day
  }

  /// All occurrences with `from <= day <= through`, in order.
  public func occurrences(from: Day, through: Day) -> [Day] {
    var result: [Day] = []
    var index = firstIndex(onOrAfter: from)
    while let day = occurrence(at: index), day <= through {
      if day >= from { result.append(day) }
      index += 1
    }
    return result
  }

  /// The first `count` occurrences at or after `from` (the editor's "next five dates", R-REC-12).
  public func next(_ count: Int, onOrAfter from: Day) -> [Day] {
    var result: [Day] = []
    var index = firstIndex(onOrAfter: from)
    while result.count < count, let day = occurrence(at: index) {
      if day >= from { result.append(day) }
      index += 1
    }
    return result
  }

  /// The number of occurrences at or before `day`, ending rule applied.
  public func count(through day: Day) -> Int {
    var n = 0
    while let d = occurrence(at: n), d <= day { n += 1 }
    return n
  }

  /// The index of the last occurrence, when the series is finite.
  public var lastOccurrence: Day? {
    switch end {
    case .never: return nil
    case .afterCount(let count): return count > 0 ? occurrence(at: count - 1) : nil
    case .onDay(let last):
      var n = 0
      var last_: Day?
      while let d = occurrence(at: n), d <= last { last_ = d; n += 1 }
      return last_
    }
  }

  /// A lower bound for the index of the first occurrence on or after `day` (cheap jump so a long
  /// past start does not cost a loop over every earlier occurrence).
  private func firstIndex(onOrAfter day: Day) -> Int {
    guard day > startDay else { return 0 }
    let ordinalGap = Civil.ordinal(day) - Civil.ordinal(startDay)
    let guess: Int
    switch unit {
    case .day: guess = ordinalGap / interval
    case .week: guess = ordinalGap / (7 * interval)
    case .month, .year:
      let months = (day.year - startDay.year) * 12 + (day.month - startDay.month)
      guess = months / ((unit == .year ? 12 : 1) * interval)
    }
    // Step back one so clamping at a month end can never skip an occurrence.
    return max(0, guess - 1)
  }
}

extension ScheduledItem {
  /// The recurrence of this item; nil when a stored day is not a valid `YYYY-MM-DD`.
  public var schedule: Schedule? {
    guard let start = Day(startDay) else { return nil }
    let end: Schedule.End
    switch endKind {
    case .never: end = .never
    case .onDay:
      guard let endDay, let day = Day(endDay) else { return nil }
      end = .onDay(day)
    case .afterCount:
      guard let endCount else { return nil }
      end = .afterCount(endCount)
    }
    return Schedule(unit: unit, interval: interval, startDay: start, lastDayOfMonth: lastDayOfMonth, end: end)
  }
}

/// Civil-day arithmetic without `Calendar` (Howard Hinnant's days-from-civil).
enum Civil {
  static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

  static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: return isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  /// Days since 1970-01-01.
  static func ordinal(_ day: Day) -> Int {
    let y = day.month <= 2 ? day.year - 1 : day.year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (day.month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day.day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  static func day(fromOrdinal z0: Int) -> Day {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return Day(year: m <= 2 ? y + 1 : y, month: m, day: d)
  }
}

extension Day {
  /// Signed number of days from `self` to `other`, calendar-free.
  public func daysUntil(_ other: Day) -> Int { Civil.ordinal(other) - Civil.ordinal(self) }
  /// Calendar-free day arithmetic (R-REC: day strings only).
  public func plusDays(_ n: Int) -> Day { Civil.day(fromOrdinal: Civil.ordinal(self) + n) }
}
