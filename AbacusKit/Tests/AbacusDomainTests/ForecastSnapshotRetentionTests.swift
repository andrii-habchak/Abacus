import AbacusDomain
import Foundation
import Testing

/// N5c: R-REC-18 retention rule and the snapshot JSON columns (R-REC-17, R-REC-19).
@Suite("Forecast snapshot retention and JSON")
struct ForecastSnapshotRetentionTests {
  static let today = Day("2026-11-10")!  // a Tuesday

  @Test("R-REC-18: the last 120 days are kept daily")
  func daily() {
    let days = (0..<120).map { Self.today.plusDays(-$0) }
    #expect(ForecastSnapshotRetention.keep(days, today: Self.today) == Set(days))
  }

  @Test("R-REC-18: older than 120 days, the first snapshot of each ISO week is kept, up to 2 years")
  func weekly() {
    // 2026-06-01 is a Monday, 162 days before today.
    let monday = Day("2026-06-01")!
    let week = (0..<7).map { monday.plusDays($0) }
    #expect(ForecastSnapshotRetention.keep(week, today: Self.today) == [monday])
    // Without the Monday, Wednesday is the first of that week.
    #expect(ForecastSnapshotRetention.keep(week.dropFirst(2), today: Self.today) == [monday.plusDays(2)])
    // Sunday belongs to the week before the next Monday (ISO weeks start Monday).
    let sunday = Day("2026-06-07")!
    let nextMonday = Day("2026-06-08")!
    #expect(ForecastSnapshotRetention.keep([sunday, nextMonday], today: Self.today) == [sunday, nextMonday])
  }

  @Test("R-REC-18: older than 2 years is deleted; the boundaries are 120 and 730 days")
  func boundaries() {
    let keep = ForecastSnapshotRetention.keep(
      [Self.today.plusDays(-119), Self.today.plusDays(-730), Self.today.plusDays(-731)], today: Self.today)
    #expect(keep == [Self.today.plusDays(-119), Self.today.plusDays(-730)])
    #expect(ForecastSnapshotRetention.keep([Self.today.plusDays(3)], today: Self.today) == [Self.today.plusDays(3)])
  }

  @Test("R-REC-19: snapshot rates round-trip exactly and convert through the base")
  func ratesJSON() throws {
    let rates = SnapshotRates(asOf: Day("2026-11-09"), base: .UAH, toBase: [.PLN: Decimal(string: "10.4567")!, .EUR: 45])
    let text = try SnapshotJSON.encode(rates)
    #expect(text.contains("\"asOf\":\"2026-11-09\""))
    #expect(try SnapshotJSON.decode(SnapshotRates.self, text) == rates)
    #expect(rates.convert(100_00, from: .EUR, to: .UAH) == 4_500_00)
    #expect(rates.convert(4_500_00, from: .UAH, to: .EUR) == 100_00)
    #expect(rates.convert(100_00, from: .PLN, to: .PLN) == 100_00)
    #expect(rates.convert(100_00, from: .USD, to: .UAH) == nil)
    let start = SnapshotStartBalances(
      accounts: [SnapshotAccountBalance(accountID: UUID(), currency: .PLN, isLiability: false, balanceMinor: -5)],
      debts: [.EUR: 7])
    #expect(try SnapshotJSON.decode(SnapshotStartBalances.self, try SnapshotJSON.encode(start)) == start)
  }
}
