import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// Debts linked to bank transactions (TA v1.8 R-DEBT-9…13, C17) on the SQLite store, with
/// synthetic PKO and Saldo rows: one payment is always one transaction.
@Suite("Debts linked to bank transactions (C17)")
struct DebtLinkingTests {
  typealias F = PipelineFixture

  /// A fixed day rate for the cross-currency cases: 1 EUR = 4.30 PLN.
  struct FixedRates: CurrencyConverter {
    var latestDay: Day? { nil }
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { latestRate(from: from, to: to) }
    func latestRate(from: Currency, to: Currency) -> Decimal? {
      switch (from, to) {
      case _ where from == to: 1
      case (.EUR, .PLN): Decimal(string: "4.3")
      case (.PLN, .EUR): 1 / Decimal(string: "4.3")!
      default: nil
      }
    }
  }

  struct Env {
    let database: any DatabaseWriter
    var withRates = true

    init(withRates: Bool = true) throws {
      database = try AbacusDatabase.open(at: nil)
      self.withRates = withRates
    }

    var calendar: Calendar { F.calendar }
    var store: SQLiteImportStore { SQLiteImportStore(database: database, calendar: calendar) }
    var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: calendar) }
    var debts: SQLiteDebtRepository { SQLiteDebtRepository(database: database, calendar: calendar) }
    var rules: SQLiteRuleRepository { SQLiteRuleRepository(database: database, calendar: calendar) }

    var pipeline: ImportPipeline {
      let rates: (any CurrencyConverter)? = withRates ? FixedRates() : nil
      return ImportPipeline(
        store: store, accounts: accounts, categories: SQLiteCategoryRepository(database: database),
        events: SQLiteEventRepository(database: database), rules: rules, calendar: calendar,
        converter: { rates })
    }

    func pko(_ rows: [String]) async throws -> ImportPreview {
      try await pipeline.preview(data: F.pko(rows), fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    }

    func allTxns() async throws -> [Txn] { try await txns.transactions(matching: TxnQuery()).map(\.txn) }

    func balance(_ id: Account.ID) async throws -> Int64 {
      try await accounts.balances(asOf: Day("2100-01-01")!)[id] ?? 0
    }

    func debtBalances() async throws -> [String: Int64] {
      let book = try await debts.book()
      var result: [String: Int64] = [:]
      for debt in book.debts { result["\(debt.personName) \(debt.currency.rawValue)"] = book.balance(of: debt.id) }
      return result
    }

    /// A debt record entered by hand on `account` (C14's form): its leg is a manual transaction.
    @discardableResult
    func handRecord(
      _ person: String, _ currency: Currency, _ kind: DebtRecordKind, day: String, amount: Int64,
      account: Account.ID = F.pkoAccount.id, accountAmount: Int64? = nil
    ) async throws -> DebtRecord {
      let book = try await debts.book()
      let debt = book.debt(person: person, currency: currency) ?? Debt(personName: person, currency: currency)
      if !book.debts.contains(where: { $0.id == debt.id }) { try await debts.save(debt) }
      let record = DebtRecord(debtID: debt.id, kind: kind, day: day, amountMinor: amount)
      try await debts.save(record, leg: DebtLegInput(accountID: account, amountMinor: accountAmount ?? amount))
      return record
    }
  }

  static func outgoing(_ day: String, _ amount: String, _ name: String = "ANNA NOWAK", ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-\#(amount)","PLN","+100.00","Rachunek odbiorcy: 11 1111 1111 1111 1111 1111 1111","Nazwa odbiorcy: \#(name)","Tytuł: ZWROT \#(ref)","","","""#
  }

  static func incoming(_ day: String, _ amount: String, _ name: String = "ANNA NOWAK", ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 11 1111 1111 1111 1111 1111 1111","Nazwa nadawcy: \#(name)","Tytuł: ODDAJE \#(ref)","","","""#
  }

  static let unknownType =
    #""2026-01-07","2026-01-07","Opłata za kartę","-5.00","PLN","-767.00","Tytuł: OPŁATA MIESIĘCZNA","","","","","""#

  // MARK: R-DEBT-13 matching

  @Test("Flow of a one-sided debt leg: money in when marked isRefund (the C14 leg), out otherwise")
  func flowOfLegs() {
    let account = F.id(1)
    var leg = Txn(type: .transfer, occurredAt: F.date("2026-01-10"), accountID: account, amountMinor: 100)
    leg.debtRecordID = F.id(99)
    #expect(Flow.of(leg, on: account) == .out)
    leg.isRefund = true
    #expect(Flow.of(leg, on: account) == .in)
    let transfer = Txn(type: .transfer, occurredAt: F.date("2026-01-10"), accountID: account, amountMinor: 100, toAccountID: F.id(2))
    #expect(Flow.of(transfer, on: account) == .out)
    #expect(Flow.of(transfer, on: F.id(2)) == .in)
  }

  @Test(
    "R-DEBT-13: a hand record and the bank row of the same payment — out and in, same day and 3 days apart — stay one transaction",
    arguments: [(false, 0), (false, 3), (true, 0), (true, 3)])
  func matchesHandRecords(inflow: Bool, gap: Int) async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    // They owe me first, so "They repaid" is the natural record for money in.
    if inflow { try await env.handRecord("Ann", .PLN, .lent, day: "2026-01-02", amount: 300_00, accountAmount: nil) }
    let kind: DebtRecordKind = inflow ? .theyRepaid : .lent
    try await env.handRecord("Ann", .PLN, kind, day: "2026-01-10", amount: 120_00)
    let txnsBefore = try await env.allTxns()
    let balanceBefore = try await env.balance(F.pkoAccount.id)
    let debtsBefore = try await env.debtBalances()

    let day = Day("2026-01-10")!.adding(days: gap, calendar: F.calendar).string
    let row = inflow ? Self.incoming(day, "120.00") : Self.outgoing(day, "120.00")
    let preview = try await env.pko([row])
    let only = try #require(preview.rows.first)
    #expect(only.status == .alreadyImported)
    #expect(only.linkedDebtLeg != nil)
    #expect(only.detail?.hasPrefix("Matches the debt record") == true)
    #expect(preview.transactionsToCreate == 0)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.created == 0)
    #expect(summary.debtRecordsMatched == 1)

    #expect(try await env.allTxns().count == txnsBefore.count)
    #expect(try await env.balance(F.pkoAccount.id) == balanceBefore)
    #expect(try await env.debtBalances() == debtsBefore)

    // The row's fingerprint is on the leg now: a re-import is an exact match.
    let again = try await env.pko([row])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.rows.first?.linkedDebtLeg == nil)
    #expect(again.rows.first?.detail == "Imported earlier")
  }

  @Test("R-DEBT-13: four days apart, another amount or the other direction is not the same payment")
  func noMatchOutsideTheRule() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handRecord("Ann", .PLN, .lent, day: "2026-01-10", amount: 120_00)
    let preview = try await env.pko([
      Self.outgoing("2026-01-14", "120.00", ref: "a"),
      Self.outgoing("2026-01-11", "121.00", ref: "b"),
      Self.incoming("2026-01-11", "120.00", ref: "c"),
    ])
    #expect(preview.rows.allSatisfy { $0.linkedDebtLeg == nil })
    #expect(preview.counts.alreadyImported == 0)
  }

  @Test("R-DEBT-13: two equal payments, one hand record — only the closest row is linked")
  func oneLegOneRow() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handRecord("Ann", .PLN, .lent, day: "2026-01-10", amount: 50_00)
    let preview = try await env.pko([
      Self.outgoing("2026-01-12", "50.00", ref: "a"),
      Self.outgoing("2026-01-10", "50.00", ref: "b"),
    ])
    #expect(preview.rows.filter { $0.linkedDebtLeg != nil }.map(\.id) == [preview.rows[1].id])
    #expect(preview.counts.alreadyImported == 1)
    #expect(preview.transactionsToCreate == 1)
  }

  @Test("R-DEBT-13: a cross-currency record (EUR debt, PLN account) matches on the account's amount")
  func crossCurrencyHandRecord() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handRecord("Ben", .EUR, .lent, day: "2026-01-10", amount: 50_00, accountAmount: 215_00)
    let debtsBefore = try await env.debtBalances()
    let preview = try await env.pko([Self.outgoing("2026-01-11", "215.00", "BEN")])
    #expect(preview.rows.first?.status == .alreadyImported)
    try await env.pipeline.commit(preview)
    #expect(try await env.allTxns().count == 1)
    #expect(try await env.debtBalances() == debtsBefore)
  }

  @Test("R-DEBT-13: a Saldo row for a hand-entered record is linked too (any description)")
  func saldoRowMatches() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handRecord("Ann", .PLN, .lent, day: "2026-01-09", amount: 49_99)
    let saldo = F.saldo([
      "9001,2026-01-09T18:00:00,Gave cash,PKO Personal,BANK_ACCOUNTS,0,CREDIT,49.99,PLN",
      "9001,2026-01-09T18:00:00,Gave cash,Shopping,EXPENSES,0,DEBIT,49.99,PLN",
    ])
    let preview = try await env.pipeline.preview(data: saldo, fileName: "saldo.csv")
    let row = try #require(preview.rows.first { $0.source.kind != .openingBalance })
    #expect(row.status == .alreadyImported)
    #expect(row.linkedDebtLeg != nil)
  }

  @Test("R-DEBT-13: a leg made from this bank's own row is not matched by another row of that bank")
  func ownSourceLegNotMatched() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var first = try await env.pko([Self.outgoing("2026-01-10", "50.00", ref: "a")])
    let id = try #require(first.rows.first?.id)
    first.setDebt(ImportDebtChoice(personName: "Ann", currency: .PLN, kind: .lent), forRow: id)
    try await env.pipeline.commit(first)
    // A second, real payment of the same amount the next day.
    let second = try await env.pko([Self.outgoing("2026-01-10", "50.00", ref: "a"), Self.outgoing("2026-01-11", "50.00", ref: "b")])
    #expect(second.counts.alreadyImported == 1)
    #expect(second.transactionsToCreate == 1)
  }

  // MARK: R-DEBT-10 import action

  @Test("R-DEBT-10: a new row becomes a debt record; its transaction is the leg; re-import and undo")
  func importRowAsDebt() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    let id = try #require(preview.rows.first?.id)
    #expect(preview.rows.first?.canRecordDebt == true)
    let choice = try #require(preview.suggestedDebtChoice(forRow: id, person: "Ann"))
    #expect(choice.kind == .lent)
    #expect(choice.debtID == nil)
    preview.setDebt(choice, forRow: id)
    #expect(preview.rows.first?.debt?.personName == "Ann")
    #expect(preview.rows.first?.needsCategory == false)
    #expect(preview.transactionsToCreate == 1)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.debtRecords == 1)

    let txns = try await env.allTxns()
    #expect(txns.count == 1)
    let leg = try #require(txns.first)
    #expect(leg.debtRecordID != nil)
    #expect(leg.type == .transfer && leg.toAccountID == nil && !leg.isRefund)
    #expect(leg.payee == "ANNA NOWAK")
    #expect(leg.importBatchID == summary.batch.id)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 100_00)
    #expect(try await env.debtBalances() == ["Ann PLN": 100_00])

    let again = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.transactionsToCreate == 0)

    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().isEmpty)
    #expect(try await env.debts.book().debts.isEmpty)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
  }

  @Test("R-DEBT-10: kind suggested from the balance — money in while they owe me is They repaid; an existing debt is used")
  func suggestedKinds() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handRecord("Ann", .PLN, .lent, day: "2026-01-02", amount: 300_00)
    try await env.handRecord("Bob", .PLN, .borrowed, day: "2026-01-02", amount: 80_00)
    let preview = try await env.pko([Self.incoming("2026-01-10", "100.00", ref: "a"), Self.outgoing("2026-01-11", "80.00", "BOB", ref: "b")])
    let inRow = try #require(preview.rows.first { $0.isInflow })
    let outRow = try #require(preview.rows.first { !$0.isInflow })
    let ann = try #require(preview.suggestedDebtChoice(forRow: inRow.id, person: "ann"))
    #expect(ann.kind == .theyRepaid)
    #expect(ann.debtID != nil)
    #expect(try #require(preview.suggestedDebtChoice(forRow: outRow.id, person: "Bob")).kind == .iRepaid)
    #expect(try #require(preview.suggestedDebtChoice(forRow: inRow.id, person: "Cleo")).kind == .borrowed)
    #expect(try #require(preview.suggestedDebtChoice(forRow: outRow.id, person: "Cleo")).kind == .lent)
  }

  @Test("R-DEBT-10: a Needs review row (unknown PKO type) can be recorded as a debt record")
  func reviewRowAsDebt() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var preview = try await env.pko([Self.unknownType])
    let row = try #require(preview.rows.first { $0.review != nil })
    #expect(row.canRecordDebt)
    preview.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .PLN, kind: .paidOnTheirBehalf)), forRow: row.id)
    #expect(preview.canCommit)
    try await env.pipeline.commit(preview)
    let leg = try #require(try await env.allTxns().first)
    #expect(leg.debtRecordID != nil)
    #expect(try await env.debtBalances() == ["Ann PLN": 5_00])
    #expect(try await env.debts.book().entries.first?.record.kind == .paidOnTheirBehalf)
  }

  @Test("R-DEBT-10: a debt in another currency — amount at the day's rate, or entered; without either the commit waits")
  func crossCurrencyImportAction() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let eur = Debt(personName: "Ben", currency: .EUR)
    try await env.debts.save(eur)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "215.00", "BEN")])
    let id = try #require(preview.rows.first?.id)
    preview.setDebt(ImportDebtChoice(personName: "Ben", debtID: eur.id, currency: .EUR, kind: .lent), forRow: id)
    #expect(preview.rows.first?.debt?.amountMinor == 50_00)
    try await env.pipeline.commit(preview)
    #expect(try await env.debtBalances() == ["Ben EUR": 50_00])
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 215_00)

    let offline = try Env(withRates: false)
    try await offline.accounts.save(F.pkoAccount)
    try await offline.debts.save(eur)
    var noRates = try await offline.pko([Self.outgoing("2026-01-10", "215.00", "BEN")])
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: eur.id, currency: .EUR, kind: .lent), forRow: id)
    #expect(!noRates.canCommit)
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: eur.id, currency: .EUR, kind: .lent, amountMinor: 49_00), forRow: id)
    #expect(noRates.canCommit)
    try await offline.pipeline.commit(noRates)
    #expect(try await offline.debtBalances() == ["Ben EUR": 49_00])
  }

  // MARK: R-DEBT-12 rules

  @Test("R-DEBT-12: a debt rule records rows on import — one leg each, kinds from the running balance, hits counted")
  func ruleOnImport() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let rule = CategoryRule(pattern: "anna nowak", action: .debt, debtPersonName: "Anna")
    try await env.rules.save(rule)
    let preview = try await env.pko([
      Self.incoming("2026-01-20", "100.00", ref: "back"),
      Self.outgoing("2026-01-10", "100.00", ref: "loan"),
    ])
    #expect(preview.rows.allSatisfy { $0.debt?.ruleID == rule.id })
    #expect(preview.rows.first { !$0.isInflow }?.debt?.kind == .lent)
    #expect(preview.rows.first { $0.isInflow }?.debt?.kind == .theyRepaid)
    #expect(preview.uncategorisedCount == 0)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.debtRecords == 2)

    let txns = try await env.allTxns()
    #expect(txns.count == 2)
    #expect(txns.allSatisfy { $0.debtRecordID != nil })
    let book = try await env.debts.book()
    #expect(book.debts.count == 1)
    #expect(Set(book.entries.map(\.record.kind)) == [.lent, .theyRepaid])
    #expect(book.entries.allSatisfy { $0.leg != nil })
    #expect(try await env.debtBalances() == ["Anna PLN": 0])
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
    #expect(try await env.rules.rules().first?.hitCount == 2)
  }

  @Test("R-DEBT-12: a category rule above the debt rule wins; the user can turn a rule's debt off")
  func ruleOrderAndOverride() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await SQLiteCategoryRepository(database: env.database).save(F.groceries)
    try await env.rules.save(CategoryRule(pattern: "anna", categoryID: F.groceries.id, position: 0))
    try await env.rules.save(CategoryRule(pattern: "nowak", action: .debt, debtPersonName: "Anna", position: 1))
    let first = try await env.pko([Self.outgoing("2026-01-10", "10.00")])
    #expect(first.rows.first?.debt == nil)
    #expect(first.rows.first?.category == .existing(F.groceries.id))

    let only = try Env()
    try await only.accounts.save(F.pkoAccount)
    try await only.rules.save(CategoryRule(pattern: "nowak", action: .debt, debtPersonName: "Anna"))
    var preview = try await only.pko([Self.outgoing("2026-01-10", "10.00")])
    let id = try #require(preview.rows.first?.id)
    #expect(preview.rows.first?.debt != nil)
    preview.setDebt(nil, forRow: id)
    #expect(preview.rows.first?.debt == nil)
    try await only.pipeline.commit(preview)
    #expect(try await only.allTxns().first?.debtRecordID == nil)
  }

  @Test("R-DEBT-12: Update existing transactions converts them; roll back restores them and removes the records")
  func ruleUpdatesExisting() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let preview = try await env.pko([Self.outgoing("2026-01-10", "30.00", ref: "a"), Self.incoming("2026-01-15", "30.00", ref: "b")])
    try await env.pipeline.commit(preview)
    let items = try await env.txns.transactions(matching: TxnQuery())
    let originals = items.map(\.txn)
    let rule = CategoryRule(pattern: "anna nowak", action: .debt, debtPersonName: "Anna")
    let changes = RuleEffect.changes(rule, in: items, accounts: [F.pkoAccount], categories: [])
    #expect(changes.count == 2)
    try await env.rules.apply(rule, records: RuleApplication.records(ruleID: rule.id, originals: originals, changes: changes))

    let txns = try await env.allTxns()
    #expect(txns.count == 2)
    #expect(Set(txns.map(\.id)) == Set(originals.map(\.id)))
    #expect(txns.allSatisfy { $0.debtRecordID != nil })
    #expect(Set(try await env.debts.book().entries.map(\.record.kind)) == [.lent, .theyRepaid])
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
    // Converted legs are never changed again by the rule.
    #expect(RuleEffect.changes(rule, in: try await env.txns.transactions(matching: TxnQuery()), accounts: [F.pkoAccount], categories: []).isEmpty)

    let rolled = try await env.rules.rollBack(rule.id)
    #expect(rolled.restored == 2)
    let back = try await env.allTxns()
    #expect(back.count == 2)
    #expect(back.allSatisfy { $0.debtRecordID == nil && $0.type != .transfer })
    #expect(try await env.debts.book().entries.isEmpty)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
  }

  // MARK: R-DEBT-11 convert

  @Test("R-DEBT-11: import → convert → re-import finds nothing new; the leg keeps id and fingerprint; undo removes the record")
  func convertThenReimport() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let row = Self.outgoing("2026-01-10", "75.00")
    let summary = try await env.pipeline.commit(try await env.pko([row]))
    let original = try #require(try await env.allTxns().first)
    #expect(original.type == .expense)

    let record = try await env.debts.convert(original.id, to: DebtLink(personName: "Ann", currency: .PLN))
    #expect(record.kind == .lent)
    #expect(record.importBatchID == summary.batch.id)
    let leg = try #require(try await env.allTxns().first)
    #expect(leg.id == original.id)
    #expect(leg.debtRecordID == record.id)
    #expect(leg.payee == original.payee)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 75_00)
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.convert(original.id, to: DebtLink(personName: "Ann", currency: .PLN))
    }

    let again = try await env.pko([row])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.transactionsToCreate == 0)

    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().isEmpty)
    #expect(try await env.debts.book().entries.isEmpty)
    #expect(try await env.debts.book().debts.isEmpty)
  }

  @Test("R-DEBT-11: flagged conversion is an expense in Debts; across currencies the amount is required")
  func convertFlaggedAndCrossCurrency() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.pipeline.commit(try await env.pko([Self.outgoing("2026-01-10", "43.00", ref: "a"), Self.outgoing("2026-01-11", "20.00", ref: "b")]))
    let txns = try await env.allTxns().sorted { $0.occurredAt < $1.occurredAt }
    try await env.debts.convert(txns[0].id, to: DebtLink(personName: "Ann", currency: .PLN, kind: .lent, countsInReports: true))
    let flagged = try #require(try await env.allTxns().first { $0.id == txns[0].id })
    #expect(flagged.type == .expense)
    #expect(flagged.categoryID != nil)

    await #expect(throws: DebtRepositoryError.amountUnknown) {
      try await env.debts.convert(txns[1].id, to: DebtLink(personName: "Ben", currency: .EUR))
    }
    try await env.debts.convert(txns[1].id, to: DebtLink(personName: "Ben", currency: .EUR, amountMinor: 4_65))
    #expect(try await env.debtBalances()["Ben EUR"] == 4_65)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 63_00)
  }

  @Test("R-DEBT-11: a kind against the money's direction is refused; transfers cannot be converted")
  func convertRefusals() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.accounts.save(F.pkoUSD)
    try await env.pipeline.commit(try await env.pko([Self.outgoing("2026-01-10", "10.00")]))
    let txn = try #require(try await env.allTxns().first)
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.convert(txn.id, to: DebtLink(personName: "Ann", currency: .PLN, kind: .theyRepaid))
    }
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 1_00,
      toAccountID: F.pkoUSD.id, toAmountMinor: 25)
    try await env.txns.save(transfer, lines: [])
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.convert(transfer.id, to: DebtLink(personName: "Ann", currency: .PLN))
    }
  }
}
