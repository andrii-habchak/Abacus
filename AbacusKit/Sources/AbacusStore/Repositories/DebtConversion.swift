import AbacusDomain
import Foundation
import SQLiteData

/// Gives every account of kind `debt` that belongs to no debt yet a debt (R-DEBT-17, D59;
/// docs/status/C19.md): run after every import commit, because an import that maps a Saldo
/// LIABILITIES account still creates a debt-kind account. The account stays as it is (balance,
/// transactions, opening balance: nothing is rewritten); it is linked to the person's debt as a
/// `virtual` account, found by name (case/diacritic-insensitive) or created. Safe to run again.
public enum DebtConversion {
  public struct Result: Hashable, Sendable {
    /// Debt-kind accounts that were not linked yet.
    public var accounts = 0
    public var debtsCreated = 0

    public init() {}
  }

  /// A debt created here counts in net worth like the account did (a non-archived liability);
  /// archived accounts give a settled debt that does not.
  @discardableResult
  public static func convertDebtAccounts(_ db: Database, calendar: Calendar = .current, now: Date = Date()) throws -> Result {
    var result = Result()
    let accounts = try Account.where { $0.kind.eq(AccountKind.debt) }
      .order { ($0.position, $0.name, $0.id) }.fetchAll(db)
    let linked = Set(try DebtAccountLink.fetchAll(db).map(\.accountID))
    var debts = try Debt.fetchAll(db)
    var clock = now
    for account in accounts where !linked.contains(account.id) {
      result.accounts += 1
      let key = Debt.personKey(account.name)
      let found = debts.filter { $0.personKey == key }
        .sorted { ($0.isSettled ? 1 : 0, $0.createdAt) < ($1.isSettled ? 1 : 0, $1.createdAt) }.first
      let debt: Debt
      if let found {
        debt = found
      } else {
        clock = clock.addingTimeInterval(1)
        debt = Debt(
          personName: account.name.trimmingCharacters(in: .whitespacesAndNewlines),
          countsInNetWorth: !account.isArchived, isSettled: account.isArchived, sourceAccountID: account.id,
          importBatchID: account.importBatchID, createdAt: clock)
        try Debt.insert { debt }.execute(db)
        debts.append(debt)
        result.debtsCreated += 1
      }
      try DebtAccountLink.insert { DebtAccountLink(accountID: account.id, debtID: debt.id, role: .virtual) }.execute(db)
    }
    return result
  }
}
