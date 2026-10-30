import Foundation

// Debt calculators (R-DEBT-16…20, docs/status/C19.md): balances per currency from linked
// accounts and manual records, converted totals, the report ledger of flagged records, the
// widget totals and the two hints.

// MARK: - Balances (R-DEBT-18)

/// One linked account's contribution to its debt, in the account's currency: opening balance plus
/// the signed effect of every transaction touching it (positive = they owe me).
public struct DebtAccountBalance: Hashable, Sendable, Identifiable {
  public let accountID: Account.ID
  public let role: DebtAccountRole
  public let balance: Money

  public var id: Account.ID { accountID }
}

/// A debt's total in one display currency (R-DEBT-18): the per-currency balances converted and
/// summed; nil when a rate is missing.
public struct DebtConvertedTotal: Hashable, Sendable {
  public let debtID: Debt.ID
  public let total: Money?
  public let unconverted: Unconverted
}

extension Calc {
  /// Per linked account of `debtID`: its balance in its own currency (R-DEBT-18, R-DEBT-21
  /// breakdown), in the order of `book.accounts`; with `day`, only transactions on or before it
  /// (the opening balance from its opening day on).
  public static func debtAccountBalances(
    _ book: DebtBook, debtID: Debt.ID, through day: Day? = nil, calendar: Calendar = .current
  ) -> [DebtAccountBalance] {
    let links = book.links(of: debtID)
    guard !links.isEmpty else { return [] }
    let roles = Dictionary(links.map { ($0.accountID, $0.role) }, uniquingKeysWith: { first, _ in first })
    let accounts = book.accounts.filter { roles[$0.id] != nil }
    let balances = LedgerTimeline(accounts: accounts, txns: book.txns, calendar: calendar).balances(through: day)
    return accounts.map { account in
      DebtAccountBalance(
        accountID: account.id, role: roles[account.id] ?? .external,
        balance: balances[account.id] ?? .zero(account.currency))
    }
  }

  /// Every debt's balance per currency, **never netted across currencies**: linked accounts
  /// (opening balance + transactions) plus manual records of that currency. Currencies a debt
  /// touches (an account or a record) are listed even at zero, in display order; a debt without
  /// accounts or records has an empty list. With `day`, only what happened on or before it.
  public static func debtBalances(
    _ book: DebtBook, through day: Day? = nil, calendar: Calendar = .current
  ) -> [Debt.ID: [Money]] {
    let timeline = LedgerTimeline(accounts: book.accounts, txns: book.txns, calendar: calendar)
    return debtBalances(
      book, accountBalances: timeline.balances(through: day), through: day)
  }

  /// `debtBalances` over account balances computed by the caller (net worth shares its timeline).
  static func debtBalances(
    _ book: DebtBook, accountBalances: [Account.ID: Money], through day: Day?
  ) -> [Debt.ID: [Money]] {
    let dayString = day?.string
    var sums: [Debt.ID: [Currency: Int64]] = [:]
    for link in book.links {
      guard let balance = accountBalances[link.accountID] else { continue }
      sums[link.debtID, default: [:]][balance.currency, default: 0] += balance.minorUnits
    }
    for record in book.records {
      if let dayString, record.day > dayString { continue }
      sums[record.debtID, default: [:]][record.currency, default: 0] += record.balanceEffect
    }
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    var result: [Debt.ID: [Money]] = [:]
    for debt in book.debts {
      let perCurrency = sums[debt.id] ?? [:]
      result[debt.id] = perCurrency
        .sorted { (order[$0.key] ?? 99, $0.key.rawValue) < (order[$1.key] ?? 99, $1.key.rawValue) }
        .map { Money(minorUnits: $0.value, currency: $0.key) }
    }
    return result
  }

  /// One debt's balance in one currency (zero when it has none there).
  public static func debtBalance(
    _ book: DebtBook, debtID: Debt.ID, currency: Currency, through day: Day? = nil, calendar: Calendar = .current
  ) -> Money {
    let all = debtBalances(book, through: day, calendar: calendar)[debtID] ?? []
    return all.first { $0.currency == currency } ?? .zero(currency)
  }

  /// R-DEBT-18: the debt's per-currency balances converted to `currency` and summed (latest rate
  /// by default); `total` is nil when a rate is missing (the gap is in `unconverted`).
  public static func debtConvertedTotal(
    _ book: DebtBook, debtID: Debt.ID, currency: Currency, converter: some CurrencyConverter,
    rateDate: RateDate = .latest, through day: Day? = nil, calendar: Calendar = .current
  ) -> DebtConvertedTotal {
    var gaps = Unconverted()
    var sum: Int64 = 0
    var complete = true
    for balance in debtBalances(book, through: day, calendar: calendar)[debtID] ?? [] {
      if let minor = convert(
        balance.minorUnits, from: balance.currency, to: currency, at: rateDate, using: converter, gaps: &gaps)
      {
        sum += minor
      } else {
        complete = false
      }
    }
    return DebtConvertedTotal(
      debtID: debtID, total: complete ? Money(minorUnits: sum, currency: currency) : nil, unconverted: gaps)
  }
}

extension DebtBook {
  /// The debt's balance per currency now; see `Calc.debtBalances`.
  public func balances(of debtID: Debt.ID, calendar: Calendar = .current) -> [Money] {
    Calc.debtBalances(self, calendar: calendar)[debtID] ?? []
  }

  /// The debt's balance in one currency now (positive = they owe me).
  public func balance(of debtID: Debt.ID, currency: Currency, calendar: Calendar = .current) -> Int64 {
    Calc.debtBalance(self, debtID: debtID, currency: currency, calendar: calendar).minorUnits
  }
}

// MARK: - Money through the linked accounts (R-DEBT-18, R-DEBT-21 breakdown)

/// What moved through one linked account of a debt: money into the person's account (they owe me
/// more) and out of it (they repaid), in the account's currency, and how many transactions.
public struct DebtAccountFlow: Hashable, Sendable, Identifiable {
  public let accountID: Account.ID
  public let role: DebtAccountRole
  /// Money out of the person's account (minor units, positive).
  public let outMinor: Int64
  /// Money into the person's account.
  public let inMinor: Int64
  public let transactions: Int

  public var id: Account.ID { accountID }
}

extension Calc {
  /// Per linked account of the given debts (in the order of `book.links`): the sum of the
  /// transaction effects flowing in and out, and their count.
  public static func debtAccountFlows(_ book: DebtBook, debtIDs: Set<Debt.ID>) -> [DebtAccountFlow] {
    let links = book.links.filter { debtIDs.contains($0.debtID) }
    let wanted = Set(links.map(\.accountID))
    var sums: [Account.ID: (out: Int64, in: Int64, count: Int)] = [:]
    for item in book.txns {
      for effect in effects(of: item) where wanted.contains(effect.accountID) && effect.amountMinor != 0 {
        var sum = sums[effect.accountID] ?? (0, 0, 0)
        if effect.amountMinor > 0 { sum.in += effect.amountMinor } else { sum.out -= effect.amountMinor }
        sum.count += 1
        sums[effect.accountID] = sum
      }
    }
    return links.map { link in
      let sum = sums[link.accountID] ?? (0, 0, 0)
      return DebtAccountFlow(
        accountID: link.accountID, role: link.role, outMinor: sum.out, inMinor: sum.in, transactions: sum.count)
    }
  }
}

// MARK: - Reports of flagged manual records

extension DebtBook {
  /// Flagged manual records (a forgiven debt counted as an expense, R-DEBT-4) as calculator
  /// input: one synthetic **archived** account per record (id = the record's, in the record's
  /// currency) and per record a zero-amount transfer (id = the record's) on it carrying one
  /// attached record of the record's report kind, category and amount, at noon of its day.
  ///
  /// Append both to the accounts and transactions given to the report calculators (donut,
  /// budget, income/expense totals): the attached-record rules (D22 refund lines, day-rate
  /// conversion) then apply as to any transaction, net worth ignores them (archived), and no
  /// real balance changes. Never store or list them.
  public func reportLedger(calendar: Calendar = .current) -> (accounts: [Account], txns: [TxnWithLines]) {
    let known = Set(debts.map(\.id))
    var accounts: [Account] = []
    var txns: [TxnWithLines] = []
    for record in records {
      guard let kind = record.reportKind, known.contains(record.debtID), let day = Day(record.day) else { continue }
      let noon = calendar.date(byAdding: .hour, value: 12, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar)
      let txn = Txn(
        id: record.id, type: .transfer, occurredAt: noon, accountID: record.id, amountMinor: 0,
        note: record.note, createdAt: record.createdAt)
      let line = AttachedRecord(
        id: record.id, txnID: record.id, kind: kind, categoryID: record.categoryID, amountMinor: record.amountMinor,
        note: record.note)
      txns.append(TxnWithLines(txn: txn, lines: [line]))
      accounts.append(
        Account(
          id: record.id, name: "Debt", currency: record.currency, kind: .debt,
          openingDate: Date(timeIntervalSince1970: 0), isArchived: true))
    }
    return (accounts, txns)
  }
}

// MARK: - Widget totals (R-DEBT-6)

private struct DebtSummaryPerson {
  var name: String
  var balances: [Money] = []
  var converted: Int64 = 0
  var complete = true
}

/// One person's open debt for the Debts widget and tab.
public struct DebtPersonSummary: Hashable, Sendable, Identifiable {
  public let personKey: String
  public let personName: String
  /// The debt (R-DEBT-16: one per person).
  public let debtID: Debt.ID
  /// Per-currency balances (non-zero), in currency display order.
  public let balances: [Money]
  /// Sum of the balances in the summary's currency; nil when a rate is missing.
  public let converted: Money?

  public var id: String { personKey }
}

public struct DebtSummary: Hashable, Sendable {
  public let currency: Currency
  /// What people owe me (sum of positive balances), in `currency` at the latest rate.
  public let owedToMe: Money
  /// What I owe (sum of negative balances, as a positive amount).
  public let iOwe: Money
  /// People with a non-zero open balance, largest (absolute, converted) first.
  public let people: [DebtPersonSummary]
  public let unconverted: Unconverted
}

extension Calc {
  /// The Debts widget (R-DEBT-6): open (not settled) debts with a non-zero balance, totals
  /// "Owed to you" / "You owe" in `currency` at the latest rate, people largest first. Balances
  /// are never netted across currencies; a person's converted figure is only for ordering. Stored
  /// signs: positive = they owe me (the display sign convention of R-DEBT-21 is the UI's).
  public static func debtSummary(
    _ book: DebtBook, currency: Currency, converter: some CurrencyConverter, calendar: Calendar = .current
  ) -> DebtSummary {
    let balances = debtBalances(book, calendar: calendar)
    var gaps = Unconverted()
    var owed: Int64 = 0
    var owe: Int64 = 0
    var people: [String: (debtID: Debt.ID, person: DebtSummaryPerson)] = [:]
    for debt in book.debts where !debt.isSettled {
      let open = (balances[debt.id] ?? []).filter { $0.minorUnits != 0 }
      guard !open.isEmpty else { continue }
      var entry = people[debt.personKey]
        ?? (debt.id, DebtSummaryPerson(name: debt.personName.trimmingCharacters(in: .whitespacesAndNewlines)))
      for balance in open {
        entry.person.balances.append(balance)
        if let minor = convert(
          balance.minorUnits, from: balance.currency, to: currency, at: .latest, using: converter, gaps: &gaps)
        {
          if minor > 0 { owed += minor } else { owe -= minor }
          entry.person.converted += minor
        } else {
          entry.person.complete = false
        }
      }
      people[debt.personKey] = entry
    }
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    let summaries = people.map { key, entry in
      DebtPersonSummary(
        personKey: key, personName: entry.person.name, debtID: entry.debtID,
        balances: entry.person.balances.sorted { (order[$0.currency] ?? 0) < (order[$1.currency] ?? 0) },
        converted: entry.person.complete ? Money(minorUnits: entry.person.converted, currency: currency) : nil)
    }
    .sorted { a, b in
      let x = abs(a.converted?.minorUnits ?? 0)
      let y = abs(b.converted?.minorUnits ?? 0)
      if x != y { return x > y }
      return a.personName.localizedStandardCompare(b.personName) == .orderedAscending
    }
    return DebtSummary(
      currency: currency, owedToMe: Money(minorUnits: owed, currency: currency),
      iOwe: Money(minorUnits: owe, currency: currency), people: summaries, unconverted: gaps)
  }
}

// MARK: - Hints (R-DEBT-20, R-DEBT-21)

extension Day {
  /// Whole days from a fixed epoch (differences between days, DST-safe).
  fileprivate func debtOrdinal(calendar: Calendar) -> Int {
    let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    return calendar.dateComponents([.day], from: epoch, to: date(calendar: calendar)).day ?? 0
  }
}

/// R-DEBT-20: the same payment seems to be on two accounts of one debt (e.g. entered by hand on
/// the virtual account and imported on the person's external account). Only a hint: nothing is
/// merged automatically.
public struct DebtDuplicateHint: Hashable, Sendable, Identifiable {
  public let debtID: Debt.ID
  public let first: Txn.ID
  public let second: Txn.ID
  public let firstAccountID: Account.ID
  public let secondAccountID: Account.ID
  /// Positive amount in the accounts' currency.
  public let amountMinor: Int64
  public let currency: Currency
  public let firstDay: Day
  public let secondDay: Day

  public var id: String { "\(first.uuidString)|\(second.uuidString)" }
}

/// R-DEBT-21: a linked account without any transaction in the last period.
public struct DebtIdleAccountHint: Hashable, Sendable, Identifiable {
  public let debtID: Debt.ID
  public let accountID: Account.ID
  public let role: DebtAccountRole
  /// Day of its latest transaction; nil = never had one.
  public let lastTransactionDay: Day?

  public var id: Account.ID { accountID }
}

extension Calc {
  /// R-DEBT-20: pairs of transactions on two different linked accounts of one debt with the same
  /// effect (same currency, amount and direction) at most `windowDays` apart. A transaction
  /// touching both accounts (a transfer between them) is never paired with itself; each
  /// transaction is used once, the closest days first.
  public static func debtDuplicateHints(
    _ book: DebtBook, windowDays: Int = 3, calendar: Calendar = .current
  ) -> [DebtDuplicateHint] {
    var hints: [DebtDuplicateHint] = []
    let accountsByID = Dictionary(book.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for debt in book.debts {
      let accountIDs = Set(book.links(of: debt.id).map(\.accountID))
      guard accountIDs.count > 1 else { continue }
      struct Entry {
        let txn: Txn.ID
        let account: Account.ID
        let currency: Currency
        let effect: Int64
        let day: Day
        let dayNumber: Int
      }
      var entries: [Entry] = []
      for item in book.txns {
        let day = Day(item.txn.occurredAt, calendar: calendar)
        for effect in effects(of: item) where accountIDs.contains(effect.accountID) && effect.amountMinor != 0 {
          guard let account = accountsByID[effect.accountID] else { continue }
          entries.append(
            Entry(
              txn: item.txn.id, account: effect.accountID, currency: account.currency, effect: effect.amountMinor,
              day: day, dayNumber: day.debtOrdinal(calendar: calendar)))
        }
      }
      var candidates: [(Int, Entry, Entry)] = []
      for (i, a) in entries.enumerated() {
        for b in entries[(i + 1)...] {
          guard a.txn != b.txn, a.account != b.account, a.currency == b.currency, a.effect == b.effect else { continue }
          let gap = abs(a.dayNumber - b.dayNumber)
          if gap <= windowDays { candidates.append((gap, a, b)) }
        }
      }
      candidates.sort { ($0.0, $0.1.day.string, $0.1.txn.uuidString) < ($1.0, $1.1.day.string, $1.1.txn.uuidString) }
      var used: Set<Txn.ID> = []
      for (_, a, b) in candidates where !used.contains(a.txn) && !used.contains(b.txn) {
        used.insert(a.txn)
        used.insert(b.txn)
        let (first, second) = a.day <= b.day ? (a, b) : (b, a)
        hints.append(
          DebtDuplicateHint(
            debtID: debt.id, first: first.txn, second: second.txn, firstAccountID: first.account,
            secondAccountID: second.account, amountMinor: abs(a.effect), currency: a.currency,
            firstDay: first.day, secondDay: second.day))
      }
    }
    return hints.sorted { ($0.firstDay.string, $0.id) < ($1.firstDay.string, $1.id) }
  }

  /// R-DEBT-21: linked accounts of open debts without any transaction in the `periodDays` up to
  /// and including `today` (default 30). Accounts of settled debts are left out.
  public static func debtIdleAccountHints(
    _ book: DebtBook, today: Day, periodDays: Int = 30, calendar: Calendar = .current
  ) -> [DebtIdleAccountHint] {
    var latest: [Account.ID: Day] = [:]
    let linked = book.linkedAccountIDs
    for item in book.txns {
      let day = Day(item.txn.occurredAt, calendar: calendar)
      for effect in effects(of: item) where linked.contains(effect.accountID) {
        if let known = latest[effect.accountID], known >= day { continue }
        latest[effect.accountID] = day
      }
    }
    let todayNumber = today.debtOrdinal(calendar: calendar)
    let open = Set(book.debts.filter { !$0.isSettled }.map(\.id))
    var hints: [DebtIdleAccountHint] = []
    for link in book.links where open.contains(link.debtID) {
      let last = latest[link.accountID]
      let idle = last.map { todayNumber - $0.debtOrdinal(calendar: calendar) >= periodDays } ?? true
      if idle {
        hints.append(DebtIdleAccountHint(debtID: link.debtID, accountID: link.accountID, role: link.role, lastTransactionDay: last))
      }
    }
    return hints
  }
}
