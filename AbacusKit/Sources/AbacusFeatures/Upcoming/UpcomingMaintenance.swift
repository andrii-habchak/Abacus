import AbacusDomain
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData

/// The launch / activation work of N5 (R-REC-7c, R-REC-9, R-REC-17): the matching sweep, then
/// the daily forecast snapshot. Runs off the main actor; never creates a transaction (R-REC-3).
public enum UpcomingMaintenance {
  public struct Result: Hashable, Sendable {
    public var sweep: ScheduledSweepResult?
    public var snapshotTaken = false
  }

  /// Sweep, then `takeIfNeeded` with today's latest rates (R-REC-13) and the debt terms.
  public static func run(
    database: any DatabaseWriter, today: Day, converter: (any CurrencyConverter)?, calendar: Calendar
  ) async -> Result {
    var result = Result()
    let store = SQLiteScheduledStore(database: database, calendar: calendar)
    result.sweep = try? await store.sweep(today: today, matcher: ScheduledMatch.rule)
    guard let converter else { return result }
    let accounts = (try? await SQLiteAccountRepository(database: database, calendar: calendar).accounts(includeArchived: false)) ?? []
    let book = (try? await SQLiteDebtRepository(database: database, calendar: calendar).book()) ?? .empty
    let debts = debtTerms(book, today: today, calendar: calendar)
    let rates = SnapshotRates.latest(
      from: converter, currencies: accounts.map(\.currency) + Array(debts.keys))
    let snapshot = try? await SQLiteForecastSnapshotRepository(database: database, calendar: calendar)
      .takeIfNeeded(today: today, rates: rates, debts: debts)
    result.snapshotTaken = snapshot != nil
    return result
  }

  /// R-REC-13: the debts that count in net worth, per currency (positive = owed to me), held at
  /// today's value. `Calc.netWorth` leaves every debt-linked account out of the account part;
  /// the snapshot stores all non-archived accounts, so their balances are taken out here (the
  /// snapshot's end net worth then equals the dashboard's).
  public static func debtTerms(_ book: DebtBook, today: Day, calendar: Calendar) -> [Currency: Int64] {
    let perDebt = Calc.debtBalances(book, through: today, calendar: calendar)
    let accountBalances = Calc.balances(accounts: book.accounts, txns: book.txns, through: today, calendar: calendar)
    var result: [Currency: Int64] = [:]
    for debt in book.debts where debt.countsInNetWorth {
      for balance in perDebt[debt.id] ?? [] { result[balance.currency, default: 0] += balance.minorUnits }
    }
    for account in book.accounts where !account.isArchived && book.linkedAccountIDs.contains(account.id) {
      if let balance = accountBalances[account.id] { result[balance.currency, default: 0] -= balance.minorUnits }
    }
    return result.filter { $0.value != 0 }
  }
}
