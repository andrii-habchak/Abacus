import AbacusDomain
import Foundation
import Testing

@Suite("Money and days")
struct MoneyTests {
  @Test("R-CUR-2: decimal amounts round to minor units with banker's rounding")
  func bankersRounding() {
    #expect(Money(Decimal(string: "10.005")!, .PLN).minorUnits == 1000)
    #expect(Money(Decimal(string: "10.015")!, .PLN).minorUnits == 1002)
    #expect(Money(Decimal(string: "-3.335")!, .UAH).minorUnits == -334)
  }

  @Test("R-CUR-2: arithmetic stays exact")
  func arithmetic() {
    let a = Money(minorUnits: 10, currency: .EUR)
    let b = Money(minorUnits: 20, currency: .EUR)
    #expect((a + b).minorUnits == 30)
    #expect((a - b).decimal == Decimal(string: "-0.1")!)
  }

  @Test("R-CUR-4: minor units for any ISO code")
  func currencyDigits() {
    #expect(CurrencyDigits.minorUnits("JPY") == 0)
    #expect(CurrencyDigits.minorUnits("kwd") == 3)
    #expect(CurrencyDigits.minorUnits("CHF") == 2)
    #expect(CurrencyDigits.minorUnits(from: Decimal(string: "1234.5")!, code: "HUF") == 123450)
    #expect(CurrencyDigits.minorUnits(from: Decimal(string: "1.2345")!, code: "KWD") == 1234)
  }

  @Test("Rates are stored scaled by 10^8")
  func rateScale() {
    let rate = Decimal(string: "41.5872")!
    #expect(RateScale.decimal(RateScale.scaled(rate)) == rate)
  }

  @Test("Day and Month parse, format and step")
  func days() {
    let day = Day("2026-10-21")!
    #expect(day.string == "2026-10-21")
    #expect(day.adding(days: -29).string == "2026-09-22")
    #expect(Day("2026-13-01") == nil)
    #expect(Month("2026-12")!.adding(months: 1).string == "2027-01")
    #expect(Month("2026-02")!.lastDay().string == "2026-02-28")
  }

  @Test("R-LIST-1: the default list range is the last 30 days")
  func lastThirtyDays() {
    let query = TxnQuery.lastThirtyDays(today: Day("2026-10-21")!)
    #expect(query.fromDay?.string == "2026-09-22")
    #expect(query.toDay?.string == "2026-10-21")
    #expect(query.newestFirst)
  }
}
