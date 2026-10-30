import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// Payments to a person as transfers to their virtual account (R-DEBT-19, C19) through the
/// import action, rules and "transfer to a debt account", on the SQLite store with synthetic PKO
/// rows: one payment is always one transaction, fingerprints stay on it. C22 reshapes the import
/// choice and the matching of hand-entered payments on top of this.
@Suite("Payments to a debt account (C19)")
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

  @Test("R-DEBT-10: kind suggested from the balance — money in while they owe me is They repaid; an existing debt is used")
  func suggestedKinds() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-02", amount: 300_00)
    try await env.handTransfer("Bob", .PLN, inflow: true, day: "2026-01-02", amount: 80_00)
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

  @Test("R-DEBT-10: a Needs review row (unknown PKO type) can be sent to a person's account")
  func reviewRowAsDebt() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    var preview = try await env.pko([Self.unknownType])
    let row = try #require(preview.rows.first { $0.review != nil })
    #expect(row.canRecordDebt)
    preview.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .PLN, kind: .paidOnTheirBehalf)), forRow: row.id)
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
    preview.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR, kind: .lent), forRow: id)
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
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR, kind: .lent), forRow: id)
    #expect(!noRates.canCommit)
    noRates.setDebt(ImportDebtChoice(personName: "Ben", debtID: ben.id, currency: .EUR, kind: .lent, amountMinor: 49_00), forRow: id)
    #expect(noRates.canCommit)
    try await offline.pipeline.commit(noRates)
    #expect(try await offline.debtBalances() == ["Ben EUR": 49_00])
  }

  @Test("R-DEBT-19: a bank row for a payment entered by hand is not imported silently (flagged as a possible duplicate until C22 matches it)")
  func handEnteredPaymentIsFlagged() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await env.handTransfer("Ann", .PLN, inflow: false, day: "2026-01-11", amount: 100_00)
    let preview = try await env.pko([Self.outgoing("2026-01-10", "100.00")])
    #expect(preview.rows.first?.status == .possibleDuplicate)
    #expect(preview.transactionsToCreate == 0)
  }

  // MARK: R-DEBT-12 rules

  @Test("R-DEBT-12: a debt rule sends rows on import to the person's account — one transfer each, hits counted")
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
}
