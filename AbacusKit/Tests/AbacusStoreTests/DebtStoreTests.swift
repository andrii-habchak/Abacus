import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Debts in the store (R-DEBT-16…20, C19; docs/status/C19.md): one debt per person, linked
/// accounts, balances per currency, transfers to a virtual account, net worth, report ledger of
/// flagged manual records, the runtime conversion of debt-kind accounts (synthetic data only).
@Suite("Debts store (C19)")
struct DebtStoreTests {
  typealias F = StoreFixture

  static let converter = FixedConverter(rates: ["EURPLN": Decimal(string: "4.3")!])

  struct Env {
    let f: F
    var debts: SQLiteDebtRepository { SQLiteDebtRepository(database: f.database, calendar: F.calendar) }

    init() throws {
      f = try F()
      try f.seedBasics()
    }

    func balances() async throws -> [Account.ID: Int64] {
      try await f.accounts.balances(asOf: Day("2100-01-01")!)
    }

    func all() async throws -> (accounts: [Account], txns: [TxnWithLines]) {
      (try await f.accounts.accounts(includeArchived: true), try await f.txns.transactions(matching: TxnQuery()))
    }

    @discardableResult
    func debt(_ name: String, counts: Bool = false) async throws -> Debt {
      let debt = Debt(personName: name, countsInNetWorth: counts)
      try await debts.save(debt)
      return debt
    }
  }

  // MARK: R-DEBT-16

  @Test("R-DEBT-16: one debt per person without currency; rename keeps the debt; a name is unique per person key")
  func onePersonOneDebt() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna Žuk")
    #expect(!anna.countsInNetWorth, "new debts default to not counting in net worth (R-DEBT-21, D61)")
    // Case, spaces and diacritics do not make another person.
    await #expect(throws: DebtRepositoryError.personExists(anna.id)) {
      try await env.debts.save(Debt(personName: " anna zuk "))
    }
    // Rename: same id, new name; the old name is free again.
    var renamed = anna
    renamed.personName = "Ania"
    try await env.debts.save(renamed)
    let book = try await env.debts.book()
    #expect(book.debts.map(\.personName) == ["Ania"] && book.debts[0].id == anna.id)
    try await env.debts.save(Debt(personName: "Anna Žuk"))
    // Renaming into another person's name is refused.
    var clash = renamed
    clash.personName = "ANNA ŽUK"
    await #expect(throws: DebtRepositoryError.self) { try await env.debts.save(clash) }
  }

  @Test("R-DEBT-16: person names for autocomplete, prefix first, case and diacritics ignored")
  func personNameAutocomplete() async throws {
    let env = try Env()
    for name in ["Maria Sample", "Marek", "Alex Marian", "Zoë"] { try await env.debt(name) }
    #expect(try await env.debts.personNames(matching: "") == ["Alex Marian", "Marek", "Maria Sample", "Zoë"])
    #expect(try await env.debts.personNames(matching: "mar") == ["Marek", "Maria Sample", "Alex Marian"])
    #expect(try await env.debts.personNames(matching: "zoe") == ["Zoë"])
    #expect(try await env.debts.personNames(matching: "nobody").isEmpty)
  }

  // MARK: R-DEBT-17

  @Test("R-DEBT-17: an account belongs to at most one debt; relinking to the same debt only changes the role")
  func atMostOneDebtPerAccount() async throws {
    let env = try Env()
    let a = try await env.debt("Person A")
    let b = try await env.debt("Person B")
    try await env.debts.link(F.card.id, to: a.id, role: .external)
    await #expect(throws: DebtRepositoryError.accountLinkedElsewhere(a.id)) {
      try await env.debts.link(F.card.id, to: b.id, role: .external)
    }
    try await env.debts.link(F.card.id, to: a.id, role: .virtual)
    var book = try await env.debts.book()
    #expect(book.links.count == 1 && book.links[0].role == .virtual && book.debtID(ofAccount: F.card.id) == a.id)
    // Unlinking frees the account for another debt; the account and its transactions stay.
    try await env.debts.unlink(F.card.id)
    try await env.debts.link(F.card.id, to: b.id, role: .external)
    book = try await env.debts.book()
    #expect(book.debtID(ofAccount: F.card.id) == b.id && book.links(of: a.id).isEmpty)
    try await env.debts.unlink(F.loan.id)  // never linked: no-op
    // Deleting a debt removes its links, keeps the account.
    try await env.debts.delete(b.id)
    book = try await env.debts.book()
    #expect(book.links.isEmpty)
    let accounts = try await env.f.accounts.accounts(includeArchived: true)
    #expect(accounts.contains { $0.id == F.card.id })
    await #expect(throws: RepositoryError.self) { try await env.debts.link(F.card.id, to: b.id, role: .external) }
  }

  @Test("R-DEBT-17: a virtual account is a debt-kind account in the chosen currency, linked as virtual, with its own opening balance")
  func virtualAccount() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    let eur = try await env.debts.createVirtualAccount(for: anna.id, currency: .EUR)
    let named = try await env.debts.createVirtualAccount(for: anna.id, currency: .UAH, name: " Anna cash ", openingBalanceMinor: 250_00)
    #expect(eur.kind == .debt && eur.currency == .EUR && eur.name == "Anna (EUR)" && !eur.isArchived)
    #expect(named.name == "Anna cash" && named.openingBalanceMinor == 250_00)
    let book = try await env.debts.book()
    #expect(Set(book.links(of: anna.id).map(\.accountID)) == [eur.id, named.id])
    #expect(book.links.allSatisfy { $0.role == .virtual })
    // The opening balance is part of the balance (R-DEBT-18).
    let balances = Calc.debtBalances(book, calendar: F.calendar)[anna.id]
    #expect(balances == [Money(minorUnits: 0, currency: .EUR), Money(minorUnits: 250_00, currency: .UAH)])
  }

  // MARK: R-DEBT-18

  @Test("R-DEBT-18: balance per currency = linked accounts (opening + transactions) + manual records, never netted")
  func balancePerCurrency() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    // An external EUR account with an opening balance and a statement, a virtual PLN account, a USD record.
    let revolut = Account(
      id: F.id(60), name: "Revolut Anna", currency: .EUR, kind: .bank, openingBalanceMinor: 100_00,
      openingDate: F.at("2026-01-01", "00:00"))
    try await env.f.accounts.save(revolut)
    try await env.debts.link(revolut.id, to: anna.id, role: .external)
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    try await env.f.insert(F.income(61, "2026-03-02", 40_00, nil, account: revolut))
    try await env.f.insert(F.expense(62, "2026-03-04", 15_00, nil, account: revolut))
    try await env.f.insert(F.transfer(63, "2026-03-05", from: F.bank, to: virtual, 70_00))
    try await env.f.insert(F.transfer(64, "2026-03-09", from: virtual, to: F.bank, 10_00))
    try await env.debts.save(
      DebtRecord(debtID: anna.id, kind: .lent, day: "2026-03-06", amountMinor: 5_00, currency: .USD))
    try await env.debts.save(
      DebtRecord(debtID: anna.id, kind: .forgaveThem, day: "2026-03-07", amountMinor: 2_00, currency: .USD))
    // An expense of mine on an unrelated account never touches the debt.
    try await env.f.insert(F.expense(65, "2026-03-08", 9_00, nil))

    let book = try await env.debts.book()
    let balances = Calc.debtBalances(book, calendar: F.calendar)[anna.id]
    #expect(balances == [
      Money(minorUnits: 125_00, currency: .EUR),  // 100 + 40 − 15
      Money(minorUnits: 3_00, currency: .USD),  // lent 5 − forgave 2
      Money(minorUnits: 60_00, currency: .PLN),  // 70 − 10
    ])
    #expect(Calc.debtBalance(book, debtID: anna.id, currency: .PLN, calendar: F.calendar).minorUnits == 60_00)
    #expect(Calc.debtBalance(book, debtID: anna.id, currency: .UAH, calendar: F.calendar).minorUnits == 0)
    // Through a day: the EUR opening counts from its opening day, later rows do not yet.
    let early = Calc.debtBalances(book, through: Day("2026-03-03")!, calendar: F.calendar)[anna.id]
    #expect(early?.first { $0.currency == .EUR }?.minorUnits == 140_00)
    #expect(early?.first { $0.currency == .PLN }?.minorUnits == 0)
    // Per account breakdown.
    let perAccount = Calc.debtAccountBalances(book, debtID: anna.id, calendar: F.calendar)
    #expect(perAccount.first { $0.accountID == revolut.id }?.balance.minorUnits == 125_00)
    #expect(perAccount.first { $0.accountID == revolut.id }?.role == .external)
    #expect(perAccount.first { $0.accountID == virtual.id }?.balance == Money(minorUnits: 60_00, currency: .PLN))
    // Converted total in PLN: 125 EUR × 4.3 + 60 PLN; USD has no rate → no total, gap reported.
    let partial = Calc.debtConvertedTotal(book, debtID: anna.id, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    #expect(partial.total == nil && !partial.unconverted.isEmpty)
    let eurOnly = FixedConverter(rates: ["EURPLN": Decimal(string: "4.3")!, "USDPLN": Decimal(string: "4")!])
    let total = Calc.debtConvertedTotal(book, debtID: anna.id, currency: .PLN, converter: eurOnly, calendar: F.calendar)
    let expectedTotal: Int64 = 125_00 * 43 / 10 + 60_00 + 12_00
    #expect(total.total?.minorUnits == expectedTotal)
  }

  @Test("R-DEBT-18: a linked account's attached records (fees) count in the balance like in any account")
  func attachedLinesCount() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    try await env.f.insert(
      F.transfer(70, "2026-03-02", from: F.bank, to: virtual, 100_00),
      lines: [AttachedRecord(txnID: F.id(70), kind: .expense, categoryID: F.fees.id, amountMinor: 1_00)])
    let book = try await env.debts.book()
    // The fee hits the transfer's source (my bank), not the person's account.
    #expect(Calc.debtBalance(book, debtID: anna.id, currency: .PLN, calendar: F.calendar).minorUnits == 100_00)
    #expect(book.txns.first?.lines.count == 1)
  }

  @Test("R-DEBT-18: net worth counts linked accounts only through the debt (flag on) and never twice")
  func netWorthOnlyThroughDebt() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna", counts: true)
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    let external = Account(
      id: F.id(60), name: "Revolut Anna", currency: .EUR, kind: .bank, openingBalanceMinor: 10_00,
      openingDate: F.at("2026-01-01", "00:00"))
    try await env.f.accounts.save(external)
    try await env.debts.link(external.id, to: anna.id, role: .external)
    try await env.f.insert(F.transfer(61, "2026-03-02", from: F.bank, to: virtual, 70_00))
    try await env.debts.save(DebtRecord(debtID: anna.id, kind: .borrowed, day: "2026-03-03", amountMinor: 5_00, currency: .PLN))

    let (accounts, txns) = try await env.all()
    let owned = accounts.filter { $0.id != virtual.id && $0.id != external.id }
    let mine = Calc.netWorth(accounts: owned, txns: txns, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    var book = try await env.debts.book()
    let with = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    // Only my accounts plus the debt term (70 − 5 PLN, 10 EUR at 4.3), counted once.
    let shownIDs = Set(with.accounts.map(\.accountID))
    #expect(shownIDs == Set(owned.map(\.id)))
    #expect(with.debts.map(\.balance) == [Money(minorUnits: 10_00, currency: .EUR), Money(minorUnits: 65_00, currency: .PLN)])
    #expect(with.debtsTotal.minorUnits == 65_00 + 43_00)
    // The own-account part moved by the transfer (−70) is the only difference outside the debt term.
    #expect(with.total.minorUnits == mine.total.minorUnits + 65_00 + 43_00)

    // Flag off: linked accounts vanish from net worth altogether (no second route in).
    var off = anna
    off.countsInNetWorth = false
    try await env.debts.save(off)
    book = try await env.debts.book()
    let without = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    #expect(without.total == mine.total && without.debts.isEmpty)
    // An archived linked account still carries the debt (flag on again).
    var on = off
    on.countsInNetWorth = true
    try await env.debts.save(on)
    try await env.f.accounts.setArchived(virtual.id, true)
    let (archivedAccounts, archivedTxns) = try await env.all()
    let archived = Calc.netWorth(
      accounts: archivedAccounts, txns: archivedTxns, currency: .PLN, converter: Self.converter,
      debts: try await env.debts.book(), calendar: F.calendar)
    #expect(archived.total == with.total)
    // The chart series agrees with the headline at today's point.
    let series = Calc.netWorthSeries(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, today: Day("2026-03-20")!,
      monthEnds: 2, debts: try await env.debts.book(), calendar: F.calendar)
    #expect(series.today?.value == with.total)
  }

  @Test("R-DEBT-18: widget totals in the display currency, people largest first, settled left out, no netting across currencies")
  func widgetSummary() async throws {
    let env = try Env()
    let a = try await env.debt("Person A")
    let b = try await env.debt("Person B")
    let settled = Debt(personName: "Person C", isSettled: true)
    try await env.debts.save(settled)
    let aEUR = try await env.debts.createVirtualAccount(for: a.id, currency: .EUR)
    try await env.f.insert(F.transfer(80, "2026-02-10", from: F.card, to: aEUR, 10_00))
    try await env.debts.save(DebtRecord(debtID: a.id, kind: .borrowed, day: "2026-02-10", amountMinor: 3_00, currency: .PLN))
    try await env.debts.save(DebtRecord(debtID: b.id, kind: .borrowed, day: "2026-02-10", amountMinor: 100_00, currency: .PLN))
    try await env.debts.save(DebtRecord(debtID: settled.id, kind: .lent, day: "2026-02-10", amountMinor: 5_00, currency: .PLN))
    let summary = Calc.debtSummary(try await env.debts.book(), currency: .PLN, converter: Self.converter, calendar: F.calendar)
    #expect(summary.owedToMe.minorUnits == 43_00)
    #expect(summary.iOwe.minorUnits == 103_00)
    #expect(summary.people.map(\.personName) == ["Person B", "Person A"])
    #expect(summary.people.last?.balances.count == 2)
    #expect(summary.people.last?.debtID == a.id)
  }

  // MARK: R-DEBT-19

  @Test("R-DEBT-19: an expense becomes a transfer to the person's virtual account in place, money out; balances equal")
  func transferOut() async throws {
    let env = try Env()
    let before = try await env.balances()
    var expense = F.expense(100, "2026-03-02", 30_00, F.groceries, payee: "BLIK Anna", note: "dinner")
    expense.importBatchID = nil
    try await env.f.insert(expense)
    try await env.f.imports.commit(ImportCommit(batch: ImportBatch(source: .pko, fileName: "x.csv"), fingerprints: [
      ImportFingerprint(id: "pko:aaa", txnID: F.id(100))
    ]))
    let result = try await env.debts.transferToDebt(F.id(100), to: DebtLink(personName: "Anna"))
    #expect(result.createdDebt && result.createdAccount)

    let moved = try #require(try await env.f.txns.transaction(F.id(100))?.txn)
    #expect(moved.type == .transfer && moved.accountID == F.bank.id && moved.toAccountID == result.accountID)
    #expect(moved.amountMinor == 30_00 && moved.toAmountMinor == nil && moved.categoryID == nil && !moved.isRefund)
    #expect(moved.payee == "BLIK Anna" && moved.note == "dinner", "description and note stay")
    // My account balance is the same as with the expense; the person's account holds the money.
    let after = try await env.balances()
    #expect(after[F.bank.id] == before[F.bank.id]! - 30_00)
    #expect(after[result.accountID] == 30_00)
    let book = try await env.debts.book()
    let debt = try #require(book.debt(person: "anna"))
    #expect(Calc.debtBalance(book, debtID: debt.id, currency: .PLN, calendar: F.calendar).minorUnits == 30_00)
    // Fingerprint stays on the same transaction.
    #expect(try await env.f.imports.existingFingerprints(["pko:aaa"]) == ["pko:aaa": F.id(100)])
    // A second payment reuses the debt and its PLN account.
    try await env.f.insert(F.expense(101, "2026-03-03", 5_00, nil))
    let again = try await env.debts.transferToDebt(F.id(101), to: DebtLink(personName: "ANNA"))
    #expect(!again.createdDebt && !again.createdAccount && again.accountID == result.accountID)
    #expect(try await env.debts.book().links.count == 1)
  }

  @Test("R-DEBT-19: an income becomes a transfer from the person's account to mine (they repaid), same id")
  func transferIn() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    try await env.f.insert(F.income(110, "2026-03-04", 12_00, F.salary, payee: "Anna repaid"))
    let before = try await env.balances()
    let result = try await env.debts.transferToDebt(F.id(110), to: DebtLink(personName: "x", debtID: anna.id))
    #expect(!result.createdDebt && !result.createdAccount && result.accountID == virtual.id)
    let moved = try #require(try await env.f.txns.transaction(F.id(110))?.txn)
    #expect(moved.type == .transfer && moved.accountID == virtual.id && moved.toAccountID == F.bank.id)
    #expect(moved.amountMinor == 12_00 && moved.categoryID == nil && !moved.isRefund)
    let after = try await env.balances()
    #expect(after[F.bank.id] == before[F.bank.id])  // +12 as income, +12 as the transfer's destination
    #expect(after[virtual.id] == -12_00)  // they owe me less
    let book = try await env.debts.book()
    #expect(Calc.debtBalance(book, debtID: anna.id, currency: .PLN, calendar: F.calendar).minorUnits == -12_00)
    // An income reversal is money out (refund flag flips the direction).
    try await env.f.insert(F.income(111, "2026-03-05", 2_00, F.salary, reversal: true))
    try await env.debts.transferToDebt(F.id(111), to: DebtLink(personName: "Anna"))
    let out = try #require(try await env.f.txns.transaction(F.id(111))?.txn)
    #expect(out.accountID == F.bank.id && out.toAccountID == virtual.id)
  }

  @Test("R-DEBT-19: an inflow's attached records stay on my account as their own transactions")
  func inflowLines() async throws {
    let env = try Env()
    try await env.f.insert(
      F.income(120, "2026-03-04", 50_00, F.salary),
      lines: [AttachedRecord(txnID: F.id(120), kind: .expense, categoryID: F.fees.id, amountMinor: 1_00, note: "fee")])
    let before = try await env.balances()[F.bank.id]!
    try await env.debts.transferToDebt(F.id(120), to: DebtLink(personName: "Anna"))
    #expect(try await env.balances()[F.bank.id] == before)
    let all = try await env.f.txns.transactions(matching: TxnQuery())
    let moved = try #require(all.first { $0.txn.id == F.id(120) })
    #expect(moved.lines.isEmpty)
    let fee = try #require(all.first { $0.txn.type == .expense && $0.txn.amountMinor == 1_00 })
    #expect(fee.txn.accountID == F.bank.id && fee.txn.categoryID == F.fees.id && fee.txn.note == "fee")
  }

  @Test("R-DEBT-19: across currencies the person's side takes the original amount, a given amount, or is refused")
  func crossCurrency() async throws {
    let env = try Env()
    // Card is EUR; the person's account is PLN.
    var spent = F.expense(130, "2026-03-02", 10_00, nil, account: F.card)
    spent.originalAmountMinor = 43_00
    spent.originalCurrencyCode = "PLN"
    try await env.f.insert(spent)
    let result = try await env.debts.transferToDebt(F.id(130), to: DebtLink(personName: "Anna", currency: .PLN))
    let txn = try #require(try await env.f.txns.transaction(F.id(130))?.txn)
    #expect(txn.amountMinor == 10_00 && txn.toAmountMinor == 43_00 && txn.toAccountID == result.accountID)
    let account = try #require(try await env.f.accounts.accounts(includeArchived: true).first { $0.id == result.accountID })
    #expect(account.currency == .PLN)

    try await env.f.insert(F.expense(131, "2026-03-03", 10_00, nil, account: F.card))
    await #expect(throws: DebtRepositoryError.amountUnknown) {
      try await env.debts.transferToDebt(F.id(131), to: DebtLink(personName: "Anna", currency: .PLN))
    }
    try await env.debts.transferToDebt(F.id(131), to: DebtLink(personName: "Anna", currency: .PLN, amountMinor: 41_00))
    #expect(try await env.f.txns.transaction(F.id(131))?.txn.toAmountMinor == 41_00)
    // Inflow across currencies: the person's side is the main amount, mine the destination.
    var received = F.income(132, "2026-03-04", 20_00, nil, account: F.card)
    received.originalAmountMinor = 86_00
    received.originalCurrencyCode = "PLN"
    try await env.f.insert(received)
    try await env.debts.transferToDebt(F.id(132), to: DebtLink(personName: "Anna", currency: .PLN))
    let back = try #require(try await env.f.txns.transaction(F.id(132))?.txn)
    #expect(back.accountID == result.accountID && back.amountMinor == 86_00 && back.toAccountID == F.card.id && back.toAmountMinor == 20_00)
    let book = try await env.debts.book()
    #expect(Calc.debtBalance(book, debtID: result.debtID, currency: .PLN, calendar: F.calendar).minorUnits == 43_00 + 41_00 - 86_00)
  }

  @Test("R-DEBT-19: transfers, accounts of a debt and foreign accounts are refused; a given account must be the debt's")
  func transferRefusals() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    let bob = try await env.debt("Bob")
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    try await env.f.insert(F.transfer(140, "2026-03-02", from: F.bank, to: F.loan, 1_00))
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.transferToDebt(F.id(140), to: DebtLink(personName: "Anna"))
    }
    // A transaction on a debt's own account is not "my own account".
    try await env.f.insert(F.expense(141, "2026-03-02", 1_00, nil, account: virtual))
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.transferToDebt(F.id(141), to: DebtLink(personName: "Bob", debtID: bob.id))
    }
    try await env.f.insert(F.expense(142, "2026-03-02", 1_00, nil))
    await #expect(throws: DebtRepositoryError.notDebtAccount) {
      try await env.debts.transferToDebt(F.id(142), to: DebtLink(personName: "Bob", debtID: bob.id, accountID: virtual.id))
    }
    await #expect(throws: RepositoryError.self) { try await env.debts.transferToDebt(F.id(999), to: DebtLink(personName: "Anna")) }
    // Into a chosen external account of the debt.
    let external = Account(
      id: F.id(60), name: "Revolut Anna", currency: .PLN, kind: .bank, openingDate: F.at("2026-01-01", "00:00"))
    try await env.f.accounts.save(external)
    try await env.debts.link(external.id, to: anna.id, role: .external)
    let chosen = try await env.debts.transferToDebt(F.id(142), to: DebtLink(personName: "x", debtID: anna.id, accountID: external.id))
    #expect(chosen.accountID == external.id)
    // A settled debt that gets money again is open again.
    var settled = anna
    settled.isSettled = true
    try await env.debts.save(settled)
    try await env.f.insert(F.expense(143, "2026-03-03", 1_00, nil))
    try await env.debts.transferToDebt(F.id(143), to: DebtLink(personName: "Anna"))
    #expect(try await env.debts.book().debt(anna.id)?.isSettled == false)
  }

  @Test("R-DEBT-19: unlinking a transfer gives the expense or income back on my account")
  func unlinkTransfer() async throws {
    let env = try Env()
    try await env.f.insert(F.expense(150, "2026-03-02", 30_00, F.groceries))
    try await env.f.insert(F.income(151, "2026-03-03", 12_00, F.salary))
    let before = try await env.balances()[F.bank.id]!
    try await env.debts.transferToDebt(F.id(150), to: DebtLink(personName: "Anna"))
    try await env.debts.transferToDebt(F.id(151), to: DebtLink(personName: "Anna"))
    try await env.debts.unlinkTransfer(F.id(150))
    try await env.debts.unlinkTransfer(F.id(151))
    let out = try #require(try await env.f.txns.transaction(F.id(150))?.txn)
    #expect(out.type == .expense && out.accountID == F.bank.id && out.amountMinor == 30_00 && out.toAccountID == nil)
    let back = try #require(try await env.f.txns.transaction(F.id(151))?.txn)
    #expect(back.type == .income && back.accountID == F.bank.id && back.amountMinor == 12_00 && back.toAccountID == nil)
    #expect(try await env.balances()[F.bank.id] == before)
    // Not a debt transfer: an ordinary transfer between my accounts.
    try await env.f.insert(F.transfer(152, "2026-03-04", from: F.bank, to: F.loan, 1_00))
    await #expect(throws: DebtRepositoryError.notDebtTransfer) { try await env.debts.unlinkTransfer(F.id(152)) }
  }

  @Test("R-DEBT-19: undoing the import removes the transfer and the debt and account it created; fingerprints keep a re-import exact")
  func importUndoAndRepeat() async throws {
    let env = try Env()
    let batch = ImportBatch(source: .pko, fileName: "a.csv")
    let row = Txn(
      id: F.id(160), type: .expense, occurredAt: F.at("2026-03-02"), accountID: F.bank.id, amountMinor: 25_00, payee: "ANNA",
      source: .pko, createdAt: F.at("2026-03-02"))
    let commit = ImportCommit(
      batch: batch, txns: [TxnWithLines(txn: row, lines: [])],
      fingerprints: [ImportFingerprint(id: "pko:row1", txnID: row.id)],
      debtLinks: [ImportDebtLink(txnID: row.id, link: DebtLink(personName: "Anna"))])
    try await env.f.imports.commit(commit)
    var book = try await env.debts.book()
    #expect(book.debts.count == 1 && book.links.count == 1 && book.debts[0].importBatchID == batch.id)
    let account = try #require(book.accounts.first)
    #expect(account.importBatchID == batch.id && account.kind == .debt)
    #expect(Calc.debtBalance(book, debtID: book.debts[0].id, currency: .PLN, calendar: F.calendar).minorUnits == 25_00)
    // A repeated import finds the row by its fingerprint: nothing to create twice.
    #expect(try await env.f.imports.existingFingerprints(["pko:row1"]) == ["pko:row1": row.id])
    #expect(try await env.f.txns.transactions(matching: TxnQuery()).filter { $0.txn.payee == "ANNA" }.count == 1)

    try await env.f.imports.undo(batch.id)
    book = try await env.debts.book()
    #expect(book.debts.isEmpty && book.links.isEmpty)
    #expect(try await env.f.txns.transaction(row.id) == nil)
    #expect(try await env.f.accounts.accounts(includeArchived: true).filter { $0.kind == .debt }.isEmpty)
  }

  @Test("R-DEBT-19: undo keeps a debt that has a manual record or an account the import did not create")
  func importUndoKeepsUsedDebts() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    let batch = ImportBatch(source: .pko, fileName: "a.csv")
    let row = Txn(
      id: F.id(161), type: .expense, occurredAt: F.at("2026-03-02"), accountID: F.bank.id, amountMinor: 25_00,
      payee: "ANNA", source: .pko, createdAt: F.at("2026-03-02"))
    let virtual = try await env.debts.createVirtualAccount(for: anna.id, currency: .PLN)
    try await env.f.imports.commit(
      ImportCommit(
        batch: batch, txns: [TxnWithLines(txn: row, lines: [])],
        debtLinks: [ImportDebtLink(txnID: row.id, link: DebtLink(personName: "Anna", debtID: anna.id))]))
    try await env.f.imports.undo(batch.id)
    let book = try await env.debts.book()
    #expect(book.debts.map(\.id) == [anna.id] && book.links.map(\.accountID) == [virtual.id])
  }

  // MARK: Manual records and reports (R-DEBT-4 stays)

  @Test("R-DEBT-18, R-DEBT-4: a flagged manual record reports under a Debts category in its own currency; unflagged never")
  func flagsInReports() async throws {
    let env = try Env()
    let anna = try await env.debt("Anna")
    try await env.debts.save(
      DebtRecord(debtID: anna.id, kind: .forgaveThem, day: "2026-03-04", amountMinor: 10_00, currency: .PLN, reportKind: .expense))
    try await env.debts.save(
      DebtRecord(debtID: anna.id, kind: .forgaveThem, day: "2026-03-05", amountMinor: 2_00, currency: .EUR, reportKind: .expense))
    try await env.debts.save(DebtRecord(debtID: anna.id, kind: .lent, day: "2026-03-06", amountMinor: 7_00, currency: .PLN))
    let categories = try await env.f.categories.categories(kind: nil, includeArchived: true)
    let expenseDebts = try #require(categories.first { $0.name == "Debts" && $0.kind == .expense })
    let (accounts, txns) = try await env.all()
    let book = try await env.debts.book()
    let ledger = book.reportLedger(calendar: F.calendar)
    #expect(ledger.txns.count == 2 && ledger.accounts.allSatisfy(\.isArchived))
    let breakdown = Calc.expensesByCategory(
      month: Month("2026-03")!, accounts: accounts + ledger.accounts, categories: categories,
      txns: txns + ledger.txns, currency: .PLN, converter: Self.converter, refundsReduceSpending: false,
      calendar: F.calendar)
    let debtsTotal: Int64 = 10_00 + 8_60
    #expect(breakdown.items.first { $0.key == .category(expenseDebts.id) }?.total.minorUnits == debtsTotal)
    // The synthetic ledger never changes net worth or real balances.
    let without = Calc.netWorth(accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    let with = Calc.netWorth(
      accounts: accounts + ledger.accounts, txns: txns + ledger.txns, currency: .PLN, converter: Self.converter,
      calendar: F.calendar)
    #expect(without.total == with.total)
    // Records validate: a bad day or a missing debt is refused.
    await #expect(throws: DebtRepositoryError.invalidRecord) {
      try await env.debts.save(DebtRecord(debtID: anna.id, kind: .lent, day: "nope", amountMinor: 1, currency: .PLN))
    }
    await #expect(throws: RepositoryError.self) {
      try await env.debts.save(DebtRecord(debtID: UUID(), kind: .lent, day: "2026-03-01", amountMinor: 1, currency: .PLN))
    }
    try await env.debts.deleteRecord(book.records[0].id)
    await #expect(throws: RepositoryError.self) { try await env.debts.deleteRecord(book.records[0].id) }
  }

  // MARK: Runtime conversion (imports of debt-kind accounts)

  @Test("R-DEBT-17: a debt-kind account without a debt gets one, linked as virtual, by name; nothing else is rewritten")
  func debtKindAccountsGetADebt() async throws {
    let env = try Env()
    let friend = Account(
      id: F.id(70), name: "Friend Ann", currency: .UAH, kind: .debt, openingBalanceMinor: -50_00,
      openingDate: F.at("2026-01-01", "00:00"))
    let archived = Account(
      id: F.id(71), name: "Old Debt", currency: .UAH, kind: .debt, openingDate: F.at("2026-01-01", "00:00"), isArchived: true)
    try await env.f.accounts.save(friend)
    try await env.f.accounts.save(archived)
    try await env.f.insert(F.transfer(170, "2026-03-02", from: F.bank, to: friend, 10_00))
    let result = try await env.f.database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: F.calendar) }
    #expect(result.accounts == 2 && result.debtsCreated == 2)
    let book = try await env.debts.book()
    let ann = try #require(book.debt(person: "friend ann"))
    #expect(ann.sourceAccountID == friend.id && ann.countsInNetWorth && !ann.isSettled)
    let old = try #require(book.debt(person: "Old Debt"))
    #expect(old.isSettled && !old.countsInNetWorth)
    #expect(book.links.allSatisfy { $0.role == .virtual })
    // The account keeps its opening balance and transactions: −50 + 10 (transfer in).
    #expect(Calc.debtBalance(book, debtID: ann.id, currency: .UAH, calendar: F.calendar).minorUnits == -40_00)
    // Again: nothing left to do. A second account of the same person joins that debt.
    let again = try await env.f.database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: F.calendar) }
    #expect(again == DebtConversion.Result())
    try await env.f.accounts.save(
      Account(id: F.id(72), name: "friend ann", currency: .PLN, kind: .debt, openingDate: F.at("2026-01-01", "00:00")))
    let joined = try await env.f.database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: F.calendar) }
    #expect(joined.accounts == 1 && joined.debtsCreated == 0)
    #expect(try await env.debts.book().links(of: ann.id).count == 2)
  }
}
