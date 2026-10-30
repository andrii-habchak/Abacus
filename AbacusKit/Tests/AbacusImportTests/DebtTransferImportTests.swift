import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// Payments to a person as transfers to their virtual account (R-DEBT-19, C19) through the
/// import action, rules and "transfer to a debt account", on the SQLite store with synthetic PKO
/// rows: one payment is always one transaction, fingerprints stay on it. C22: the import choice
/// without kinds, and the matching of payments entered by hand (R-DEBT-13, R-DEBT-19).
@Suite("Payments to a debt account (C19, C22)")
struct DebtTransferImportTests {
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

    /// "Anna PLN" → balance, per person and currency (R-DEBT-18).
    func debtBalances() async throws -> [String: Int64] {
      let book = try await debts.book()
      var result: [String: Int64] = [:]
      for debt in book.debts {
        for balance in book.balances(of: debt.id, calendar: calendar) {
          result["\(debt.personName) \(balance.currency.rawValue)"] = balance.minorUnits
        }
      }
      return result
    }

    /// A payment entered by hand: a transfer between `account` and the person's virtual account
    /// (the debt and the account are created when missing).
    @discardableResult
    func handTransfer(
      _ person: String, _ currency: Currency, inflow: Bool, day: String, amount: Int64,
      account: Account.ID = F.pkoAccount.id
    ) async throws -> Txn {
      var book = try await debts.book()
      var debt = book.debt(person: person)
      if debt == nil {
        let created = Debt(personName: person)
        try await debts.save(created)
        debt = created
      }
      book = try await debts.book()
      let existing = book.accounts(of: debt!.id).first { $0.currency == currency }
      let virtual: Account
      if let existing {
        virtual = existing
      } else {
        virtual = try await debts.createVirtualAccount(for: debt!.id, currency: currency)
      }
      let txn = Txn(
        type: .transfer, occurredAt: F.date(day), accountID: inflow ? virtual.id : account, amountMinor: amount,
        toAccountID: inflow ? account : virtual.id, payee: "by hand", source: .manual)
      try await txns.save(txn, lines: [])
      return txn
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

  // MARK: Import action

  @Test("R-DEBT-10, R-DEBT-19: a new row becomes a transfer to the person's virtual account; re-import and undo")
  func importRowAsDebt() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    let id = try #require(preview.rows.first?.id)
    #expect(preview.rows.first?.canRecordDebt == true)
    let choice = try #require(preview.suggestedDebtChoice(forRow: id, person: "Ann"))
    #expect(choice.debtID == nil)
    preview.setDebt(choice, forRow: id)
    #expect(preview.rows.first?.debt?.personName == "Ann")
    #expect(preview.rows.first?.needsCategory == false)
    #expect(preview.transactionsToCreate == 1)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.debtRecords == 1)

    let txns = try await env.allTxns()
    #expect(txns.count == 1)
    let transfer = try #require(txns.first)
    #expect(transfer.type == .transfer && transfer.accountID == F.pkoAccount.id && transfer.toAccountID != nil)
    #expect(transfer.toAmountMinor == nil && !transfer.isRefund && transfer.debtRecordID == nil)
    #expect(transfer.payee == "ANNA NOWAK")
    #expect(transfer.importBatchID == summary.batch.id)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 100_00)
    #expect(try await env.debtBalances() == ["Ann PLN": 100_00])

    // The fingerprint sits on that transaction: the same file again is already imported.
    let again = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.transactionsToCreate == 0)

    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().isEmpty)
    let book = try await env.debts.book()
    #expect(book.debts.isEmpty && book.links.isEmpty && book.accounts.isEmpty)
    #expect(try await env.accounts.accounts(includeArchived: true).filter { $0.kind == .debt }.isEmpty)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
  }

  @Test("R-DEBT-10, R-DEBT-16: the suggested choice finds the person's debt by name (one per person, any currency) and takes the row's currency")
  func suggestedChoice() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handTransfer("Ann", .EUR, inflow: false, day: "2026-01-02", amount: 300_00)
    let preview = try await env.pko([Self.incoming("2026-01-10", "100.00", ref: "a")])
    let row = try #require(preview.rows.first)
    let ann = try #require(preview.suggestedDebtChoice(forRow: row.id, person: "ann"))
    #expect(ann.debtID != nil && ann.accountID == nil && ann.currency == .PLN)
    let cleo = try #require(preview.suggestedDebtChoice(forRow: row.id, person: "Cleo"))
    #expect(cleo.debtID == nil && cleo.currency == .PLN)
  }

  @Test("R-DEBT-10: a Needs review row (unknown PKO type) can be sent to a person's account")
  func reviewRowAsDebt() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var preview = try await env.pko([Self.unknownType])
    let row = try #require(preview.rows.first { $0.review != nil })
    #expect(row.canRecordDebt)
    preview.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .PLN)), forRow: row.id)
    #expect(preview.canCommit)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.type == .transfer && transfer.toAccountID != nil)
    #expect(try await env.debtBalances() == ["Ann PLN": 5_00])
  }

  @Test("R-DEBT-10, R-DEBT-18: another currency — amount at the day's rate, or entered; without either the commit waits")
  func crossCurrencyImportAction() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let ben = Debt(personName: "Ben")
    try await env.debts.save(ben)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "215.00", "BEN")])
    let id = try #require(preview.rows.first?.id)
    preview.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR), forRow: id)
    #expect(preview.rows.first?.debt?.amountMinor == 50_00)
    try await env.pipeline.commit(preview)
    #expect(try await env.debtBalances() == ["Ben EUR": 50_00])
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.amountMinor == 215_00 && transfer.toAmountMinor == 50_00)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 215_00)

    let offline = try Env(withRates: false)
    try await offline.accounts.save(F.pkoAccount)
    try await offline.debts.save(ben)
    var noRates = try await offline.pko([Self.outgoing("2026-01-10", "215.00", "BEN")])
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR), forRow: id)
    #expect(!noRates.canCommit)
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR, amountMinor: 49_00), forRow: id)
    #expect(noRates.canCommit)
    try await offline.pipeline.commit(noRates)
    #expect(try await offline.debtBalances() == ["Ben EUR": 49_00])
  }

  // MARK: R-DEBT-13 / R-DEBT-19 matching of payments entered by hand

  @Test("R-DEBT-13, R-DEBT-19: a bank row for an outgoing payment entered by hand is Already imported, names the debt, and re-import is an exact match")
  func matchOut() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let hand = try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-11", amount: 100_00)
    let preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    let row = try #require(preview.rows.first)
    #expect(row.status == .alreadyImported)
    #expect(row.linkedDebtLeg?.id == hand.id)
    #expect(row.detail?.contains("Ann") == true)
    #expect(preview.transactionsToCreate == 0)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.debtRecordsMatched == 1 && summary.created == 0)

    // No second transaction, balances unchanged, the fingerprint now sits on the transfer.
    let txns = try await env.allTxns()
    #expect(txns.count == 1 && txns[0].id == hand.id)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 100_00)
    #expect(try await env.debtBalances() == ["Ann PLN": 100_00])
    let again = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.rows.first?.linkedDebtLeg == nil)
    #expect(again.rows.first?.detail == "Imported earlier")

    // Undo of the import removes only its fingerprint; the hand transfer stays.
    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().count == 1)
    let third = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(third.rows.first?.linkedDebtLeg?.id == hand.id)
  }

  @Test("R-DEBT-13, R-DEBT-19: a bank row for money coming in matches the transfer from the person's account")
  func matchIn() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let hand = try await env.handTransfer("Ann", .PLN, inflow: true, day: "2026-01-12", amount: 40_00)
    let preview = try await env.pko([Self.incoming("2026-01-10", "40.00")])
    #expect(preview.rows.first?.status == .alreadyImported)
    #expect(preview.rows.first?.linkedDebtLeg?.id == hand.id)
    try await env.pipeline.commit(preview)
    #expect(try await env.allTxns().count == 1)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 + 40_00)
  }

  @Test("R-DEBT-13: same day and 3 days apart match, 4 days apart does not; direction must agree")
  func matchWindowAndDirection() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let hand = try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-10", amount: 100_00)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(preview.rows.first?.linkedDebtLeg?.id == hand.id)
    preview = try await env.pko([Self.outgoing("2026-01-07", "100.00")])
    #expect(preview.rows.first?.linkedDebtLeg?.id == hand.id)
    preview = try await env.pko([Self.outgoing("2026-01-13", "100.00")])
    #expect(preview.rows.first?.linkedDebtLeg?.id == hand.id)
    preview = try await env.pko([Self.outgoing("2026-01-06", "100.00")])
    #expect(preview.rows.first?.status == .new && preview.rows.first?.linkedDebtLeg == nil)
    preview = try await env.pko([Self.outgoing("2026-01-14", "100.00")])
    #expect(preview.rows.first?.status == .new && preview.rows.first?.linkedDebtLeg == nil)
    // Money in does not match a payment out; another amount does not either.
    preview = try await env.pko([Self.incoming("2026-01-10", "100.00")])
    #expect(preview.rows.first?.linkedDebtLeg == nil)
    preview = try await env.pko([Self.outgoing("2026-01-10", "100.01")])
    #expect(preview.rows.first?.linkedDebtLeg == nil)
  }

  @Test("R-DEBT-13: one transfer serves one row (closest day first), one row serves one transfer")
  func matchOneToOne() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let hand = try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-11", amount: 100_00)
    let two = try await env.pko([
      Self.outgoing("2026-01-08", "100.00", ref: "far"), Self.outgoing("2026-01-10", "100.00", ref: "near"),
    ])
    let byDay = two.rows.sorted { $0.day < $1.day }
    let far = byDay[0]
    let near = byDay[1]
    #expect(near.linkedDebtLeg?.id == hand.id)
    #expect(far.linkedDebtLeg == nil && far.status != .alreadyImported)
    #expect(two.transactionsToCreate == 1)

    // Two hand transfers, one row: one of them is left alone.
    let env2 = try Env()
    try await env2.accounts.save(F.pkoAccount)
    try await env2.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-09", amount: 100_00)
    try await env2.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-10", amount: 100_00)
    let one = try await env2.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(one.rows.count == 1 && one.rows.first?.linkedDebtLeg != nil)
    try await env2.pipeline.commit(one)
    #expect(try await env2.allTxns().count == 2)
  }

  @Test("R-DEBT-13: a transfer made from this bank's own row is not matched by another row — equal payments never swallow each other")
  func ownSourceNotMatched() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.pipeline.commit(try await env.pko([Self.outgoing("2026-01-10", "50.00", ref: "1")]))
    let first = try #require(try await env.allTxns().first)
    try await env.debts.transferToDebt(first.id, to: DebtLink(personName: "Ann"))
    let next = try await env.pko([Self.outgoing("2026-01-10", "50.00", ref: "1"), Self.outgoing("2026-01-11", "50.00", ref: "2")])
    let exact = try #require(next.rows.first { $0.status == .alreadyImported })
    #expect(exact.linkedDebtLeg == nil)
    let second = try #require(next.rows.first { $0.status != .alreadyImported })
    #expect(second.status == .new && second.linkedDebtLeg == nil)
  }

  @Test("R-DEBT-13: a Needs review row (unknown PKO type) for a payment entered by hand is matched too")
  func matchReviewRow() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let hand = try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-08", amount: 5_00)
    let preview = try await env.pko([Self.unknownType])
    let row = try #require(preview.rows.first)
    #expect(row.status == .alreadyImported && row.linkedDebtLeg?.id == hand.id)
    #expect(preview.canCommit)
  }

  @Test("R-DEBT-13, R-DEBT-19: the transfer is also matched when it was made by Transfer to debt account on an import of another source")
  func matchConvertedOtherSource() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let manual = Txn(
      type: .expense, occurredAt: F.date("2026-01-09"), accountID: F.pkoAccount.id, amountMinor: 20_00, payee: "cash", source: .manual)
    try await env.txns.save(manual, lines: [])
    try await env.debts.transferToDebt(manual.id, to: DebtLink(personName: "Ann"))
    let preview = try await env.pko([Self.outgoing("2026-01-10", "20.00")])
    #expect(preview.rows.first?.linkedDebtLeg?.id == manual.id)
  }

  @Test("R-DEBT-20, R-DEBT-13: a row on a debt's linked account is never merged silently into a payment from my account")
  func linkedAccountStatementNotMerged() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-10", amount: 100_00)
    // The statement's own account belongs to the debt (an external account): no automatic link.
    let debt = try #require(try await env.debts.book().debts.first)
    try await env.debts.link(F.pkoAccount.id, to: debt.id, role: .external)
    let preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(preview.rows.first?.linkedDebtLeg == nil)
  }

  @Test("R-DEBT-10, R-DEBT-19: the person's own linked account can be chosen; the transfer goes there, the amount is in its currency")
  func importToLinkedAccount() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let ann = Debt(personName: "Ann")
    try await env.debts.save(ann)
    let external = Account(name: "Ann Revolut", currency: .PLN, kind: .bank, openingDate: F.date("2026-01-01"))
    try await env.accounts.save(external)
    try await env.debts.link(external.id, to: ann.id, role: .external)
    var preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    let id = try #require(preview.rows.first?.id)
    preview.setDebt(ImportDebtChoice(personName: "Ann", debtID: ann.id, accountID: external.id, currency: .PLN), forRow: id)
    #expect(preview.rows.first?.debt?.accountID == external.id)
    #expect(preview.rows.first?.detail?.hasPrefix("Transfer to debt · Ann") == true)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.toAccountID == external.id)
    #expect(try await env.debtBalances() == ["Ann PLN": 100_00])
    let book = try await env.debts.book()
    #expect(book.accounts(of: ann.id).count == 1, "no virtual account was created")

    // An account that is not the debt's is refused in the preview.
    var bad = try await env.pko([Self.outgoing("2026-01-12", "10.00", ref: "x")])
    bad.setDebt(ImportDebtChoice(personName: "Ann", debtID: ann.id, accountID: F.pkoUSD.id, currency: .PLN), forRow: try #require(bad.rows.first?.id))
    #expect(!bad.canCommit)
  }

  // MARK: R-DEBT-12 rules

  @Test("R-DEBT-12: a Transfer-to-debt rule sends rows on import to the person's account — one transfer each, hits counted")
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
    #expect(preview.uncategorisedCount == 0)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.debtRecords == 2)

    let txns = try await env.allTxns()
    #expect(txns.count == 2)
    #expect(txns.allSatisfy { $0.type == .transfer })
    let book = try await env.debts.book()
    #expect(book.debts.count == 1 && book.links.count == 1 && book.records.isEmpty)
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
    #expect(try await only.allTxns().first?.type == .expense)
  }

  @Test("R-DEBT-12: Update existing transactions sends them to the person's account; roll back restores them")
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
    #expect(txns.allSatisfy { $0.type == .transfer })
    #expect(try await env.debtBalances() == ["Anna PLN": 0])
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
    // Transfers are never changed again by the rule.
    #expect(RuleEffect.changes(rule, in: try await env.txns.transactions(matching: TxnQuery()), accounts: [F.pkoAccount], categories: []).isEmpty)

    let rolled = try await env.rules.rollBack(rule.id)
    #expect(rolled.restored == 2)
    let back = try await env.allTxns()
    #expect(back.count == 2)
    #expect(back.allSatisfy { $0.type != .transfer && $0.toAccountID == nil })
    #expect(Set(back.map(\.id)) == Set(originals.map(\.id)))
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00)
    // The debt and its account stay, empty.
    let book = try await env.debts.book()
    #expect(book.debts.count == 1 && book.txns.isEmpty)
  }

  // MARK: R-DEBT-11 transfer to a debt account from the list

  @Test("R-DEBT-11, R-DEBT-19: import → transfer to debt → re-import finds nothing new; the transaction keeps id and fingerprint; undo removes it all")
  func convertThenReimport() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let row = Self.outgoing("2026-01-10", "75.00")
    let summary = try await env.pipeline.commit(try await env.pko([row]))
    let original = try #require(try await env.allTxns().first)
    #expect(original.type == .expense)

    let result = try await env.debts.transferToDebt(original.id, to: DebtLink(personName: "Ann"))
    #expect(result.createdDebt && result.createdAccount)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.id == original.id && transfer.type == .transfer && transfer.toAccountID == result.accountID)
    #expect(transfer.payee == original.payee && transfer.importBatchID == summary.batch.id)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 75_00)
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.transferToDebt(original.id, to: DebtLink(personName: "Ann"))
    }

    let again = try await env.pko([row])
    #expect(again.rows.first?.status == .alreadyImported)
    #expect(again.transactionsToCreate == 0)

    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().isEmpty)
    let book = try await env.debts.book()
    #expect(book.debts.isEmpty && book.accounts.isEmpty)
  }

  @Test("R-DEBT-11: across currencies the amount on the person's side is required")
  func convertCrossCurrency() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.pipeline.commit(try await env.pko([Self.outgoing("2026-01-10", "20.00", ref: "b")]))
    let txn = try #require(try await env.allTxns().first)
    await #expect(throws: DebtRepositoryError.amountUnknown) {
      try await env.debts.transferToDebt(txn.id, to: DebtLink(personName: "Ben", currency: .EUR))
    }
    try await env.debts.transferToDebt(txn.id, to: DebtLink(personName: "Ben", currency: .EUR, amountMinor: 4_65))
    #expect(try await env.debtBalances()["Ben EUR"] == 4_65)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 20_00)
  }

  @Test("R-DEBT-11: transfers between my accounts cannot be sent to a person")
  func convertRefusals() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.accounts.save(F.pkoUSD)
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 1_00,
      toAccountID: F.pkoUSD.id, toAmountMinor: 25)
    try await env.txns.save(transfer, lines: [])
    await #expect(throws: DebtRepositoryError.notLinkable) {
      try await env.debts.transferToDebt(transfer.id, to: DebtLink(personName: "Ann"))
    }
  }

  @Test("R-DEBT-11, R-DEBT-19: Transfer to debt account then Undo — the transaction is an expense again with its fingerprint; a re-import is still an exact match")
  func convertThenUnlink() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let row = Self.outgoing("2026-01-10", "75.00")
    try await env.pipeline.commit(try await env.pko([row]))
    let original = try #require(try await env.allTxns().first)
    try await env.debts.transferToDebt(original.id, to: DebtLink(personName: "Ann"))
    try await env.debts.unlinkTransfer(original.id)
    let back = try #require(try await env.allTxns().first)
    #expect(back.id == original.id && back.type == .expense && back.toAccountID == nil && back.categoryID == nil)
    #expect(try await env.balance(F.pkoAccount.id) == 1_000_00 - 75_00)
    #expect(try await env.debtBalances() == ["Ann PLN": 0])
    #expect(try await env.pko([row]).rows.first?.status == .alreadyImported)
    await #expect(throws: DebtRepositoryError.notDebtTransfer) { try await env.debts.unlinkTransfer(original.id) }
  }

  @Test("R-DEBT-12, R-DEBT-19: RuleEffect shows the real transfer when the person has a virtual account in the currency, skips debt accounts")
  func ruleEffectShapes() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    let handOut = try await env.handTransfer("Anna", .PLN, inflow: false, day: "2026-01-02", amount: 10_00)
    let book = try await env.debts.book()
    let virtual = try #require(book.accounts.first)
    try await env.pipeline.commit(try await env.pko([Self.outgoing("2026-01-10", "30.00", ref: "a"), Self.incoming("2026-01-15", "30.00", ref: "b")]))
    let items = try await env.txns.transactions(matching: TxnQuery()).filter { $0.txn.id != handOut.id }
    let rule = CategoryRule(pattern: "anna nowak", action: .debt, debtPersonName: "Anna")
    let accounts = try await env.accounts.accounts(includeArchived: true)
    let changes = RuleEffect.changes(rule, in: items, accounts: accounts, categories: [], debts: book)
    #expect(changes.count == 2)
    let out = try #require(changes.first { $0.accountID == F.pkoAccount.id })
    #expect(out.type == .transfer && out.toAccountID == virtual.id && !out.isRefund)
    let inflow = try #require(changes.first { $0.toAccountID == F.pkoAccount.id })
    #expect(inflow.accountID == virtual.id)
    // Without the person's account the shape is one-sided (made on apply); a debt account's own
    // transactions are never touched.
    #expect(RuleEffect.changes(CategoryRule(pattern: "anna nowak", action: .debt, debtPersonName: "Nobody"), in: items, accounts: accounts, categories: [], debts: book).allSatisfy { $0.toAccountID == nil })
    let onDebtAccount = Txn(type: .expense, occurredAt: F.date("2026-01-20"), accountID: virtual.id, amountMinor: 5_00, payee: "anna nowak")
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: onDebtAccount, lines: []), accounts: accounts, categories: [], debts: book) == nil)
  }
}
