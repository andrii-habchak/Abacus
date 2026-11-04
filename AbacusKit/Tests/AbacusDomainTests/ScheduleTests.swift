import AbacusDomain
import Foundation
import Testing

@Suite("N5 Schedule (R-REC-2)")
struct ScheduleTests {
  func d(_ s: String) -> Day { Day(s)! }
  func strings(_ days: [Day]) -> [String] { days.map(\.string) }

  @Test("R-REC-2: monthly on the 31st clamps to month end and returns to the 31st, leap February")
  func monthly31() {
    let s = Schedule(unit: .month, startDay: d("2027-01-31"))
    #expect(strings(s.next(4, onOrAfter: d("2027-01-01"))) == ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30"])
    let leap = Schedule(unit: .month, startDay: d("2028-01-31"))
    #expect(leap.occurrence(at: 1)?.string == "2028-02-29")
  }

  @Test("R-REC-2: last day of the month, even when started mid-month")
  func lastDay() {
    let s = Schedule(unit: .month, startDay: d("2026-10-15"), lastDayOfMonth: true)
    #expect(strings(s.next(4, onOrAfter: d("2026-10-01"))) == ["2026-10-31", "2026-11-30", "2026-12-31", "2027-01-31"])
  }

  @Test("R-REC-2: yearly 29 Feb is 28 Feb in common years")
  func yearlyLeap() {
    let s = Schedule(unit: .year, startDay: d("2024-02-29"))
    #expect(strings(s.next(5, onOrAfter: d("2024-01-01"))) == ["2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29"])
  }

  @Test("R-REC-2: every 2 months from 31 Jan counts months from the start, no drift")
  func everyTwoMonths() {
    let s = Schedule(unit: .month, interval: 2, startDay: d("2027-01-31"))
    #expect(strings(s.next(4, onOrAfter: d("2027-01-01"))) == ["2027-01-31", "2027-03-31", "2027-05-31", "2027-07-31"])
  }

  @Test("R-REC-2: weekly keeps the weekday across DST changes (day strings only)")
  func weeklyDST() {
    let s = Schedule(unit: .week, startDay: d("2027-03-20"))
    let days = s.next(6, onOrAfter: d("2027-03-01"))
    for (a, b) in zip(days, days.dropFirst()) { #expect(a.daysUntil(b) == 7) }
    #expect(days.contains(d("2027-03-27")))
    #expect(days.contains(d("2027-04-03")))
    let every2 = Schedule(unit: .week, interval: 2, startDay: d("2026-10-17"))
    #expect(strings(every2.next(3, onOrAfter: d("2026-10-17"))) == ["2026-10-17", "2026-10-31", "2026-11-14"])
  }

  @Test("R-REC-2: daily with an interval")
  func daily() {
    let s = Schedule(unit: .day, interval: 3, startDay: d("2026-02-27"))
    #expect(strings(s.next(3, onOrAfter: d("2026-02-27"))) == ["2026-02-27", "2026-03-02", "2026-03-05"])
  }

  @Test("R-REC-2: end by day and by count")
  func ends() {
    let byDay = Schedule(unit: .month, startDay: d("2026-01-10"), end: .onDay(d("2026-04-10")))
    #expect(strings(byDay.occurrences(from: d("2026-01-01"), through: d("2030-01-01"))) == ["2026-01-10", "2026-02-10", "2026-03-10", "2026-04-10"])
    #expect(byDay.lastOccurrence?.string == "2026-04-10")
    let byCount = Schedule(unit: .week, startDay: d("2026-01-05"), end: .afterCount(3))
    #expect(byCount.occurrences(from: d("2026-01-01"), through: d("2030-01-01")).count == 3)
    #expect(byCount.lastOccurrence?.string == "2026-01-19")
    #expect(Schedule(unit: .day, startDay: d("2026-01-01"), end: .afterCount(0)).occurrence(at: 0) == nil)
  }

  @Test("R-REC-2: start in the past is found without drift; ranges are inclusive")
  func pastStart() {
    let s = Schedule(unit: .month, startDay: d("2020-01-31"))
    #expect(strings(s.occurrences(from: d("2026-02-01"), through: d("2026-04-30"))) == ["2026-02-28", "2026-03-31", "2026-04-30"])
    #expect(s.occurrences(from: d("2026-02-28"), through: d("2026-02-28")).count == 1)
    let before = Schedule(unit: .month, startDay: d("2026-06-01"))
    #expect(before.occurrences(from: d("2026-01-01"), through: d("2026-05-30")).isEmpty)
  }

  @Test("R-REC-2 property: strictly increasing, anchored, count matches formula")
  func property() {
    for unit in ScheduleUnit.allCases {
      for interval in [1, 2, 5] {
        for start in ["2024-02-29", "2026-01-31", "2026-12-31", "2027-03-01"] {
          let s = Schedule(unit: unit, interval: interval, startDay: d(start))
          let days = s.next(40, onOrAfter: d(start))
          #expect(days.count == 40)
          #expect(days.first == d(start))
          for (a, b) in zip(days, days.dropFirst()) { #expect(a < b) }
          for (i, day) in days.enumerated() { #expect(s.occurrence(at: i) == day) }
        }
      }
    }
  }

  @Test("R-REC-12: invalid interval is clamped to 1; the item exposes its schedule")
  func itemSchedule() {
    #expect(Schedule(unit: .day, interval: 0, startDay: d("2026-01-01")).interval == 1)
    let item = ScheduledItem(type: .expense, accountID: UUID(), amountMinor: 100, unit: .month, startDay: "2026-01-31", endKind: .afterCount, endCount: 2)
    #expect(item.schedule?.end == .afterCount(2))
    let broken = ScheduledItem(type: .expense, accountID: UUID(), amountMinor: 100, startDay: "garbage")
    #expect(broken.schedule == nil)
  }

  @Test("Civil arithmetic round trips and matches Calendar")
  func civil() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var day = d("2023-12-20")
    for _ in 0..<800 {
      let next = day.plusDays(1)
      #expect(next == day.adding(days: 1, calendar: cal))
      #expect(day.daysUntil(next) == 1)
      day = next
    }
    #expect(d("2000-02-29").plusDays(366).string == "2001-03-01")
    #expect(d("2026-11-04").plusDays(-1000).plusDays(1000) == d("2026-11-04"))
  }
}
