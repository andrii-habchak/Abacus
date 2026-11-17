import AbacusDomain
import Foundation

/// The debt terms of net worth (R-REC-13, R-DEBT-7, R-DEBT-18): per currency, the signed balances
/// of the debts with "Count in net worth" (owed to me positive), never netted across currencies.
/// A debt's balance = its linked accounts' balances + its manual records up to the day — the same
/// sum as `Calc.netWorth`, computed from balances the caller already has (one query for many days).
/// Also the `debts` argument of `ForecastSnapshotRepository.takeIfNeeded`.
public enum ForecastDebtTerms {
  /// - Parameters:
  ///   - accountBalances: end-of-`day` balances of (at least) the linked accounts, account currency.
  public static func terms(
    book: DebtBook, accountBalances: [Account.ID: Int64], currencies: [Account.ID: Currency], day: Day
  ) -> [Currency: Int64] {
    let counted = Set(book.debts.filter(\.countsInNetWorth).map(\.id))
    guard !counted.isEmpty else { return [:] }
    var result: [Currency: Int64] = [:]
    for link in book.links where counted.contains(link.debtID) {
      guard let balance = accountBalances[link.accountID], let currency = currencies[link.accountID] else { continue }
      result[currency, default: 0] += balance
    }
    let dayString = day.string
    for record in book.records where counted.contains(record.debtID) && record.day <= dayString {
      result[record.currency, default: 0] += record.balanceEffect
    }
    return result.filter { $0.value != 0 }
  }

  /// Terms for each day of a balance series (the actual line of the overlay).
  public static func terms(book: DebtBook, series: BalanceSeriesInput) -> [Day: [Currency: Int64]] {
    guard book.debts.contains(where: \.countsInNetWorth) else { return [:] }
    var result: [Day: [Currency: Int64]] = [:]
    for (index, day) in series.days.enumerated() {
      var balances: [Account.ID: Int64] = [:]
      for link in book.links {
        if let values = series.balances[link.accountID], index < values.count { balances[link.accountID] = values[index] }
      }
      let terms = terms(book: book, accountBalances: balances, currencies: series.currencies, day: day)
      if !terms.isEmpty { result[day] = terms }
    }
    return result
  }

  /// Days, currencies and balances of a balance query (kept free of the store type).
  public struct BalanceSeriesInput: Sendable {
    public var days: [Day]
    public var currencies: [Account.ID: Currency]
    public var balances: [Account.ID: [Int64]]

    public init(days: [Day], currencies: [Account.ID: Currency], balances: [Account.ID: [Int64]]) {
      self.days = days
      self.currencies = currencies
      self.balances = balances
    }
  }
}
