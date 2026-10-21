import AbacusDomain
import Foundation

/// Official NBU rates through Frankfurter v2 (DECISIONS D8, R-FX-1):
/// `GET /v2/rates?base=X&quotes=UAH&date=YYYY-MM-DD&providers=NBU` (or `from`/`to` for a range).
///
/// `providers=NBU` is required, otherwise Frankfurter blends several central banks. Only
/// `base=X&quotes=UAH` returns the NBU's exact numbers (other bases are derived and rounded), so
/// a request is made per non-UAH currency. The response is a flat array
/// `[{"date","base","quote","rate"}]`; weekends and holidays are absent from ranges, and a
/// single weekend `date` answers with the previous business day.
public struct FrankfurterNBUProvider: OfficialRateSource {
  public static let defaultBaseURL = URL(string: "https://api.frankfurter.dev/v2/rates")!
  public static let providerName = "Frankfurter/NBU"

  public var name: String { Self.providerName }
  public let session: URLSession
  public let baseURL: URL
  private let now: @Sendable () -> Date

  public init(
    session: URLSession = .shared, baseURL: URL = Self.defaultBaseURL,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.session = session
    self.baseURL = baseURL
    self.now = now
  }

  public func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    let bases = Array(Set(currencies).subtracting([AbacusFX.pivot])).sorted { $0.rawValue < $1.rawValue }
    guard !bases.isEmpty, from <= to else { return [] }
    return try await withThrowingTaskGroup(of: [FXRate].self) { group in
      for base in bases {
        group.addTask {
          try await fetch(base: base, quotes: [AbacusFX.pivot], from: from, to: to)
        }
      }
      var all: [FXRate] = []
      for try await rates in group { all += rates }
      return all.sorted { ($0.day, $0.base.rawValue) < ($1.day, $1.base.rawValue) }
    }
  }

  /// The request URL. A single day uses `date=`, so that a weekend still yields the previous
  /// business day; a range uses `from`/`to`.
  public func url(base: Currency, quotes: [Currency], from: Day, to: Day) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "base", value: base.rawValue),
      URLQueryItem(name: "quotes", value: quotes.map(\.rawValue).joined(separator: ",")),
    ]
    if from == to {
      items.append(URLQueryItem(name: "date", value: from.string))
    } else {
      items.append(URLQueryItem(name: "from", value: from.string))
      items.append(URLQueryItem(name: "to", value: to.string))
    }
    items.append(URLQueryItem(name: "providers", value: "NBU"))
    components.queryItems = items
    return components.url!
  }

  func fetch(base: Currency, quotes: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    let (data, status) = try await HTTP.get(url(base: base, quotes: quotes, from: from, to: to), session: session)
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
      throw FXError.http(status: status, message: message)
    }
    return try Self.parse(data, provider: name, fetchedAt: now())
  }

  /// Parses a v2 `/rates` body. Rows with currencies outside `Currency` are skipped.
  public static func parse(_ data: Data, provider: String = providerName, fetchedAt: Date = Date())
    throws -> [FXRate]
  {
    let rows: [Row]
    do {
      rows = try JSONDecoder().decode([Row].self, from: data)
    } catch {
      let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
      throw FXError.invalidResponse(message ?? "Frankfurter: \(error)")
    }
    return try rows.compactMap { row in
      guard let base = Currency(rawValue: row.base), let quote = Currency(rawValue: row.quote),
        base != quote
      else { return nil }
      guard let day = Day(row.date), day.string == row.date else {
        throw FXError.invalidResponse("Frankfurter: bad date \(row.date)")
      }
      guard row.rate > 0 else { throw FXError.invalidResponse("Frankfurter: rate \(row.rate)") }
      return FXRate(
        day: day.string, base: base, quote: quote, rateE8: RateScale.scaled(row.rate),
        provider: provider, fetchedAt: fetchedAt)
    }
  }

  struct Row: Decodable {
    var date: String
    var base: String
    var quote: String
    var rate: Decimal
  }

  struct ErrorBody: Decodable {
    var status: Int?
    var message: String
  }
}
