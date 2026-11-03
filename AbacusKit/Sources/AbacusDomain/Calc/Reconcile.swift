import Foundation

/// N6 (R-CLR): what the Reconcile screen and the account window compute. All amounts are in the
/// account's currency, minor units.
public struct ReconcileRow: Hashable, Identifiable, Sendable {
  public var item: TxnWithLines
  /// The transaction's effect on the account (signed; main amount ± attached records).
  public var effectMinor: Int64
  /// Whether this side of the transaction is cleared.
  public var isCleared: Bool
  /// The day the bank booked it (`bookedDay`), else its own day: PKO statements are by booking day
  /// while rows are dated by purchase day (R-IMP-PKO-4).
  public var statementDay: Day
  public var id: Txn.ID { item.txn.id }
  public var isPending: Bool { item.txn.isPendingAtBank }
}

public struct ReconcileFigures: Hashable, Sendable {
  /// The closing balance typed from the statement (or the counted cash).
  public var statementMinor: Int64
  /// Opening balance + rows that are cleared (or ticked) with statement day ≤ the date; for a cash
  /// account the whole balance at that date.
  public var clearedMinor: Int64
  /// statement − cleared: 0 means the account agrees with the bank.
  public var differenceMinor: Int64 { statementMinor - clearedMinor }
}

public enum Reconcile {
  /// The statement day of a transaction (see `ReconcileRow.statementDay`).
  public static func statementDay(of txn: Txn, calendar: Calendar) -> Day {
    txn.bookedDay.flatMap(Day.init) ?? Day(txn.occurredAt, calendar: calendar)
  }

  /// Every transaction that touches `account`, with its effect and this side's cleared flag.
  public static func rows(account: Account, txns: [TxnWithLines], calendar: Calendar) -> [ReconcileRow] {
    txns.compactMap { item in
      let effect = Calc.effect(of: item, on: account.id)
      guard item.txn.accountID == account.id || item.txn.toAccountID == account.id else { return nil }
      return ReconcileRow(
        item: item, effectMinor: effect, isCleared: item.txn.isCleared(on: account.id),
        statementDay: statementDay(of: item.txn, calendar: calendar))
    }
  }

  /// Opening balance + the effect of cleared (or `ticked`) rows booked on or before `day`. Pending
  /// holds never count. For a cash account (`wholeBalance`) every row counts.
  public static func figures(
    account: Account, rows: [ReconcileRow], statementMinor: Int64, through day: Day,
    ticked: Set<Txn.ID> = [], wholeBalance: Bool = false
  ) -> ReconcileFigures {
    var cleared = account.openingBalanceMinor
    for row in rows where row.statementDay <= day && !row.isPending {
      if wholeBalance || row.isCleared || ticked.contains(row.id) { cleared += row.effectMinor }
    }
    return ReconcileFigures(statementMinor: statementMinor, clearedMinor: cleared)
  }

  /// Cleared balance of the account on `day` as stored now (no ticks).
  public static func clearedBalance(account: Account, rows: [ReconcileRow], through day: Day) -> Int64 {
    figures(account: account, rows: rows, statementMinor: 0, through: day).clearedMinor
  }

  /// Whether the last reconciliation no longer adds up: the cleared balance on its day now differs
  /// from the closing balance the owner typed (corrections included, they are cleared rows).
  public static func drift(_ last: Reconciliation, account: Account, rows: [ReconcileRow]) -> Int64? {
    guard let day = Day(last.statementDay) else { return nil }
    let now = clearedBalance(account: account, rows: rows, through: day)
    return now == last.closingMinor ? nil : now - last.closingMinor
  }

  /// The "Not reconciled" hint: cleared rows booked after the last reconciliation (any cleared row
  /// when there was none). Only a hint.
  public static func isNotReconciled(rows: [ReconcileRow], last: Reconciliation?) -> Bool {
    let since = last.flatMap { Day($0.statementDay) }
    return rows.contains { row in
      row.isCleared && !row.isPending && (since.map { row.statementDay > $0 } ?? true)
    }
  }
}

/// What finishing a reconciliation writes, in one database transaction (R-CLR-5).
public struct ReconcileFinish: Sendable {
  public var accountID: Account.ID
  public var statementDay: Day
  public var closingMinor: Int64
  /// Transactions whose side on `accountID` becomes cleared (the ticked rows).
  public var clearIDs: [Txn.ID]
  /// Rows added during the run (already cleared on the account).
  public var additions: [Txn]
  /// Rows edited during the run (the whole transaction as edited).
  public var edits: [Txn]
  /// Uncleared hand-typed rows deleted during the run.
  public var deletions: [Txn.ID]
  /// Pending holds marked settled during the run.
  public var settleIDs: [Txn.ID]
  /// A "Balance correction" to book on `statementDay` (signed effect on the account), 0 = none.
  public var correctionMinor: Int64

  public init(
    accountID: Account.ID, statementDay: Day, closingMinor: Int64, clearIDs: [Txn.ID] = [],
    additions: [Txn] = [], edits: [Txn] = [], deletions: [Txn.ID] = [], settleIDs: [Txn.ID] = [],
    correctionMinor: Int64 = 0
  ) {
    self.accountID = accountID
    self.statementDay = statementDay
    self.closingMinor = closingMinor
    self.clearIDs = clearIDs
    self.additions = additions
    self.edits = edits
    self.deletions = deletions
    self.settleIDs = settleIDs
    self.correctionMinor = correctionMinor
  }
}

/// Reads and writes for Reconcile and the cleared flag (N6). Implemented by the SQLite store.
public protocol ReconcileRepository: Sendable {
  /// The last finished reconciliation of each account.
  func lastReconciliations() async throws -> [Account.ID: Reconciliation]
  /// Sets the cleared flag of the side on `accountID` of each transaction (pending holds are
  /// skipped: they are never cleared).
  func setCleared(_ ids: [Txn.ID], _ cleared: Bool, on accountID: Account.ID) async throws
  /// A pending hold was paid: it stops being pending and stays uncleared.
  func markSettled(_ ids: [Txn.ID]) async throws
  /// Applies a finished reconciliation (all or nothing).
  func finish(_ finish: ReconcileFinish) async throws
}
