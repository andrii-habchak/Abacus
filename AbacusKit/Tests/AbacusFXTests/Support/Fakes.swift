import AbacusDomain
import Foundation
import Synchronization

@testable import AbacusFX

/// `RateStore` in memory. Mirrors the schema: rows are upserted by id, and the UNIQUE index on
/// `(day, base, quote, provider)` rejects a second row with another id.
actor InMemoryRateStore: RateStore {
  struct Failure: Error {}

  private(set) var rows: [UUID: FXRate] = [:]
  private(set) var overrideRows: [UUID: FXOverride] = [:]
  private(set) var saveCalls = 0
  var failSaves = false
  var failLoads = false

  init(rates: [FXRate] = [], overrides: [FXOverride] = []) {
    for rate in rates { rows[rate.id] = rate }
    for override in overrides { overrideRows[override.id] = override }
  }

  func setFailSaves(_ value: Bool) { failSaves = value }

  func rates(from: Day, to: Day) async throws -> [FXRate] {
    if failLoads { throw Failure() }
    return rows.values.filter { $0.day >= from.string && $0.day <= to.string }
  }

  func latestRates() async throws -> [FXRate] {
    guard let day = rows.values.map(\.day).max() else { return [] }
    return rows.values.filter { $0.day == day }
  }

  func save(_ rates: [FXRate]) async throws {
    saveCalls += 1
    if failSaves { throw Failure() }
    for rate in rates {
      if let clash = rows.values.first(where: {
        $0.id != rate.id && $0.day == rate.day && $0.base == rate.base && $0.quote == rate.quote
          && $0.provider == rate.provider
      }) {
        throw UniqueViolation(existing: clash.id)
      }
      rows[rate.id] = rate
    }
  }

  struct UniqueViolation: Error { var existing: UUID }

  func overrides() async throws -> [FXOverride] { Array(overrideRows.values) }
  func save(_ override: FXOverride) async throws { overrideRows[override.id] = override }
  func deleteOverride(_ id: FXOverride.ID) async throws { overrideRows[id] = nil }
}

/// An official source over a fixed set of business-day rates (like Frankfurter: no weekend
/// rows). Records every request; can be switched to fail.
final class ScriptedSource: OfficialRateSource, Sendable {
  let name: String
  private let state: Mutex<(rates: [FXRate], calls: [ClosedRange<Day>], failing: Bool)>

  init(_ rates: [FXRate], name: String = "Frankfurter/NBU") {
    self.name = name
    state = Mutex((rates, [], false))
  }

  var calls: [ClosedRange<Day>] { state.withLock { $0.calls } }
  func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }
  func add(_ rates: [FXRate]) { state.withLock { $0.rates += rates } }

  func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    try state.withLock { state in
      state.calls.append(from...to)
      if state.failing { throw FXError.allProvidersFailed(["\(name): network error: offline"]) }
      return state.rates.filter {
        currencies.contains($0.base) && $0.day >= from.string && $0.day <= to.string
      }
    }
  }
}

/// A settable clock for "now".
final class TestClock: Sendable {
  private let value: Mutex<Date>
  init(_ date: Date) { value = Mutex(date) }
  var now: Date { value.withLock { $0 } }
  func set(_ date: Date) { value.withLock { $0 = date } }
  func advance(hours: Double) { value.withLock { $0 = $0.addingTimeInterval(hours * 3600) } }
  var closure: @Sendable () -> Date { { self.now } }
}

let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

/// `YYYY-MM-DD hh:mm` in UTC.
func at(_ text: String) -> Date {
  let formatter = DateFormatter()
  formatter.calendar = utc
  formatter.timeZone = utc.timeZone
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HH:mm"
  return formatter.date(from: text)!
}

/// Synthetic business-day rates `from...to` (weekends skipped), values rising by day.
func businessDays(from: Day, to: Day, fetchedAt: Date = at("2024-01-01 00:00")) -> [FXRate] {
  var rates: [FXRate] = []
  var day = from
  var index = 0
  while day <= to {
    let weekday = utc.component(.weekday, from: day.date(calendar: utc))
    if weekday != 1 && weekday != 7 {
      let step = Decimal(index) / 100
      rates += official(day.string, usd: 37 + step, eur: 41 + step, pln: 9 + step, fetchedAt: fetchedAt)
      index += 1
    }
    day = day.adding(days: 1, calendar: utc)
  }
  return rates
}
