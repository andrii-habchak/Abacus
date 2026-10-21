import Foundation

/// Namespace for the pure calculators (WP A1): transaction effects and balances, net worth,
/// budget status, event totals, category roll-ups. No I/O here — inputs are entities and a
/// `CurrencyConverter`, outputs are values.
///
/// Conventions shared by every calculator:
/// - Transactions come as `TxnWithLines` (a transaction with its attached records).
/// - A transaction's day is `Day(txn.occurredAt, calendar:)`; pass the same calendar the UI uses.
/// - Period aggregates convert each amount at the rate of its own day; net worth today uses the
///   latest rate (R-FX-3). An amount whose rate is unknown is left out and recorded in
///   `Unconverted` — it is never converted at 1.
public enum Calc {}

/// Which rate converts an amount (R-FX-3).
public enum RateDate: Hashable, Sendable {
  /// The rate of that day (period aggregates, month-end net worth).
  case day(Day)
  /// The most recent rate known (today's net worth).
  case latest

  var day: Day? {
    if case .day(let day) = self { return day }
    return nil
  }
}

/// A rate the converter did not know; `day == nil` means the latest rate. Callers can use these
/// to fetch the missing historical rates lazily (R-FX-1).
public struct MissingRate: Hashable, Sendable {
  public let from: Currency
  public let to: Currency
  public let day: Day?

  public init(from: Currency, to: Currency, day: Day?) {
    self.from = from
    self.to = to
    self.day = day
  }
}

/// Amounts left out of a result because they could not be converted: no rate was known, or the
/// transaction's account was not among the accounts passed in. Empty when the result is complete.
public struct Unconverted: Hashable, Sendable {
  /// How many amounts (transactions, attached records or account balances) were left out.
  public internal(set) var count: Int = 0
  public internal(set) var missingRates: Set<MissingRate> = []
  /// Accounts referenced by transactions but not passed in (their currency is unknown).
  public internal(set) var unknownAccountIDs: Set<Account.ID> = []

  public init() {}

  public var isEmpty: Bool { count == 0 }

  mutating func record(_ missing: MissingRate) {
    count += 1
    missingRates.insert(missing)
  }

  mutating func recordUnknownAccount(_ id: Account.ID) {
    count += 1
    unknownAccountIDs.insert(id)
  }
}

/// Spending against a limit (R-HOME-2): over when spent exceeds the limit, near at ≥ 90 %.
public enum LimitStatus: String, Hashable, Sendable {
  case ok, near, over
}

extension Calc {
  /// ok / near (≥ 90 % of the limit) / over (spent > limit). A limit of zero or less is over as
  /// soon as anything is spent.
  public static func limitStatus(spentMinor: Int64, limitMinor: Int64) -> LimitStatus {
    if spentMinor > limitMinor { return .over }
    if limitMinor > 0, spentMinor * 10 >= limitMinor * 9 { return .near }
    return .ok
  }

  /// `spent / limit` as a fraction (1 = 100 %), nil when the limit is not positive.
  public static func fractionUsed(spentMinor: Int64, limitMinor: Int64) -> Decimal? {
    guard limitMinor > 0 else { return nil }
    return Decimal(spentMinor) / Decimal(limitMinor)
  }

  /// Converts minor units; on a missing rate records it in `gaps` and returns nil.
  static func convert(
    _ minor: Int64, from: Currency, to: Currency, at rateDate: RateDate,
    using converter: some CurrencyConverter, gaps: inout Unconverted
  ) -> Int64? {
    if from == to { return minor }
    let money = Money(minorUnits: minor, currency: from)
    let converted =
      switch rateDate {
      case .day(let day): converter.convert(money, to: to, on: day)
      case .latest: converter.convertAtLatest(money, to: to)
      }
    guard let converted else {
      gaps.record(MissingRate(from: from, to: to, day: rateDate.day))
      return nil
    }
    return converted.minorUnits
  }
}
