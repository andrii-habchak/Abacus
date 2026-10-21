import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Rates storage")
struct RateStoreTests {
  typealias F = StoreFixture

  static func rate(_ day: String, _ base: Currency, _ quote: Currency, _ value: Decimal, provider: String = "NBU") -> FXRate {
    FXRate(day: day, base: base, quote: quote, rateE8: RateScale.scaled(value), provider: provider)
  }

  @Test("R-FX-1: rates are cached per (day, base, quote, provider); a refetch replaces the value")
  func cache() async throws {
    let f = try F()
    try await f.rates.save([
      Self.rate("2026-03-02", .EUR, .PLN, 4.25),
      Self.rate("2026-03-03", .EUR, .PLN, 4.26),
      Self.rate("2026-03-03", .USD, .UAH, 41.5),
      Self.rate("2026-03-05", .EUR, .PLN, 4.3),
    ])
    try await f.rates.save([Self.rate("2026-03-03", .EUR, .PLN, 4.27)])
    let range = try await f.rates.rates(from: Day("2026-03-02")!, to: Day("2026-03-03")!)
    #expect(range.count == 3)
    #expect(range.first { $0.day == "2026-03-03" && $0.base == .EUR }?.rateE8 == RateScale.scaled(4.27))
    // Another provider for the same day is a separate entry.
    try await f.rates.save([Self.rate("2026-03-03", .EUR, .PLN, 4.28, provider: "ECB")])
    #expect(try await f.rates.rates(from: Day("2026-03-03")!, to: Day("2026-03-03")!).count == 3)
  }

  @Test("R-FX-1: latest rates are the most recent day per currency pair")
  func latest() async throws {
    let f = try F()
    #expect(try await f.rates.latestRates().isEmpty)
    try await f.rates.save([
      Self.rate("2026-03-02", .EUR, .PLN, 4.25),
      Self.rate("2026-03-05", .EUR, .PLN, 4.3),
      Self.rate("2026-03-03", .USD, .UAH, 41.5),
    ])
    let latest = try await f.rates.latestRates()
    #expect(latest.map(\.day) == ["2026-03-05", "2026-03-03"])
  }

  @Test("R-FX-2: manual overrides are stored, edited and removed")
  func overrides() async throws {
    let f = try F()
    var oneDay = FXOverride(base: .EUR, quote: .PLN, rateE8: RateScale.scaled(4.4), fromDay: "2026-03-02", untilDay: "2026-03-02")
    let fromDay = FXOverride(base: .EUR, quote: .PLN, rateE8: RateScale.scaled(4.5), fromDay: "2026-04-01", note: "Kantor")
    try await f.rates.save(oneDay)
    try await f.rates.save(fromDay)
    #expect(try await f.rates.overrides().map(\.id) == [fromDay.id, oneDay.id])
    oneDay.rateE8 = RateScale.scaled(4.41)
    try await f.rates.save(oneDay)
    #expect(try await f.rates.overrides().last?.rateE8 == RateScale.scaled(4.41))
    try await f.rates.deleteOverride(oneDay.id)
    #expect(try await f.rates.overrides().map(\.id) == [fromDay.id])
    await #expect(throws: RepositoryError.notFound) { try await f.rates.deleteOverride(oneDay.id) }
  }
}
