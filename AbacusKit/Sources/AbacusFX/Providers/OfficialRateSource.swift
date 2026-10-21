import AbacusDomain
import Foundation

/// A source of official NBU rates in their native form, `1 X = r UAH`. Both providers and the
/// fallback chain implement it; the refresher fetches through it so a whole range costs one
/// request per currency instead of one per day.
public protocol OfficialRateSource: RateProvider {
  /// Rates `1 X = r UAH` for every `X` in `currencies` (UAH itself is skipped) on each day in
  /// `from...to` that the source publishes. Each rate carries the day it is valid for, which
  /// can be earlier than `from` when `from == to` is a weekend.
  func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate]
}

extension OfficialRateSource {
  /// `RateProvider` on top of `uahRates`: pairs other than `X/UAH` are cross rates through UAH,
  /// rounded to 8 decimals. Rates carry the day the source published them for.
  public func rates(on day: Day, base: Currency, quotes: [Currency]) async throws -> [FXRate] {
    let wanted = Array(Set([base] + quotes).subtracting([AbacusFX.pivot]))
    let fetched = try await uahRates(for: wanted, from: day, to: day)
    // Normally one day comes back; keep the latest day not after `day` for each currency.
    var perCurrency: [Currency: FXRate] = [:]
    for rate in fetched where rate.quote == AbacusFX.pivot && rate.day <= day.string {
      if let existing = perCurrency[rate.base], existing.day >= rate.day { continue }
      perCurrency[rate.base] = rate
    }
    func uah(_ currency: Currency) -> (value: Decimal, rate: FXRate?)? {
      if currency == AbacusFX.pivot { return (1, nil) }
      guard let rate = perCurrency[currency] else { return nil }
      return (RateScale.decimal(rate.rateE8), rate)
    }
    guard let baseLeg = uah(base) else { return [] }
    var result: [FXRate] = []
    for quote in quotes where quote != base {
      guard let quoteLeg = uah(quote) else { continue }
      let legs = [baseLeg.rate, quoteLeg.rate].compactMap { $0 }
      guard let anyLeg = legs.first else { continue }
      let legDay = legs.map(\.day).min() ?? anyLeg.day
      result.append(
        FXRate(
          day: legDay, base: base, quote: quote,
          rateE8: RateScale.scaled(baseLeg.value / quoteLeg.value),
          provider: anyLeg.provider, fetchedAt: anyLeg.fetchedAt))
    }
    return result
  }
}

/// Shared HTTP plumbing for the providers.
enum HTTP {
  static func get(_ url: URL, session: URLSession) async throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw FXError.transport(error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    return (data, status)
  }

  /// Days `from...to` inclusive, in order.
  static func days(from: Day, to: Day, calendar: Calendar) -> [Day] {
    var result: [Day] = []
    var day = from
    while day <= to {
      result.append(day)
      day = day.adding(days: 1, calendar: calendar)
    }
    return result
  }
}

extension Calendar {
  /// Gregorian in UTC: day arithmetic on `Day` values must not depend on the user's time zone
  /// or DST changes.
  static let fxDays: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
}
