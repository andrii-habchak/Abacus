import AbacusDomain
import Foundation
import Testing

@Suite("Debt calculators (C14, C19)")
struct DebtCalcTests {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
  }()

  static func at(_ day: String) -> Date {
    let d = Day(day)!
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))!
  }

  static let opened = at("2026-01-01")

  /// A debt with a virtual PLN account (opening balance `opening`) and an external EUR account.
  struct Fixture {
    let debt = Debt(personName: "Person A", countsInNetWorth: true)
    let mine = Account(name: "Mine", currency: .PLN, kind: .bank, openingDate: DebtCalcTests.opened)
    let virtual: Account
    let external: Account
    var txns: [TxnWithLines] = []
    var records: [DebtRecord] = []

    init(opening: Int64 = 0) {
      virtual = Account(
        name: "Person A (PLN)", currency: .PLN, kind: .debt, openingBalanceMinor: opening, openingDate: DebtCalcTests.opened)
      external = Account(name: "Revolut A", currency: .EUR, kind: .bank, openingDate: DebtCalcTests.opened)
    }

    mutating func transfer(
      _ day: String, from: Account, to: Account, _ amount: Int64, received: Int64? = nil
    ) -> Txn.ID {
      let txn = Txn(
        type: .transfer, occurredAt: DebtCalcTests.at(day), accountID: from.id, amountMinor: amount, toAccountID: to.id,
        toAmountMinor: received)
      txns.append(TxnWithLines(txn: txn, lines: []))
      return txn.id
    }

    mutating func expense(_ day: String, on account: Account, _ amount: Int64) -> Txn.ID {
      let txn = Txn(type: .expense, occurredAt: DebtCalcTests.at(day), accountID: account.id, amountMinor: amount)
      txns.append(TxnWithLines(txn: txn, lines: []))
      return txn.id
    }

    var book: DebtBook {
      DebtBook(
        debts: [debt],
        links: [
          DebtAccountLink(accountID: virtual.id, debtID: debt.id, role: .virtual),
          DebtAccountLink(accountID: external.id, debtID: debt.id, role: .external),
        ], accounts: [virtual, external], txns: txns, records: records)
    }
  }

  @Test("R-DEBT-19: a transfer without destination moves money out, or in with isRefund (legacy shape stays calculable)")
  func oneSidedLegs() {
    let account = UUID()
    let out = Txn(type: .transfer, occurredAt: Date(), accountID: account, amountMinor: 5_00)
    var inflow = out
    inflow.isRefund = true
    #expect(Calc.mainEffects(of: out) == [AccountEffect(accountID: account, amountMinor: -5_00)])
    #expect(Calc.mainEffects(of: inflow) == [AccountEffect(accountID: account, amountMinor: 5_00)])
    #expect(inflow.isOneSidedInflow && !out.isOneSidedInflow)
    // A two-sided transfer ignores isRefund as before.
    var twoSided = inflow
    twoSided.toAccountID = UUID()
    #expect(Calc.mainEffects(of: twoSided).first?.amountMinor == -5_00)
  }

  @Test("R-DEBT-2, R-DEBT-4: kinds move the balance and offer flags as the TA says")
  func kinds() {
    #expect(DebtRecordKind.allCases.filter { $0.balanceSign > 0 } == [.lent, .iRepaid, .paidOnTheirBehalf, .forgivenByThem])
    #expect(DebtRecordKind.allCases.filter { !$0.movesMoney } == [.forgaveThem, .forgivenByThem])
    #expect(DebtRecordKind.allCases.filter(\.isInflow) == [.theyRepaid, .borrowed])
    #expect(DebtRecordKind.allCases.filter { $0.offeredReportKind == .expense } == [.lent, .paidOnTheirBehalf, .forgaveThem])
    #expect(DebtRecordKind.allCases.filter { $0.offeredReportKind == .income } == [.theyRepaid])
    #expect(DebtRecordKind.allCases.filter(\.reportsByDefault) == [.forgaveThem])
  }

  @Test("R-DEBT-16: person key ignores case, diacritics and surrounding spaces; names are matched by prefix first")
  func personKeys() {
    #expect(Debt.personKey("  Žuk Ñandú ") == Debt.personKey("zuk nandu"))
    #expect(!Debt(personName: "Ann").countsInNetWorth, "a new debt does not count in net worth by default (D61)")
    let book = DebtBook(debts: ["Maria", "Marek", "Alex Marian", "marek"].map { Debt(personName: $0) })
    #expect(book.personNames == ["Alex Marian", "Marek", "Maria"], "one spelling per person")
    #expect(book.personNames(matching: "MAR") == ["Marek", "Maria", "Alex Marian"])
    #expect(book.personNames(matching: "  ") == book.personNames)
    #expect(book.debt(person: "MAREK")?.personName == "Marek")
  }

  @Test("R-DEBT-18: balance per currency from accounts (opening + transactions) and manual records, through a day")
  func balances() {
    var f = Fixture(opening: 10_00)
    _ = f.transfer("2026-02-10", from: f.mine, to: f.virtual, 100_00)
    _ = f.transfer("2026-03-10", from: f.virtual, to: f.mine, 30_00)
    _ = f.transfer("2026-03-12", from: f.mine, to: f.external, 20_00, received: 4_00)
    f.records = [
      DebtRecord(debtID: f.debt.id, kind: .forgaveThem, day: "2026-03-20", amountMinor: 50_00, currency: .PLN),
      DebtRecord(debtID: f.debt.id, kind: .lent, day: "2026-03-21", amountMinor: 7_00, currency: .USD),
    ]
    let book = f.book
    let all = Calc.debtBalances(book, calendar: Self.calendar)[f.debt.id]
    // Display order of currencies: EUR, USD, PLN.
    #expect(all == [
      Money(minorUnits: 4_00, currency: .EUR),
      Money(minorUnits: 7_00, currency: .USD),
      Money(minorUnits: 30_00, currency: .PLN),  // 10 + 100 − 30 − 50
    ])
    let early = Calc.debtBalances(book, through: Day("2026-02-28")!, calendar: Self.calendar)[f.debt.id] ?? []
    #expect(early.first { $0.currency == .PLN }?.minorUnits == 110_00)
    #expect(early.first { $0.currency == .EUR }?.minorUnits == 0)
    #expect(early.first { $0.currency == .USD } == nil || early.first { $0.currency == .USD }?.minorUnits == 0)
    #expect(Calc.debtBalance(book, debtID: f.debt.id, currency: .PLN, through: Day("2026-03-15")!, calendar: Self.calendar).minorUnits == 80_00)
    #expect(book.balance(of: f.debt.id, currency: .USD, calendar: Self.calendar) == 7_00)
    #expect(book.balances(of: f.debt.id, calendar: Self.calendar).count == 3)
    // A debt without accounts or records has no currencies at all.
    #expect(Calc.debtBalances(DebtBook(debts: [Debt(personName: "Nobody")]))[book.debts[0].id] == nil)
  }

  @Test("R-DEBT-20: the same payment on two accounts of one debt is hinted — same amount, direction and currency within three days")
  func duplicateHints() {
    var f = Fixture()
    let other = Account(name: "Other EUR", currency: .EUR, kind: .bank, openingDate: Self.opened)
    // Both accounts receive 40.00 PLN-equivalent: virtual in PLN, a second PLN account of the debt.
    let second = Account(name: "Revolut PLN", currency: .PLN, kind: .bank, openingDate: Self.opened)
    let a = f.transfer("2026-03-10", from: f.mine, to: f.virtual, 40_00)
    let b = f.transfer("2026-03-12", from: other, to: second, 40_00)
    var book = f.book
    book.accounts.append(second)
    book.links.append(DebtAccountLink(accountID: second.id, debtID: f.debt.id, role: .external))
    book.txns = f.txns
    let hints = Calc.debtDuplicateHints(book, calendar: Self.calendar)
    #expect(hints.count == 1)
    #expect(hints.first.map { Set([$0.first, $0.second]) } == [a, b])
    #expect(hints.first?.amountMinor == 40_00 && hints.first?.currency == .PLN)
    #expect(hints.first?.firstAccountID == f.virtual.id && hints.first?.secondAccountID == second.id)
    #expect(hints.first?.debtID == f.debt.id)

    // Four days apart, another amount, the other direction, another currency: no hint.
    for (day, amount, to) in [("2026-03-14", Int64(40_00), second), ("2026-03-12", 41_00, second)] {
      var g = f
      _ = g.transfer(day, from: other, to: to, amount)
      var other = g.book
      other.accounts.append(second)
      other.links.append(DebtAccountLink(accountID: second.id, debtID: f.debt.id, role: .external))
      // Only the first payment (virtual) and this one are on different linked accounts.
      other.txns = [f.txns[0], g.txns.last!]
      #expect(Calc.debtDuplicateHints(other, calendar: Self.calendar).isEmpty, "\(day) \(amount)")
    }
    var out = f
    _ = out.transfer("2026-03-11", from: second, to: other, 40_00)
    var outBook = out.book
    outBook.accounts.append(second)
    outBook.links.append(DebtAccountLink(accountID: second.id, debtID: f.debt.id, role: .external))
    outBook.txns = [f.txns[0], out.txns.last!]
    #expect(Calc.debtDuplicateHints(outBook, calendar: Self.calendar).isEmpty)
    // A payment between two accounts of the same debt is one transaction: never its own duplicate.
    var within = Fixture()
    _ = within.transfer("2026-03-10", from: within.virtual, to: within.external, 40_00, received: 40_00)
    #expect(Calc.debtDuplicateHints(within.book, calendar: Self.calendar).isEmpty)
    // One account only: nothing to compare.
    var single = Fixture().book
    single.links = [single.links[0]]
    single.txns = f.txns
    #expect(Calc.debtDuplicateHints(single, calendar: Self.calendar).isEmpty)
    // Each transaction is hinted once; the closest day wins.
    var many = f
    _ = many.transfer("2026-03-11", from: other, to: second, 40_00)
    var manyBook = many.book
    manyBook.accounts.append(second)
    manyBook.links.append(DebtAccountLink(accountID: second.id, debtID: f.debt.id, role: .external))
    #expect(Calc.debtDuplicateHints(manyBook, calendar: Self.calendar).count == 1)
  }

  @Test("R-DEBT-21: a linked account without a transaction in the last period is hinted; settled debts are left out")
  func idleAccountHints() {
    var f = Fixture()
    _ = f.transfer("2026-03-01", from: f.mine, to: f.virtual, 10_00)
    let today = Day("2026-03-31")!
    // Virtual account: last transaction 30 days ago. External account: none ever.
    let thirty = Calc.debtIdleAccountHints(f.book, today: today, periodDays: 30, calendar: Self.calendar)
    #expect(Set(thirty.map(\.accountID)) == [f.virtual.id, f.external.id])
    #expect(thirty.first { $0.accountID == f.virtual.id }?.lastTransactionDay == Day("2026-03-01"))
    #expect(thirty.first { $0.accountID == f.external.id }?.lastTransactionDay == nil)
    #expect(thirty.first { $0.accountID == f.virtual.id }?.role == .virtual)
    // A wider period: the virtual account is active again.
    let wide = Calc.debtIdleAccountHints(f.book, today: today, periodDays: 60, calendar: Self.calendar)
    #expect(wide.map(\.accountID) == [f.external.id])
    // A transaction on the external account in the period removes its hint.
    _ = f.expense("2026-03-25", on: f.external, 5_00)
    #expect(Calc.debtIdleAccountHints(f.book, today: today, periodDays: 30, calendar: Self.calendar).map(\.accountID) == [f.virtual.id])
    // Settled debts have no hints.
    var settled = f.book
    settled.debts[0].isSettled = true
    #expect(Calc.debtIdleAccountHints(settled, today: today, calendar: Self.calendar).isEmpty)
  }

  @Test("R-DEBT-18: net worth counts the linked accounts once, through the debt, and only with the flag")
  func netWorthTerm() {
    var f = Fixture(opening: 5_00)
    _ = f.transfer("2026-02-10", from: f.mine, to: f.virtual, 100_00)
    f.records = [DebtRecord(debtID: f.debt.id, kind: .borrowed, day: "2026-02-11", amountMinor: 20_00, currency: .EUR)]
    let accounts = [f.mine, f.virtual, f.external]
    let converter = FakeConverter([("2026-01-01", .EUR, .PLN, "4")], latest: [(.EUR, .PLN, "4")])
    let mineOnly = Calc.netWorth(
      accounts: [f.mine], txns: f.txns, currency: .PLN, converter: converter, calendar: Self.calendar)
    let with = Calc.netWorth(
      accounts: accounts, txns: f.txns, currency: .PLN, converter: converter, debts: f.book, calendar: Self.calendar)
    // Mine −100; the debt: +105 PLN and −20 EUR (−80 PLN) = +25.
    #expect(with.total.minorUnits == mineOnly.total.minorUnits + 105_00 - 80_00)
    #expect(with.accounts.map(\.accountID) == [f.mine.id])
    #expect(with.debts.map(\.balance) == [Money(minorUnits: -20_00, currency: .EUR), Money(minorUnits: 105_00, currency: .PLN)])
    var off = f.book
    off.debts[0].countsInNetWorth = false
    let without = Calc.netWorth(
      accounts: accounts, txns: f.txns, currency: .PLN, converter: converter, debts: off, calendar: Self.calendar)
    #expect(without.total == mineOnly.total)
  }
}
