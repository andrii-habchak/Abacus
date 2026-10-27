import Foundation

// Debt calculators (R-DEBT, design in docs/status/C14.md): balances, the synthetic report
// ledger for records without a leg, and the totals of the Debts widget.

extension Calc {
  /// R-DEBT-2: the debt's balance (positive = they owe me) from its records, in its currency;
  /// with `day`, only records on or before it.
  public static func debtBalance(_ debt: Debt, records: [DebtRecord], through day: Day? = nil) -> Money {
    let dayString = day?.string
    var sum: Int64 = 0
    for record in records where record.debtID == debt.id {
      if let dayString, record.day > dayString { continue }
      sum += record.balanceEffect
    }
    return Money(minorUnits: sum, currency: debt.currency)
  }

  /// Every debt's balance; see `debtBalance(_:records:through:)`.
  public static func debtBalances(_ book: DebtBook, through day: Day? = nil) -> [Debt.ID: Money] {
    let dayString = day?.string
    var sums: [Debt.ID: Int64] = [:]
    for entry in book.entries {
      if let dayString, entry.record.day > dayString { continue }
      sums[entry.record.debtID, default: 0] += entry.record.balanceEffect
    }
    var result: [Debt.ID: Money] = [:]
    for debt in book.debts {
      result[debt.id] = Money(minorUnits: sums[debt.id] ?? 0, currency: debt.currency)
    }
    return result
  }
}

// MARK: - Reports of records without a leg

extension DebtBook {
  /// Flagged records without a leg (a forgiven debt counted as an expense, converted records
  /// that carried an expense or income) as calculator input (R-DEBT-4): one synthetic
  /// **archived** account per debt (id = the debt's, its currency) and per record a zero-amount
  /// transfer (id = the record's) on that account carrying one attached record of the record's
  /// report kind, category and amount, at noon of its day.
  ///
  /// Append both to the accounts and transactions given to the report calculators (donut,
  /// budget, income/expense totals): the attached-record rules (D22 refund lines, day-rate
  /// conversion) then apply as to any transaction, net worth ignores them (archived), and no
  /// real balance changes. Never store or list them.
  public func reportLedger(calendar: Calendar = .current) -> (accounts: [Account], txns: [TxnWithLines]) {
    let byID = Dictionary(debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var used: Set<Debt.ID> = []
    var txns: [TxnWithLines] = []
    for entry in entries where entry.leg == nil {
      let record = entry.record
      guard let kind = record.reportKind, byID[record.debtID] != nil, let day = Day(record.day) else { continue }
      used.insert(record.debtID)
      let noon = calendar.date(byAdding: .hour, value: 12, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar)
      let txn = Txn(
        id: record.id, type: .transfer, occurredAt: noon, accountID: record.debtID, amountMinor: 0,
        note: record.note, createdAt: record.createdAt)
      let line = AttachedRecord(
        id: record.id, txnID: record.id, kind: kind, categoryID: record.categoryID, amountMinor: record.amountMinor,
        note: record.note)
      txns.append(TxnWithLines(txn: txn, lines: [line]))
    }
    let accounts = debts.filter { used.contains($0.id) }.map { debt in
      Account(
        id: debt.id, name: debt.personName, currency: debt.currency, kind: .debt,
        openingDate: Date(timeIntervalSince1970: 0), isArchived: true)
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

/// One person's open debts for the Debts widget and tab.
public struct DebtPersonSummary: Hashable, Sendable, Identifiable {
  public let personKey: String
  public let personName: String
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
  /// "Owed to you" / "You owe" in `currency` at the latest rate, people largest first. Debts are
  /// never netted across currencies; a person's converted figure is only for ordering.
  public static func debtSummary(
    _ book: DebtBook, currency: Currency, converter: some CurrencyConverter
  ) -> DebtSummary {
    let balances = debtBalances(book)
    var gaps = Unconverted()
    var owed: Int64 = 0
    var owe: Int64 = 0
    var people: [String: DebtSummaryPerson] = [:]
    for debt in book.debts where !debt.isSettled {
      guard let balance = balances[debt.id], balance.minorUnits != 0 else { continue }
      var person = people[debt.personKey] ?? DebtSummaryPerson(name: debt.personName.trimmingCharacters(in: .whitespacesAndNewlines))
      person.balances.append(balance)
      if let minor = convert(balance.minorUnits, from: debt.currency, to: currency, at: .latest, using: converter, gaps: &gaps) {
        if minor > 0 { owed += minor } else { owe -= minor }
        person.converted += minor
      } else {
        person.complete = false
      }
      people[debt.personKey] = person
    }
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    let summaries = people.map { key, person in
      DebtPersonSummary(
        personKey: key, personName: person.name,
        balances: person.balances.sorted { (order[$0.currency] ?? 0) < (order[$1.currency] ?? 0) },
        converted: person.complete ? Money(minorUnits: person.converted, currency: currency) : nil)
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
