import AbacusDomain
import Foundation

/// The NBU's own API, used as the fallback (DECISIONS D8, R-FX-1):
/// `GET https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?date=YYYYMMDD&json`.
///
/// The body is `[{"r030","txt","rate","cc","exchangedate":"dd.MM.yyyy","special"}]` with
/// `rate` = UAH per 1 unit of `cc`, for every currency the NBU publishes. Weekend dates are
/// answered too (tagged with the requested date), tomorrow's rates appear the day before, later
/// dates return `[]`, and a malformed date returns a non-JSON body with HTTP 200.
/// There is no range query, so ranges cost one request per day and are capped.
public struct NBUProvider: OfficialRateSource {
  public static let defaultBaseURL = URL(
    string: "https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange")!
  public static let providerName = "NBU"
  /// Longest range fetched day by day; longer ranges throw `FXError.rangeTooLong`.
  public static let defaultMaxDays = 31

  public var name: String { Self.providerName }
  public let session: URLSession
  public let baseURL: URL
  public let maxDays: Int
  private let now: @Sendable () -> Date

  public init(
    session: URLSession = .shared, baseURL: URL = Self.defaultBaseURL,
    maxDays: Int = Self.defaultMaxDays, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.session = session
    self.baseURL = baseURL
    self.maxDays = maxDays
    self.now = now
  }

  public func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    let wanted = Set(currencies).subtracting([AbacusFX.pivot])
    guard !wanted.isEmpty, from <= to else { return [] }
    let days = HTTP.days(from: from, to: to, calendar: .fxDays)
    guard days.count <= maxDays else {
      throw FXError.rangeTooLong(days: days.count, limit: maxDays)
    }
    var all: [FXRate] = []
    // A few requests at a time: this is a central bank's public endpoint.
    for chunk in stride(from: 0, to: days.count, by: 4).map({ Array(days[$0..<min($0 + 4, days.count)]) }) {
      try await withThrowingTaskGroup(of: [FXRate].self) { group in
        for day in chunk {
          group.addTask { try await fetch(day: day, currencies: wanted) }
        }
        for try await rates in group { all += rates }
      }
    }
    return all.sorted { ($0.day, $0.base.rawValue) < ($1.day, $1.base.rawValue) }
  }

  public func url(day: Day) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "date", value: String(format: "%04d%02d%02d", day.year, day.month, day.day)),
      URLQueryItem(name: "json", value: nil),
    ]
    return components.url!
  }

  func fetch(day: Day, currencies: Set<Currency>) async throws -> [FXRate] {
    let (data, status) = try await HTTP.get(url(day: day), session: session)
    guard (200..<300).contains(status) else { throw FXError.http(status: status, message: nil) }
    return try Self.parse(data, currencies: currencies, provider: name, fetchedAt: now())
  }

  /// Parses one day's body into `1 X = r UAH` rates for `currencies`.
  public static func parse(
    _ data: Data, currencies: Set<Currency> = Set(Currency.allCases),
    provider: String = providerName, fetchedAt: Date = Date()
  ) throws -> [FXRate] {
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      let text = String(decoding: data.prefix(80), as: UTF8.self)
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
      throw FXError.invalidResponse("NBU: \(text)")
    }
    return try rows.compactMap { row in
      guard let code = row.cc, let currency = Currency(rawValue: code),
        currency != AbacusFX.pivot, currencies.contains(currency)
      else { return nil }
      guard let rate = row.rate, rate > 0 else {
        throw FXError.invalidResponse("NBU: no rate for \(code)")
      }
      guard let text = row.exchangedate, let day = parseDay(text) else {
        throw FXError.invalidResponse("NBU: bad exchangedate \(row.exchangedate ?? "nil")")
      }
      return FXRate(
        day: day.string, base: currency, quote: AbacusFX.pivot, rateE8: RateScale.scaled(rate),
        provider: provider, fetchedAt: fetchedAt)
    }
  }

  /// `dd.MM.yyyy` → `Day`.
  static func parseDay(_ text: String) -> Day? {
    let parts = text.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[0]) else { return nil }
    return Day(year: parts[2], month: parts[1], day: parts[0])
  }

  struct Row: Decodable {
    var cc: String?
    var rate: Decimal?
    var exchangedate: String?
  }
}
