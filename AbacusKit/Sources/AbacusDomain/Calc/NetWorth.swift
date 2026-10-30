import Foundation

/// One account's line in the net-worth breakdown (R-HOME-1 "per-account breakdown").
public struct AccountValue: Hashable, Sendable, Identifiable {
  public let accountID: Account.ID
  public let isLiability: Bool
  /// In the account's own currency.
  public let balance: Money
  /// In the net worth's currency; nil when no rate was known.
  public let converted: Money?

  public var id: Account.ID { accountID }
}

/// One debt's line in net worth (R-DEBT-7, R-DEBT-18): only debts with "Count in net worth", one
/// line per currency the debt has a non-zero balance in (never netted across currencies).
public struct DebtValue: Hashable, Sendable, Identifiable {
  public let debtID: Debt.ID
  /// In the line's currency; positive = owed to me (an asset), negative = I owe (a liability).
  public let balance: Money
  /// In the net worth's currency; nil when no rate was known.
  public let converted: Money?

  public var id: String { "\(debtID.uuidString)|\(balance.currency.rawValue)" }
}

/// Net worth = assets − liabilities of the non-archived accounts (R-HOME-1, R-ACC-4), plus the
/// debts counted in net worth (R-DEBT-7). Accounts linked to a debt (R-DEBT-17) are counted only
/// through the debt, and only when its flag is on, never in the account part (R-DEBT-18). Assets and liabilities follow the account kind
/// (R-ACC-2), not the sign of the balance; a debt is an asset while owed to me and a liability
/// while I owe.
public struct NetWorth: Hashable, Sendable {
  public let currency: Currency
  /// The balances' day; nil = every transaction counted.
  public let day: Day?
  public let rateDate: RateDate
  /// Sum of the converted balances of asset accounts.
  public let assets: Money
  /// What is owed: minus the sum of the liability balances (positive while in debt).
  public let liabilities: Money
  /// Non-archived accounts that are not linked to a debt, in input order.
  public let accounts: [AccountValue]
  /// Debts counted in net worth, in input order (included in `assets` / `liabilities`).
  public var debts: [DebtValue] = []
  /// Balances left out of the totals because no rate was known.
  public let unconverted: Unconverted

  public var total: Money { assets - liabilities }

  /// The debts' converted balances summed (owed to me − I owe); zero without debts.
  public var debtsTotal: Money {
    debts.reduce(.zero(currency)) { $0 + ($1.converted ?? .zero(currency)) }
  }
}

/// A point of the net-worth chart: a month end, or today for the last point (R-HOME-1).
public struct NetWorthPoint: Hashable, Sendable {
  public let day: Day
  public let isToday: Bool
  public let netWorth: NetWorth

  public var value: Money { netWorth.total }
}

public struct NetWorthSeries: Hashable, Sendable {
  /// Oldest first; the last one is today.
  public let points: [NetWorthPoint]

  /// Today's point: the headline figure.
  public var today: NetWorthPoint? { points.last }

  /// Today minus the previous month end; nil with fewer than two points.
  public var changeSincePreviousMonthEnd: Money? {
    guard points.count >= 2 else { return nil }
    return points[points.count - 1].value - points[points.count - 2].value
  }
}

extension Calc {
  /// Net worth in `currency` (R-HOME-1, R-ACC-4): archived accounts are left out; balances
  /// through `day` (nil = all transactions) converted at `rateDate` (default: the latest rate,
  /// R-FX-3). A balance without a rate is listed with `converted == nil`, left out of the
  /// totals and counted in `unconverted`.
  public static func netWorth(
    accounts: [Account], txns: [TxnWithLines], currency: Currency,
    converter: some CurrencyConverter, through day: Day? = nil, rateDate: RateDate = .latest,
    debts: DebtBook = .empty, calendar: Calendar = .current
  ) -> NetWorth {
    let linked = debts.linkedAccountIDs
    let active = accounts.filter { !$0.isArchived || linked.contains($0.id) }
    let timeline = LedgerTimeline(accounts: active, txns: txns, calendar: calendar)
    return netWorth(
      timeline: timeline, debts: debts, currency: currency, converter: converter, through: day, rateDate: rateDate)
  }

  /// The monthly net-worth chart (R-HOME-1): `monthEnds` points at the ends of the months
  /// before `today`'s month, each converted at that day's rate, then today at the latest rate.
  public static func netWorthSeries(
    accounts: [Account], txns: [TxnWithLines], currency: Currency,
    converter: some CurrencyConverter, today: Day, monthEnds: Int = 11, debts: DebtBook = .empty,
    calendar: Calendar = .current
  ) -> NetWorthSeries {
    let linked = debts.linkedAccountIDs
    let active = accounts.filter { !$0.isArchived || linked.contains($0.id) }
    let timeline = LedgerTimeline(accounts: active, txns: txns, calendar: calendar)
    var points: [NetWorthPoint] = []
    let thisMonth = today.yearMonth
    for back in stride(from: monthEnds, through: 1, by: -1) {
      let end = thisMonth.adding(months: -back).lastDay(calendar: calendar)
      let value = netWorth(
        timeline: timeline, debts: debts, currency: currency, converter: converter, through: end, rateDate: .day(end))
      points.append(NetWorthPoint(day: end, isToday: false, netWorth: value))
    }
    let now = netWorth(
      timeline: timeline, debts: debts, currency: currency, converter: converter, through: today, rateDate: .latest)
    points.append(NetWorthPoint(day: today, isToday: true, netWorth: now))
    return NetWorthSeries(points: points)
  }

  static func netWorth(
    timeline: LedgerTimeline, debts book: DebtBook = .empty, currency: Currency, converter: some CurrencyConverter,
    through day: Day?, rateDate: RateDate
  ) -> NetWorth {
    let balances = timeline.balances(through: day)
    var gaps = Unconverted()
    var assets: Int64 = 0
    var liabilities: Int64 = 0
    var values: [AccountValue] = []
    let linked = book.linkedAccountIDs
    for account in timeline.accounts where !linked.contains(account.id) {
      let balance = balances[account.id] ?? .zero(account.currency)
      let converted = convert(
        balance.minorUnits, from: account.currency, to: currency, at: rateDate, using: converter, gaps: &gaps)
      if let converted {
        if account.kind.isLiability { liabilities -= converted } else { assets += converted }
      }
      values.append(AccountValue(
        accountID: account.id, isLiability: account.kind.isLiability, balance: balance,
        converted: converted.map { Money(minorUnits: $0, currency: currency) }))
    }
    // R-DEBT-7, R-DEBT-18: debts with "Count in net worth" add one term per currency (linked
    // accounts + manual records), by the sign of the balance. Linked accounts count here only,
    // never in the account part above.
    var debtValues: [DebtValue] = []
    let counted = book.debts.filter(\.countsInNetWorth)
    if !counted.isEmpty {
      let perDebt = debtBalances(book, accountBalances: balances, through: day)
      for debt in counted {
        for balance in perDebt[debt.id] ?? [] where balance.minorUnits != 0 {
          let converted = convert(
            balance.minorUnits, from: balance.currency, to: currency, at: rateDate, using: converter, gaps: &gaps)
          if let converted {
            if converted >= 0 { assets += converted } else { liabilities -= converted }
          }
          debtValues.append(DebtValue(
            debtID: debt.id, balance: balance, converted: converted.map { Money(minorUnits: $0, currency: currency) }))
        }
      }
    }
    var result = NetWorth(
      currency: currency, day: day, rateDate: rateDate,
      assets: Money(minorUnits: assets, currency: currency),
      liabilities: Money(minorUnits: liabilities, currency: currency),
      accounts: values, unconverted: gaps)
    result.debts = debtValues
    return result
  }
}
