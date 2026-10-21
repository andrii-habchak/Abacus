import AbacusDomain
import Foundation
import Testing

@testable import AbacusFX

func d(_ string: String) -> Day { Day(string)! }

private func rateMap(_ rates: [FXRate]) -> [String: Int64] {
  Dictionary(uniqueKeysWithValues: rates.map { ("\($0.day) \($0.base)/\($0.quote)", $0.rateE8) })
}

@Suite("Frankfurter v2 provider (R-FX-1)")
struct FrankfurterProviderTests {
  @Test("R-FX-1: request uses providers=NBU, base=X&quotes=UAH, date or from/to")
  func requestURL() {
    let provider = FrankfurterNBUProvider()
    let day = provider.url(base: .EUR, quotes: [.UAH], from: d("2024-01-15"), to: d("2024-01-15"))
    #expect(day.host == "api.frankfurter.dev" && day.path == "/v2/rates")
    #expect(day.queryValue("base") == "EUR")
    #expect(day.queryValue("quotes") == "UAH")
    #expect(day.queryValue("date") == "2024-01-15")
    #expect(day.queryValue("providers") == "NBU")
    #expect(!day.hasQueryItem("from"))

    let range = provider.url(base: .USD, quotes: [.UAH], from: d("2024-01-10"), to: d("2024-01-16"))
    #expect(range.queryValue("from") == "2024-01-10")
    #expect(range.queryValue("to") == "2024-01-16")
    #expect(range.queryValue("providers") == "NBU")
    #expect(!range.hasQueryItem("date"))
  }

  @Test("R-FX-1 R-CUR-2: recorded range parses to exact rates scaled ×10^8, tagged with the provider")
  func parsesRange() async throws {
    let network = StubNetwork()
    for base in ["USD", "EUR", "PLN"] {
      network.on(
        host: Fixtures.Frankfurter.host, query: ["base": base, "from": "2024-01-10"],
        body: Fixtures.Frankfurter.range(base))
    }
    let provider = FrankfurterNBUProvider(session: network.session)
    let rates = try await provider.uahRates(
      for: [.UAH, .PLN, .EUR, .USD], from: d("2024-01-10"), to: d("2024-01-16"))

    #expect(rates.count == 15)  // 5 business days × 3 currencies, weekend absent
    #expect(network.requests.count == 3)  // one per non-UAH currency
    #expect(rates.allSatisfy { $0.quote == .UAH && $0.provider == "Frankfurter/NBU" })
    let map = rateMap(rates)
    #expect(map["2024-01-15 EUR/UAH"] == 4_138_790_000)
    #expect(map["2024-01-15 USD/UAH"] == 3_783_860_000)
    #expect(map["2024-01-15 PLN/UAH"] == 948_810_000)
    #expect(map["2024-01-13 EUR/UAH"] == nil)
  }

  @Test("R-FX-1: a weekend date answers with the previous business day, tagged with its own date")
  func weekendDate() async throws {
    let network = StubNetwork()
    network.on(
      host: Fixtures.Frankfurter.host, query: ["base": "EUR", "date": "2024-01-13"],
      body: Fixtures.Frankfurter.eurSaturday)
    let provider = FrankfurterNBUProvider(session: network.session)
    let rates = try await provider.uahRates(for: [.EUR], from: d("2024-01-13"), to: d("2024-01-13"))
    #expect(rates.map(\.day) == ["2024-01-12"])
    #expect(rates.first?.rateE8 == 4_174_100_000)
  }

  @Test("Rows for other pairs and unknown currencies are kept or skipped by `Currency`")
  func parsesMultiQuote() throws {
    let rates = try FrankfurterNBUProvider.parse(Data(Fixtures.Frankfurter.eurMultiQuote.utf8))
    #expect(rateMap(rates) == [
      "2024-01-15 EUR/PLN": 436_210_000, "2024-01-15 EUR/UAH": 4_138_790_000,
      "2024-01-15 EUR/USD": 109_380_000,
    ])
  }

  @Test("HTTP 422 surfaces the server message")
  func httpError() async {
    let network = StubNetwork()
    network.on(host: Fixtures.Frankfurter.host, status: 422, body: Fixtures.Frankfurter.invalidCurrency)
    let provider = FrankfurterNBUProvider(session: network.session)
    await #expect(throws: FXError.http(status: 422, message: "invalid currency: XXX")) {
      try await provider.uahRates(for: [.EUR], from: d("2024-01-15"), to: d("2024-01-15"))
    }
  }

  @Test("Offline → transport error; non-array body → invalid response")
  func failures() async {
    let offline = StubNetwork()
    offline.fail(host: Fixtures.Frankfurter.host)
    await #expect {
      try await FrankfurterNBUProvider(session: offline.session)
        .uahRates(for: [.EUR], from: d("2024-01-15"), to: d("2024-01-15"))
    } throws: { error in
      if case FXError.transport = error { true } else { false }
    }
    #expect(throws: FXError.invalidResponse("invalid currency: XXX")) {
      try FrankfurterNBUProvider.parse(Data(Fixtures.Frankfurter.invalidCurrency.utf8))
    }
  }

  @Test("R-FX-1: RateProvider pairs are cross rates through UAH from the exact NBU legs")
  func rateProviderPairs() async throws {
    let network = StubNetwork()
    // The recorded ranges hold more days than asked; only the asked day (or the latest one
    // before it) is used.
    for base in ["USD", "EUR", "PLN"] {
      network.on(
        host: Fixtures.Frankfurter.host, query: ["base": base, "date": "2024-01-15"],
        body: Fixtures.Frankfurter.range(base))
    }
    let provider = FrankfurterNBUProvider(session: network.session)
    let rates = try await provider.rates(on: d("2024-01-15"), base: .EUR, quotes: [.UAH, .PLN, .USD, .EUR])
    let map = rateMap(rates)
    #expect(map["2024-01-15 EUR/UAH"] == 4_138_790_000)
    // 41.3879 / 9.4881 = 4.36208514…, 41.3879 / 37.8386 = 1.09380104…
    #expect(map["2024-01-15 EUR/PLN"] == 436_208_514)
    #expect(map["2024-01-15 EUR/USD"] == 109_380_104)
    #expect(map.count == 3)
    #expect(rates.allSatisfy { $0.provider == "Frankfurter/NBU" })
  }
}

@Suite("NBU fallback provider (R-FX-1)")
struct NBUProviderTests {
  @Test("R-FX-1: request is ?date=YYYYMMDD&json")
  func requestURL() {
    let url = NBUProvider().url(day: d("2024-01-05"))
    #expect(url.absoluteString
      == "https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?date=20240105&json")
  }

  @Test("R-FX-1 R-CUR-2: recorded day parses to UAH rates of tracked currencies only")
  func parsesDay() throws {
    let rates = try NBUProvider.parse(Data(Fixtures.NBU.saturday.utf8))
    #expect(rateMap(rates) == [
      "2024-01-13 USD/UAH": 3_799_820_000, "2024-01-13 EUR/UAH": 4_174_100_000,
      "2024-01-13 PLN/UAH": 960_080_000,
    ])
    #expect(rates.allSatisfy { $0.provider == "NBU" })
    let pretty = try NBUProvider.parse(Data(Fixtures.NBU.monday.utf8), currencies: [.EUR])
    #expect(rateMap(pretty) == ["2024-01-15 EUR/UAH": 4_138_790_000])
  }

  @Test("R-FX-1: a range is fetched day by day, weekend days included")
  func range() async throws {
    let network = StubNetwork()
    network.on(host: Fixtures.NBU.host, query: ["date": "20240113"], body: Fixtures.NBU.saturday)
    network.on(
      host: Fixtures.NBU.host, query: ["date": "20240114"],
      body: Fixtures.NBU.saturday.replacingOccurrences(of: "13.01.2024", with: "14.01.2024"))
    network.on(host: Fixtures.NBU.host, query: ["date": "20240115"], body: Fixtures.NBU.monday)
    let provider = NBUProvider(session: network.session)
    let rates = try await provider.uahRates(for: [.EUR, .USD], from: d("2024-01-13"), to: d("2024-01-15"))
    #expect(network.requests.count == 3)
    #expect(Set(rates.map(\.day)) == ["2024-01-13", "2024-01-14", "2024-01-15"])
    #expect(rates.count == 6)
  }

  @Test("Unpublished day → no rates; malformed body → invalid response; long range refused")
  func edges() async throws {
    #expect(try NBUProvider.parse(Data(Fixtures.NBU.empty.utf8)).isEmpty)
    #expect(throws: FXError.invalidResponse("NBU: [ { Wrong date format } ]")) {
      try NBUProvider.parse(Data(Fixtures.NBU.wrongDateFormat.utf8))
    }
    let provider = NBUProvider(session: StubNetwork().session)
    await #expect(throws: FXError.rangeTooLong(days: 32, limit: 31)) {
      try await provider.uahRates(for: [.EUR], from: d("2024-01-01"), to: d("2024-02-01"))
    }
  }

  @Test("HTTP error status is reported")
  func httpError() async {
    let network = StubNetwork()
    network.on(host: Fixtures.NBU.host, status: 503, body: "")
    await #expect(throws: FXError.http(status: 503, message: nil)) {
      try await NBUProvider(session: network.session)
        .uahRates(for: [.EUR], from: d("2024-01-15"), to: d("2024-01-15"))
    }
  }
}

@Suite("Fallback chain (R-FX-1)")
struct FallbackTests {
  @Test("R-FX-1: Frankfurter answers → NBU is not asked")
  func primaryWins() async throws {
    let network = StubNetwork()
    network.on(host: Fixtures.Frankfurter.host, query: ["base": "EUR"], body: Fixtures.Frankfurter.eurSaturday)
    network.on(host: Fixtures.NBU.host, body: Fixtures.NBU.saturday)
    let rates = try await FallbackRateSource.standard(session: network.session)
      .uahRates(for: [.EUR], from: d("2024-01-13"), to: d("2024-01-13"))
    #expect(rates.map(\.provider) == ["Frankfurter/NBU"])
    #expect(network.requests(host: Fixtures.NBU.host).isEmpty)
  }

  @Test("R-FX-1: Frankfurter fails → NBU fallback, rates tagged NBU")
  func fallsBack() async throws {
    let network = StubNetwork()
    network.on(host: Fixtures.Frankfurter.host, status: 500, body: "")
    network.on(host: Fixtures.NBU.host, query: ["date": "20240113"], body: Fixtures.NBU.saturday)
    let chain = FallbackRateSource.standard(session: network.session)
    #expect(chain.name == "Frankfurter/NBU → NBU")
    let rates = try await chain.uahRates(for: [.EUR, .PLN], from: d("2024-01-13"), to: d("2024-01-13"))
    #expect(rateMap(rates) == ["2024-01-13 EUR/UAH": 4_174_100_000, "2024-01-13 PLN/UAH": 960_080_000])
    #expect(rates.allSatisfy { $0.provider == "NBU" })
  }

  @Test("R-FX-4: both fail → one error naming every provider")
  func allFail() async {
    let network = StubNetwork()
    network.fail(host: Fixtures.Frankfurter.host)
    network.on(host: Fixtures.NBU.host, body: Fixtures.NBU.wrongDateFormat)
    await #expect {
      try await FallbackRateSource.standard(session: network.session)
        .uahRates(for: [.EUR], from: d("2024-01-15"), to: d("2024-01-15"))
    } throws: { error in
      guard case FXError.allProvidersFailed(let messages) = error else { return false }
      return messages.count == 2 && messages[0].hasPrefix("Frankfurter/NBU: network error")
        && messages[1].hasPrefix("NBU: invalid response")
    }
  }
}

/// Live smoke test, off by default: `ABACUS_LIVE_FX=1 swift test --filter LiveFX`.
@Suite("LiveFX", .enabled(if: ProcessInfo.processInfo.environment["ABACUS_LIVE_FX"] == "1"))
struct LiveFXTests {
  @Test("R-FX-1: both live endpoints return the same NBU rates for 2024-01-15")
  func live() async throws {
    let frankfurter = try await FrankfurterNBUProvider()
      .uahRates(for: [.EUR, .PLN, .USD], from: d("2024-01-15"), to: d("2024-01-15"))
    let nbu = try await NBUProvider()
      .uahRates(for: [.EUR, .PLN, .USD], from: d("2024-01-15"), to: d("2024-01-15"))
    #expect(rateMap(frankfurter) == rateMap(nbu))
    #expect(rateMap(nbu)["2024-01-15 EUR/UAH"] == 4_138_790_000)
  }
}
