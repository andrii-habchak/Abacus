import Foundation

/// A calendar day without time zone, stored as `YYYY-MM-DD`. Used for rates, budgets and
/// date filters so that time zones never shift a transaction into another day.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  public init?(_ string: String) {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
      return nil
    }
    self.init(year: parts[0], month: parts[1], day: parts[2])
  }

  public init(_ date: Date, calendar: Calendar = .current) {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: c.year!, month: c.month!, day: c.day!)
  }

  public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
  public var description: String { string }
  public var yearMonth: Month { Month(year: year, month: month) }

  public func date(calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  public func adding(days: Int, calendar: Calendar = .current) -> Day {
    Day(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: calendar)
  }

  public static func < (lhs: Day, rhs: Day) -> Bool { lhs.string < rhs.string }
}

/// A calendar month, stored as `YYYY-MM` (budgets, month selectors).
public struct Month: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let year: Int
  public let month: Int

  public init(year: Int, month: Int) {
    self.year = year
    self.month = month
  }

  public init?(_ string: String) {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
    self.init(year: parts[0], month: parts[1])
  }

  public var string: String { String(format: "%04d-%02d", year, month) }
  public var description: String { string }
  public var firstDay: Day { Day(year: year, month: month, day: 1) }

  public func adding(months: Int) -> Month {
    let index = year * 12 + (month - 1) + months
    return Month(year: index / 12, month: index % 12 + 1)
  }

  public func lastDay(calendar: Calendar = .current) -> Day {
    adding(months: 1).firstDay.adding(days: -1, calendar: calendar)
  }

  public static func < (lhs: Month, rhs: Month) -> Bool { lhs.string < rhs.string }
}
