import Foundation

// N5 (R-REC-17…20): forecast snapshots. The header row stores the start balances and the rates as
// JSON (read whole); the expected occurrences are rows (`ForecastSnapshotItem`).

/// The rates a snapshot was taken with (R-REC-19): `1 currency = toBase[currency] base`. Stored in
/// `ForecastSnapshot.ratesJSON` so an old snapshot converts the same way forever.
public struct SnapshotRates: Hashable, Sendable, Codable {
  /// The day the rates are from ("rates as of"); nil when no rate was known.
  public var asOf: Day?
  public var base: Currency
  /// Value of one unit of the key currency in `base`. `base` itself is implied (1).
  public var toBase: [Currency: Decimal]

  public init(asOf: Day?, base: Currency, toBase: [Currency: Decimal]) {
    self.asOf = asOf
    self.base = base
    self.toBase = toBase
  }

  /// The latest known rates of `currencies` to `base` (R-REC-13: today's rates, flat).
  /// Currencies without a rate are left out (and stay unconverted when read).
  public static func latest(
    from converter: any CurrencyConverter, currencies: some Sequence<Currency>, base: Currency = .UAH
  ) -> SnapshotRates {
    var toBase: [Currency: Decimal] = [:]
    for currency in Set(currencies) where currency != base {
      if let rate = converter.latestRate(from: currency, to: base) { toBase[currency] = rate }
    }
    return SnapshotRates(asOf: converter.latestDay, base: base, toBase: toBase)
  }

  /// `1 from = rate(from:to:) to`, nil when either side has no rate.
  public func rate(from: Currency, to: Currency) -> Decimal? {
    if from == to { return 1 }
    guard let a = from == base ? 1 : toBase[from], let b = to == base ? 1 : toBase[to], b != 0 else { return nil }
    return a / b
  }

  /// `minor` in `from` converted to `to` (banker's rounding), nil without a rate.
  public func convert(_ minor: Int64, from: Currency, to: Currency) -> Int64? {
    if from == to { return minor }
    guard let rate = rate(from: from, to: to) else { return nil }
    return Money(Money(minorUnits: minor, currency: from).decimal * rate, to).minorUnits
  }

  /// A closure in the shape `Forecast.netWorth(convert:)` takes.
  public func converter(to currency: Currency) -> @Sendable (Currency, Int64) -> Int64? {
    let rates = self
    return { from, minor in rates.convert(minor, from: from, to: currency) }
  }

  // JSON: {"asOf": "2026-11-03", "base": "UAH", "rates": {"EUR": "48.12"}}; decimals as strings
  // so nothing is lost to binary floating point.
  enum CodingKeys: String, CodingKey { case asOf, base, rates }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    asOf = try c.decodeIfPresent(String.self, forKey: .asOf).flatMap(Day.init)
    base = try c.decode(Currency.self, forKey: .base)
    let raw = try c.decodeIfPresent([String: String].self, forKey: .rates) ?? [:]
    var toBase: [Currency: Decimal] = [:]
    for (key, value) in raw {
      if let currency = Currency(rawValue: key), let rate = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
        toBase[currency] = rate
      }
    }
    self.toBase = toBase
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(asOf?.string, forKey: .asOf)
    try c.encode(base, forKey: .base)
    var raw: [String: String] = [:]
    for (currency, rate) in toBase { raw[currency.rawValue] = NSDecimalNumber(decimal: rate).description(withLocale: Locale(identifier: "en_US_POSIX")) }
    try c.encode(raw, forKey: .rates)
  }
}

/// One account's balance at the start of a snapshot (end of the snapshot day, R-ACC-3).
public struct SnapshotAccountBalance: Hashable, Sendable, Codable {
  public var accountID: Account.ID
  public var currency: Currency
  public var isLiability: Bool
  /// Signed, in the account's currency.
  public var balanceMinor: Int64

  public init(accountID: Account.ID, currency: Currency, isLiability: Bool, balanceMinor: Int64) {
    self.accountID = accountID
    self.currency = currency
    self.isLiability = isLiability
    self.balanceMinor = balanceMinor
  }
}

/// `ForecastSnapshot.startBalancesJSON`: the non-archived accounts at the snapshot day and the
/// debt terms that counted in net worth (R-REC-13, held at that day's value for the horizon).
public struct SnapshotStartBalances: Hashable, Sendable, Codable {
  public var accounts: [SnapshotAccountBalance]
  /// Signed debt terms per currency (owed to me positive), added to net worth unchanged.
  public var debts: [Currency: Int64]

  public init(accounts: [SnapshotAccountBalance], debts: [Currency: Int64] = [:]) {
    self.accounts = accounts
    self.debts = debts
  }

  public func balance(of accountID: Account.ID) -> SnapshotAccountBalance? {
    accounts.first { $0.accountID == accountID }
  }

  enum CodingKeys: String, CodingKey { case accounts, debts }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    accounts = try c.decodeIfPresent([SnapshotAccountBalance].self, forKey: .accounts) ?? []
    let raw = try c.decodeIfPresent([String: Int64].self, forKey: .debts) ?? [:]
    var debts: [Currency: Int64] = [:]
    for (key, value) in raw { if let currency = Currency(rawValue: key) { debts[currency] = value } }
    self.debts = debts
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(accounts, forKey: .accounts)
    try c.encode(Dictionary(uniqueKeysWithValues: debts.map { ($0.key.rawValue, $0.value) }), forKey: .debts)
  }
}

/// JSON helpers for the two snapshot columns (sorted keys, so equal content gives equal text).
public enum SnapshotJSON {
  public static func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  public static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
  }
}

/// A loaded snapshot: header, decoded JSON columns and its expected occurrences.
public struct ForecastSnapshotContent: Hashable, Sendable {
  public var snapshot: ForecastSnapshot
  public var start: SnapshotStartBalances
  public var rates: SnapshotRates
  /// Ordered by day.
  public var items: [ForecastSnapshotItem]

  public init(snapshot: ForecastSnapshot, start: SnapshotStartBalances, rates: SnapshotRates, items: [ForecastSnapshotItem]) {
    self.snapshot = snapshot
    self.start = start
    self.rates = rates
    self.items = items
  }

  public var takenDay: Day? { Day(snapshot.takenDay) }
}

/// One row of the "Compare with a past forecast" picker (R-REC-19: day, "N days ago", end value).
public struct ForecastSnapshotSummary: Hashable, Sendable, Identifiable {
  public var id: ForecastSnapshot.ID
  public var takenDay: Day
  public var horizonDays: Int
  public var createdAt: Date
  public var start: SnapshotStartBalances
  public var rates: SnapshotRates
  /// Projected balance per account at the end of the horizon (start + all item effects).
  public var endBalances: [Account.ID: Int64]

  public init(
    id: ForecastSnapshot.ID, takenDay: Day, horizonDays: Int, createdAt: Date, start: SnapshotStartBalances,
    rates: SnapshotRates, endBalances: [Account.ID: Int64]
  ) {
    self.id = id
    self.takenDay = takenDay
    self.horizonDays = horizonDays
    self.createdAt = createdAt
    self.start = start
    self.rates = rates
    self.endBalances = endBalances
  }

  public func daysAgo(today: Day) -> Int { takenDay.daysUntil(today) }

  /// Net worth at the end of the horizon in `currency` at the snapshot's rates, plus its debts;
  /// nil when some account or debt currency has no stored rate.
  public func endNetWorth(in currency: Currency) -> Int64? {
    var total: Int64 = 0
    for account in start.accounts {
      guard let value = rates.convert(endBalances[account.accountID] ?? account.balanceMinor, from: account.currency, to: currency)
      else { return nil }
      total += value
    }
    for (debtCurrency, minor) in start.debts {
      guard let value = rates.convert(minor, from: debtCurrency, to: currency) else { return nil }
      total += value
    }
    return total
  }
}

/// Forecast snapshots (R-REC-17, R-REC-18). Implemented by AbacusStore.
public protocol ForecastSnapshotRepository: Sendable {
  /// R-REC-17: stores today's snapshot when none exists for `today` and at least one active
  /// scheduled item exists; then prunes (R-REC-18). Callers run matching first. The horizon is
  /// the `forecastHorizonDays` setting (default 90). Returns the new snapshot, nil when nothing
  /// was taken.
  @discardableResult
  func takeIfNeeded(today: Day, rates: SnapshotRates, debts: [Currency: Int64]) async throws -> ForecastSnapshot?
  /// R-REC-18: retention relative to `today`; also removes sync duplicates of one day (the
  /// newest `createdAt` stays). Returns the number of snapshots deleted.
  @discardableResult
  func prune(today: Day) async throws -> Int
  /// The picker list, newest day first, one per `takenDay` (newest `createdAt` wins).
  func snapshots() async throws -> [ForecastSnapshotSummary]
  /// One snapshot with its items.
  func snapshot(_ id: ForecastSnapshot.ID) async throws -> ForecastSnapshotContent?
  /// The snapshot of one day (deduplicated), if any.
  func snapshot(takenOn day: Day) async throws -> ForecastSnapshotContent?
}

extension ForecastSnapshotRepository {
  /// A snapshot without debt terms.
  @discardableResult
  public func takeIfNeeded(today: Day, rates: SnapshotRates) async throws -> ForecastSnapshot? {
    try await takeIfNeeded(today: today, rates: rates, debts: [:])
  }
}
