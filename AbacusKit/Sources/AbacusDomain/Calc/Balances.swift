import Foundation

/// The change a transaction makes to one account, in that account's currency.
public struct AccountEffect: Hashable, Sendable {
  public let accountID: Account.ID
  /// Signed minor units: positive = money into the account, negative = out of it.
  public let amountMinor: Int64

  public init(accountID: Account.ID, amountMinor: Int64) {
    self.accountID = accountID
    self.amountMinor = amountMinor
  }
}

extension Calc {
  /// The effect of the main amount alone (R-TX-1, R-TX-4, R-TX-5):
  /// - expense: out; an expense refund: in;
  /// - income: in; an income reversal: out;
  /// - transfer: `amountMinor` out of `accountID`, `toAmountMinor` (or `amountMinor` when the
  ///   same currency left it empty) into `toAccountID`. `isRefund` does not apply to transfers,
  ///   except on a transfer without a destination (a debt leg, R-DEBT-3): there it means money
  ///   comes in.
  public static func mainEffects(of txn: Txn) -> [AccountEffect] {
    switch txn.type {
    case .expense:
      return [AccountEffect(accountID: txn.accountID, amountMinor: txn.isRefund ? txn.amountMinor : -txn.amountMinor)]
    case .income:
      return [AccountEffect(accountID: txn.accountID, amountMinor: txn.isRefund ? -txn.amountMinor : txn.amountMinor)]
    case .transfer:
      if txn.isOneSidedInflow { return [AccountEffect(accountID: txn.accountID, amountMinor: txn.amountMinor)] }
      var effects = [AccountEffect(accountID: txn.accountID, amountMinor: -txn.amountMinor)]
      if let to = txn.toAccountID {
        effects.append(AccountEffect(accountID: to, amountMinor: txn.toAmountMinor ?? txn.amountMinor))
      }
      return effects
    }
  }

  /// Signed effect of an attached record on the parent's account (R-TX-6): an expense line
  /// (fee) takes money out, an income line (cashback) puts it in.
  public static func lineEffect(_ line: AttachedRecord) -> Int64 {
    line.kind == .expense ? -line.amountMinor : line.amountMinor
  }

  /// The full effect of a transaction per account: main amount ± attached records, which hit
  /// the parent's (source) account (R-TX-5, R-TX-6). One entry per account, source first.
  public static func effects(of item: TxnWithLines) -> [AccountEffect] {
    var effects = mainEffects(of: item.txn)
    let lines = item.lines.reduce(Int64(0)) { $0 + lineEffect($1) }
    if lines != 0 {
      if let index = effects.firstIndex(where: { $0.accountID == item.txn.accountID }) {
        effects[index] = AccountEffect(accountID: item.txn.accountID, amountMinor: effects[index].amountMinor + lines)
      } else {
        effects.insert(AccountEffect(accountID: item.txn.accountID, amountMinor: lines), at: 0)
      }
    }
    // A transfer to the same account nets out into one entry.
    var merged: [AccountEffect] = []
    for effect in effects {
      if let index = merged.firstIndex(where: { $0.accountID == effect.accountID }) {
        merged[index] = AccountEffect(accountID: effect.accountID, amountMinor: merged[index].amountMinor + effect.amountMinor)
      } else {
        merged.append(effect)
      }
    }
    return merged
  }

  /// The transaction's effect on one account (0 when it does not touch it).
  public static func effect(of item: TxnWithLines, on accountID: Account.ID) -> Int64 {
    effects(of: item).first { $0.accountID == accountID }?.amountMinor ?? 0
  }

  /// Balance = opening balance + the account's transaction effects (R-ACC-3), in the account's
  /// currency, for every account passed in (archived ones too).
  ///
  /// With `day`, only transactions on or before that day count, and the opening balance counts
  /// only from the account's opening day on. Without it, everything counts.
  public static func balances(
    accounts: [Account], txns: [TxnWithLines], through day: Day? = nil,
    calendar: Calendar = .current
  ) -> [Account.ID: Money] {
    LedgerTimeline(accounts: accounts, txns: txns, calendar: calendar).balances(through: day)
  }

  /// Balance of one account; see `balances(accounts:txns:through:calendar:)`.
  public static func balance(
    of account: Account, txns: [TxnWithLines], through day: Day? = nil,
    calendar: Calendar = .current
  ) -> Money {
    balances(accounts: [account], txns: txns, through: day, calendar: calendar)[account.id]
      ?? .zero(account.currency)
  }
}

/// Account effects with their days, computed once so balances at many days (the net-worth
/// series) do not redo the date math.
struct LedgerTimeline {
  struct DatedEffect {
    let day: Day
    let accountID: Account.ID
    let amountMinor: Int64
  }

  let accounts: [Account]
  let openingDays: [Account.ID: Day]
  let effects: [DatedEffect]

  init(accounts: [Account], txns: [TxnWithLines], calendar: Calendar) {
    self.accounts = accounts
    let ids = Set(accounts.map(\.id))
    var openingDays: [Account.ID: Day] = [:]
    for account in accounts {
      openingDays[account.id] = Day(account.openingDate, calendar: calendar)
    }
    self.openingDays = openingDays
    var effects: [DatedEffect] = []
    effects.reserveCapacity(txns.count)
    for item in txns {
      let touched = Calc.effects(of: item).filter { ids.contains($0.accountID) }
      guard !touched.isEmpty else { continue }
      let day = Day(item.txn.occurredAt, calendar: calendar)
      for effect in touched {
        effects.append(DatedEffect(day: day, accountID: effect.accountID, amountMinor: effect.amountMinor))
      }
    }
    self.effects = effects
  }

  func balances(through day: Day?) -> [Account.ID: Money] {
    var sums: [Account.ID: Int64] = [:]
    for account in accounts {
      let opened = day.map { openingDays[account.id]! <= $0 } ?? true
      sums[account.id, default: 0] += opened ? account.openingBalanceMinor : 0
    }
    for effect in effects where day.map({ effect.day <= $0 }) ?? true {
      sums[effect.accountID, default: 0] += effect.amountMinor
    }
    var result: [Account.ID: Money] = [:]
    for account in accounts {
      result[account.id] = Money(minorUnits: sums[account.id] ?? 0, currency: account.currency)
    }
    return result
  }
}
