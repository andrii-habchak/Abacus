import AbacusDomain
import Foundation

/// Where a rate came from (rates screen badge, R-FX-2/5).
public enum RateSource: Hashable, Sendable {
  /// Same currency on both sides.
  case identity
  /// A fetched official rate; the provider tag of its `FXRate` (e.g. "NBU").
  case official(provider: String)
  /// A user-set rate (`FXOverride.id`).
  case manual(overrideID: UUID)

  public var isManual: Bool { if case .manual = self { true } else { false } }
  /// "Manual" or "NBU" — every provider serves NBU rates (D8).
  public var badge: String {
    switch self {
    case .manual: "Manual"
    case .official, .identity: "NBU"
    }
  }
}

/// A rate together with the day it is from (which is earlier than the asked day on weekends
/// and holidays, R-FX-1) and its source.
public struct RateQuote: Hashable, Sendable {
  /// `1 from = rate to`.
  public var rate: Decimal
  /// For cross rates the older of the two legs' days.
  public var day: Day
  /// For cross rates a manual leg wins, else the first leg's provider.
  public var source: RateSource

  public init(rate: Decimal, day: Day, source: RateSource) {
    self.rate = rate
    self.day = day
    self.source = source
  }
}

/// In-memory rates and manual overrides answering `CurrencyConverter` synchronously, so
/// aggregates over thousands of transactions stay fast (R-FX-3, R-NF-2).
///
/// - Official rates are kept as `1 X = r UAH` series; any pair is a cross rate through UAH.
/// - A day without a rate (weekend, holiday, not yet published) uses the most recent earlier
///   rate (R-FX-1); before the first known rate the answer is nil.
/// - Manual overrides (R-FX-2) win for their days: an override for the exact pair (or its
///   inverse) wins over everything; an override against UAH also feeds cross rates. Among
///   overrides active on a day the latest `fromDay` wins, a bounded one before an open one, so
///   a one-day override inside a "from this day on" one wins on that day, and a newer "from
///   this day on" override ends an older one.
public struct RateTable: CurrencyConverter, Sendable, Equatable {
  struct Point: Equatable, Sendable {
    var key: Int
    var uahPerUnit: Decimal
    var rate: FXRate
  }

  private var series: [Currency: [Point]] = [:]
  private var overridesByPair: [Pair: [ActiveRange]] = [:]
  /// Every official day with at least one rate, sorted (for coverage checks).
  private var officialDays: [Int] = []

  /// All overrides, newest `fromDay` first.
  public private(set) var overrides: [FXOverride] = []
  /// Reference day for `latestRate` (net worth "now"). When nil, `latestDay` is used.
  public var today: Day?

  public init(rates: [FXRate] = [], overrides: [FXOverride] = [], today: Day? = nil) {
    self.today = today
    merge(rates)
    setOverrides(overrides)
  }

  // MARK: Loading

  /// Adds or replaces official rates. Pairs not involving UAH are ignored: every official rate
  /// is published against UAH. When two rates exist for one currency and day (e.g. from both
  /// providers), the most recently fetched one is kept.
  public mutating func merge(_ rates: [FXRate]) {
    guard !rates.isEmpty else { return }
    var incoming: [Currency: [Point]] = [:]
    for rate in rates {
      guard rate.rateE8 > 0, let day = Day(rate.day) else { continue }
      if rate.quote == AbacusFX.pivot, rate.base != AbacusFX.pivot {
        incoming[rate.base, default: []].append(
          Point(key: Self.key(day), uahPerUnit: RateScale.decimal(rate.rateE8), rate: rate))
      } else if rate.base == AbacusFX.pivot, rate.quote != AbacusFX.pivot {
        incoming[rate.quote, default: []].append(
          Point(key: Self.key(day), uahPerUnit: 1 / RateScale.decimal(rate.rateE8), rate: rate))
      }
    }
    guard !incoming.isEmpty else { return }
    for (currency, points) in incoming {
      var byDay = Dictionary((series[currency] ?? []).map { ($0.key, $0) }) { a, _ in a }
      for point in points {
        if let existing = byDay[point.key], existing.rate.fetchedAt > point.rate.fetchedAt { continue }
        byDay[point.key] = point
      }
      series[currency] = byDay.values.sorted { $0.key < $1.key }
    }
    officialDays = Array(Set(series.values.flatMap { $0.map(\.key) })).sorted()
  }

  public mutating func setOverrides(_ overrides: [FXOverride]) {
    let sorted = overrides.sorted(by: Self.precedes)
    self.overrides = sorted
    overridesByPair = Dictionary(
      grouping: sorted.compactMap { override -> ActiveRange? in
        guard override.rateE8 > 0, let from = Day(override.fromDay) else { return nil }
        var until: Int?
        if let text = override.untilDay {
          guard let day = Day(text) else { return nil }
          until = Self.key(day)
        }
        return ActiveRange(override: override, from: Self.key(from), until: until)
      }
    ) { Pair($0.override.base, $0.override.quote) }
  }

  /// Every official rate held, oldest first.
  public var officialRates: [FXRate] {
    series.values.flatMap { $0.map(\.rate) }.sorted { ($0.day, $0.base.rawValue) < ($1.day, $1.base.rawValue) }
  }

  /// The stored official rate of `currency` (against UAH) for exactly `day`.
  public func storedRate(_ currency: Currency, on day: Day) -> FXRate? {
    guard let points = series[currency] else { return nil }
    let key = Self.key(day)
    let index = Self.firstIndex(in: points, after: key - 1)
    return index < points.count && points[index].key == key ? points[index].rate : nil
  }

  // MARK: CurrencyConverter

  /// Same answer as `quote(…)?.rate` without building quotes: this is the hot path of every
  /// aggregate.
  public func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
    if from == to { return 1 }
    let key = Self.key(day)
    if !overridesByPair.isEmpty {
      if let override = activeOverride(Pair(from, to), key: key) {
        return RateScale.decimal(override.rateE8)
      }
      if let override = activeOverride(Pair(to, from), key: key) {
        return 1 / RateScale.decimal(override.rateE8)
      }
    }
    guard let base = uahValue(from, key: key) else { return nil }
    if to == AbacusFX.pivot { return base }
    guard let quote = uahValue(to, key: key) else { return nil }
    return from == AbacusFX.pivot ? 1 / quote : base / quote
  }

  private func uahValue(_ currency: Currency, key: Int) -> Decimal? {
    if currency == AbacusFX.pivot { return 1 }
    if !overridesByPair.isEmpty {
      if let override = activeOverride(Pair(currency, AbacusFX.pivot), key: key) {
        return RateScale.decimal(override.rateE8)
      }
      if let override = activeOverride(Pair(AbacusFX.pivot, currency), key: key) {
        return 1 / RateScale.decimal(override.rateE8)
      }
    }
    guard let points = series[currency] else { return nil }
    let index = Self.firstIndex(in: points, after: key) - 1
    return index >= 0 ? points[index].uahPerUnit : nil
  }

  public func latestRate(from: Currency, to: Currency) -> Decimal? {
    guard let day = referenceDay else { return from == to ? 1 : nil }
    return rate(from: from, to: to, on: day)
  }

  /// The newest day any official rate is for ("rates as of", R-FX-4).
  public var latestDay: Day? {
    series.values.compactMap { $0.last?.rate.day }.max().flatMap(Day.init)
  }

  /// The day `latestRate` evaluates at: `today`, else `latestDay`, else the newest override.
  public var referenceDay: Day? {
    today ?? latestDay ?? overrides.first.flatMap { Day($0.fromDay) }
  }

  // MARK: Quotes

  /// `1 from = rate to` on `day` with its effective day and source. With
  /// `includeOverrides: false` only fetched rates are used (the "fetched rate" shown next to a
  /// manual one).
  public func quote(from: Currency, to: Currency, on day: Day, includeOverrides: Bool = true)
    -> RateQuote?
  {
    if from == to { return RateQuote(rate: 1, day: day, source: .identity) }
    let key = Self.key(day)
    if includeOverrides, let manual = directOverride(from: from, to: to, key: key) {
      return manual
    }
    guard let baseLeg = uahLeg(from, key: key, includeOverrides: includeOverrides),
      let quoteLeg = uahLeg(to, key: key, includeOverrides: includeOverrides)
    else { return nil }
    let legs = [baseLeg, quoteLeg].compactMap { $0 }
    let source =
      legs.first(where: { $0.source.isManual })?.source ?? legs.first?.source ?? .identity
    let legDay = legs.map(\.day).min() ?? day
    return RateQuote(rate: (baseLeg?.rate ?? 1) / (quoteLeg?.rate ?? 1), day: legDay, source: source)
  }

  /// The official rate of `currency` on exactly `day` or the most recent earlier day.
  public func officialQuote(_ currency: Currency, on day: Day) -> RateQuote? {
    if currency == AbacusFX.pivot { return RateQuote(rate: 1, day: day, source: .identity) }
    guard let points = series[currency] else { return nil }
    let index = Self.firstIndex(in: points, after: Self.key(day)) - 1
    guard index >= 0 else { return nil }
    let point = points[index]
    return RateQuote(
      rate: point.uahPerUnit, day: Day(point.rate.day)!, source: .official(provider: point.rate.provider))
  }

  /// The override that applies to the exact pair `base/quote` on `day`, if any.
  public func activeOverride(base: Currency, quote: Currency, on day: Day) -> FXOverride? {
    activeOverride(Pair(base, quote), key: Self.key(day))
  }

  /// Official days strictly before `day` (newest first), limited to `count`.
  func officialDays(before day: Day, for currencies: Set<Currency>, count: Int) -> [Day] {
    let keys = currencies.subtracting([AbacusFX.pivot]).flatMap { currency in
      (series[currency] ?? []).map(\.key)
    }
    let limit = Self.key(day)
    return Array(Set(keys.filter { $0 < limit })).sorted(by: >).prefix(count).map(Self.day)
  }

  /// Whether `day` needs no fetch: it has a rate, or it lies in a gap of at most `gap` days
  /// between two known days (a weekend or holiday inside data already fetched).
  func covers(_ day: Day, gap: Int) -> Bool {
    guard !officialDays.isEmpty else { return false }
    let key = Self.key(day)
    let index = Self.firstIndex(in: officialDays, after: key - 1)
    if index < officialDays.count, officialDays[index] == key { return true }
    guard index > 0, index < officialDays.count else { return false }
    let before = Self.day(officialDays[index - 1])
    let after = Self.day(officialDays[index])
    return before >= day.adding(days: -gap, calendar: .fxDays)
      && after <= day.adding(days: gap, calendar: .fxDays)
  }

  /// Whether any official rate exists on a day in `from..<before`.
  func hasOfficialDay(from: Day, before: Day) -> Bool {
    let index = Self.firstIndex(in: officialDays, after: Self.key(from) - 1)
    return index < officialDays.count && officialDays[index] < Self.key(before)
  }

  // MARK: Internals

  /// `1 currency = r UAH`; `.some(nil)` for UAH itself.
  private func uahLeg(_ currency: Currency, key: Int, includeOverrides: Bool) -> RateQuote?? {
    if currency == AbacusFX.pivot { return .some(nil) }
    if includeOverrides {
      if let override = activeOverride(Pair(currency, AbacusFX.pivot), key: key) {
        return manualQuote(override, inverted: false, key: key)
      }
      if let override = activeOverride(Pair(AbacusFX.pivot, currency), key: key) {
        return manualQuote(override, inverted: true, key: key)
      }
    }
    guard let points = series[currency] else { return nil }
    let index = Self.firstIndex(in: points, after: key) - 1
    guard index >= 0 else { return nil }
    let point = points[index]
    return RateQuote(
      rate: point.uahPerUnit, day: Self.day(point.key), source: .official(provider: point.rate.provider))
  }

  private func directOverride(from: Currency, to: Currency, key: Int) -> RateQuote? {
    if let override = activeOverride(Pair(from, to), key: key) {
      return manualQuote(override, inverted: false, key: key)
    }
    if let override = activeOverride(Pair(to, from), key: key) {
      return manualQuote(override, inverted: true, key: key)
    }
    return nil
  }

  private func manualQuote(_ override: FXOverride, inverted: Bool, key: Int) -> RateQuote {
    let value = RateScale.decimal(override.rateE8)
    return RateQuote(
      rate: inverted ? 1 / value : value, day: Self.day(key), source: .manual(overrideID: override.id))
  }

  private func activeOverride(_ pair: Pair, key: Int) -> FXOverride? {
    overridesByPair[pair]?.first { $0.from <= key && $0.until.map { key <= $0 } ?? true }?.override
  }

  /// Precedence: later `fromDay` first; on the same day a bounded override before an open one.
  private static func precedes(_ a: FXOverride, _ b: FXOverride) -> Bool {
    if a.fromDay != b.fromDay { return a.fromDay > b.fromDay }
    if (a.untilDay == nil) != (b.untilDay == nil) { return a.untilDay != nil }
    return (a.untilDay ?? "", a.id.uuidString) < (b.untilDay ?? "", b.id.uuidString)
  }

  struct ActiveRange: Equatable, Sendable {
    var override: FXOverride
    var from: Int
    var until: Int?
  }

  struct Pair: Hashable, Sendable {
    var base: Currency
    var quote: Currency
    init(_ base: Currency, _ quote: Currency) {
      self.base = base
      self.quote = quote
    }
  }

  static func key(_ day: Day) -> Int { day.year * 10_000 + day.month * 100 + day.day }
  static func day(_ key: Int) -> Day { Day(year: key / 10_000, month: key / 100 % 100, day: key % 100) }

  /// Index of the first point with `key > after`.
  private static func firstIndex(in points: [Point], after: Int) -> Int {
    var low = 0
    var high = points.count
    while low < high {
      let mid = (low + high) / 2
      if points[mid].key <= after { low = mid + 1 } else { high = mid }
    }
    return low
  }

  private static func firstIndex(in keys: [Int], after: Int) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] <= after { low = mid + 1 } else { high = mid }
    }
    return low
  }
}
