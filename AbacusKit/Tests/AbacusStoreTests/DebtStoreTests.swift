import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Debts in the store (R-DEBT, C14): records and their legs, flags in reports, deleting, and
/// migration "v10: debts" from a database with debt accounts (synthetic data only).
@Suite("Debts store (C14)")
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
  }

  @Test("R-DEBT-3: every record kind moves my account the right way; balances agree in Swift and SQL")
  func recordKindsMoveMoney() async throws {
    let env = try Env()
    let debt = Debt(personName: "Person A", currency: .PLN)
    try await env.debts.save(debt)
    let start = try await env.balances()[F.bank.id]!
    let kinds: [(DebtRecordKind, Int64)] = [
      (.lent, -100_00), (.theyRepaid, 30_00), (.borrowed, 50_00), (.iRepaid, -20_00), (.paidOnTheirBehalf, -15_00),
      (.forgaveThem, 0), (.forgivenByThem, 0),
    ]
    var expectedBank = start
    var expectedDebt: Int64 = 0
    for (index, (kind, accountDelta)) in kinds.enumerated() {
      let amount = Int64(index + 1) * 10_00
      let record = DebtRecord(debtID: debt.id, kind: kind, day: "2026-03-0\(index + 1)", amountMinor: amount)
      try await env.debts.save(record, leg: DebtLegInput(accountID: F.bank.id, amountMinor: amount))
      expectedBank += kind.movesMoney ? (accountDelta < 0 ? -amount : amount) : 0
      expectedDebt += kind.balanceSign * amount
      #expect(try await env.balances()[F.bank.id] == expectedBank, "\(kind)")
      let (accounts, txns) = try await env.all()
      #expect(Calc.balances(accounts: accounts, txns: txns, calendar: F.calendar)[F.bank.id]?.minorUnits == expectedBank)
    }
    let book = try await env.debts.book()
    #expect(Calc.debtBalances(book)[debt.id]?.minorUnits == expectedDebt)
    // Forgive moves no money: no leg.
    #expect(book.entries.filter { $0.leg != nil }.count == 5)
    // Unflagged legs are transfers without destination: nothing in reports.
    let (accounts, txns) = try await env.all()
    let totals = Calc.listTotals(
      txns: txns.filter { $0.txn.debtRecordID != nil }, accounts: accounts, categories: [], currency: .PLN,
      converter: Self.converter, refundsReduceSpending: false)
    #expect(totals.income.minorUnits == 0 && totals.expense.minorUnits == 0)
  }

  @Test("R-DEBT-3: a different-currency account takes the account amount")
  func crossCurrencyLeg() async throws {
    let env = try Env()
    let debt = Debt(personName: "Person A", currency: .PLN)
    try await env.debts.save(debt)
    try await env.debts.save(
      DebtRecord(debtID: debt.id, kind: .lent, day: "2026-03-02", amountMinor: 43_00),
      leg: DebtLegInput(accountID: F.card.id, amountMinor: 10_00))
    #expect(try await env.balances()[F.card.id] == -10_00)
    #expect(Calc.debtBalances(try await env.debts.book())[debt.id]?.minorUnits == 43_00)
  }

  @Test("R-DEBT-4: flagged records report under a Debts category; unflagged never do; budget counts them")
  func flagsInReports() async throws {
    let env = try Env()
    let debt = Debt(personName: "Person A", currency: .PLN)
    try await env.debts.save(debt)
    try await env.debts.save(
      DebtRecord(debtID: debt.id, kind: .lent, day: "2026-03-02", amountMinor: 100_00, reportKind: .expense),
      leg: DebtLegInput(accountID: F.bank.id, amountMinor: 100_00))
    try await env.debts.save(
      DebtRecord(debtID: debt.id, kind: .theyRepaid, day: "2026-03-03", amountMinor: 40_00, reportKind: .income),
      leg: DebtLegInput(accountID: F.bank.id, amountMinor: 40_00))
    try await env.debts.save(
      DebtRecord(debtID: debt.id, kind: .forgaveThem, day: "2026-03-04", amountMinor: 10_00, reportKind: .expense),
      leg: nil)
    try await env.debts.save(
      DebtRecord(debtID: debt.id, kind: .paidOnTheirBehalf, day: "2026-03-05", amountMinor: 7_00),
      leg: DebtLegInput(accountID: F.bank.id, amountMinor: 7_00))

    let categories = try await env.f.categories.categories(kind: nil, includeArchived: true)
    let expenseDebts = try #require(categories.first { $0.name == "Debts" && $0.kind == .expense })
    let incomeDebts = try #require(categories.first { $0.name == "Debts" && $0.kind == .income })
    // The leg of a flagged record is an expense / income in it.
    let (accounts, txns) = try await env.all()
    let legs = txns.filter { $0.txn.debtRecordID != nil }
    #expect(legs.contains { $0.txn.type == .expense && $0.txn.categoryID == expenseDebts.id && $0.txn.amountMinor == 100_00 })
    #expect(legs.contains { $0.txn.type == .income && $0.txn.categoryID == incomeDebts.id })
    #expect(legs.contains { $0.txn.type == .transfer && $0.txn.amountMinor == 7_00 })

    // The forgiven amount has no leg; the report ledger brings it in.
    let book = try await env.debts.book()
    let ledger = book.reportLedger(calendar: F.calendar)
    let breakdown = Calc.expensesByCategory(
      month: Month("2026-03")!, accounts: accounts + ledger.accounts, categories: categories,
      txns: txns + ledger.txns, currency: .PLN, converter: Self.converter, refundsReduceSpending: false,
      calendar: F.calendar)
    let debtsItem = breakdown.items.first { $0.key == .category(expenseDebts.id) }
    #expect(debtsItem?.total.minorUnits == 110_00)
    let income = Calc.categoryTotals(
      kind: .income, days: nil, accounts: accounts + ledger.accounts, categories: categories,
      txns: txns + ledger.txns, currency: .PLN, converter: Self.converter, refundsReduceSpending: false,
      calendar: F.calendar)
    #expect(income.items.first { $0.key == .category(incomeDebts.id) }?.total.minorUnits == 40_00)
    // The synthetic ledger never changes net worth or real balances.
    let without = Calc.netWorth(accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    let with = Calc.netWorth(
      accounts: accounts + ledger.accounts, txns: txns + ledger.txns, currency: .PLN, converter: Self.converter,
      calendar: F.calendar)
    #expect(without.total == with.total)

    // Budget (R-BUD-2): the flagged expenses count against a Debts limit.
    let plan = BudgetPlan(effectiveMonth: "2026-03", currency: .PLN)
    let status = try #require(
      Calc.budgetStatus(
        month: Month("2026-03")!, plans: [plan],
        allocations: [BudgetAllocation(planID: plan.id, categoryID: expenseDebts.id, limitMinor: 500_00, currency: .PLN)],
        accounts: accounts + ledger.accounts, categories: categories, txns: txns + ledger.txns,
        converter: Self.converter, refundsReduceSpending: false, currency: .PLN, today: Day("2026-03-20")!,
        calendar: F.calendar))
    #expect(status.lines.first?.spent.minorUnits == 110_00)
  }

  @Test("R-DEBT-3: editing a record rewrites its leg; deleting a record or its leg removes both")
  func editAndDelete() async throws {
    let env = try Env()
    let debt = Debt(personName: "Person A", currency: .PLN)
    try await env.debts.save(debt)
    var record = DebtRecord(debtID: debt.id, kind: .lent, day: "2026-03-02", amountMinor: 100_00)
    try await env.debts.save(record, leg: DebtLegInput(accountID: F.bank.id, amountMinor: 100_00))
    let legID = try #require(try await env.debts.book().entries.first?.leg?.id)
    #expect(try await env.f.txns.transaction(legID)?.txn.payee == "Lent to Person A")

    record.kind = .borrowed
    record.amountMinor = 60_00
    try await env.debts.save(record, leg: DebtLegInput(accountID: F.bank.id, amountMinor: 60_00))
    let leg = try #require(try await env.f.txns.transaction(legID)?.txn)
    #expect(leg.isOneSidedInflow && leg.amountMinor == 60_00 && leg.payee == "Borrowed from Person A")
    #expect(try await env.balances()[F.bank.id] == F.bank.openingBalanceMinor + 60_00)

    // No account: the leg goes.
    try await env.debts.save(record, leg: nil)
    #expect(try await env.f.txns.transaction(legID) == nil)
    try await env.debts.save(record, leg: DebtLegInput(accountID: F.bank.id, amountMinor: 60_00))
    let newLeg = try #require(try await env.debts.book().entries.first?.leg)
    // Deleting the leg in the transaction list deletes the record.
    try await env.f.txns.delete(newLeg.id)
    #expect(try await env.debts.book().entries.isEmpty)
    // Deleting a debt deletes its records and legs.
    try await env.debts.save(record, leg: DebtLegInput(accountID: F.bank.id, amountMinor: 60_00))
    try await env.debts.delete(debt.id)
    #expect(try await env.f.txns.transactions(matching: TxnQuery()).allSatisfy { $0.txn.debtRecordID == nil })
    #expect(try await env.balances()[F.bank.id] == F.bank.openingBalanceMinor)
  }

  @Test("R-DEBT-1: the currency is fixed once a debt has records")
  func currencyLocked() async throws {
    let env = try Env()
    var debt = Debt(personName: "Person A", currency: .PLN)
    try await env.debts.save(debt)
    debt.currency = .EUR
    try await env.debts.save(debt)
    try await env.debts.save(DebtRecord(debtID: debt.id, kind: .lent, day: "2026-03-02", amountMinor: 1_00), leg: nil)
    debt.currency = .USD
    await #expect(throws: DebtRepositoryError.currencyLocked) { try await env.debts.save(debt) }
  }

  @Test("R-DEBT-7: net worth includes a debt only with Count in net worth; owed to me = asset, I owe = liability")
  func netWorthTerm() async throws {
    let env = try Env()
    var owedToMe = Debt(personName: "Person A", currency: .EUR)
    let iOwe = Debt(personName: "Person B", currency: .PLN)
    try await env.debts.save(owedToMe)
    try await env.debts.save(iOwe)
    try await env.debts.save(DebtRecord(debtID: owedToMe.id, kind: .lent, day: "2026-02-10", amountMinor: 10_00), leg: nil)
    try await env.debts.save(DebtRecord(debtID: iOwe.id, kind: .borrowed, day: "2026-03-10", amountMinor: 20_00), leg: nil)
    let (accounts, txns) = try await env.all()
    let base = Calc.netWorth(accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, calendar: F.calendar)
    var book = try await env.debts.book()
    let with = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    #expect(with.total.minorUnits == base.total.minorUnits + 43_00 - 20_00)
    #expect(with.assets.minorUnits == base.assets.minorUnits + 43_00)
    #expect(with.liabilities.minorUnits == base.liabilities.minorUnits + 20_00)
    #expect(with.debtsTotal.minorUnits == 23_00)
    // Through a day before the second record only the first counts.
    let february = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, through: Day("2026-02-28")!,
      debts: book, calendar: F.calendar)
    #expect(february.debtsTotal.minorUnits == 43_00)

    owedToMe.countsInNetWorth = false
    try await env.debts.save(owedToMe)
    book = try await env.debts.book()
    let unchecked = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    #expect(unchecked.total.minorUnits == base.total.minorUnits - 20_00)
  }

  @Test("R-DEBT-6: widget totals in the display currency, people largest first, settled left out")
  func widgetSummary() async throws {
    let env = try Env()
    let a = Debt(personName: "Person A", currency: .EUR)
    let aPLN = Debt(personName: "person a ", currency: .PLN)
    let b = Debt(personName: "Person B", currency: .PLN)
    let settled = Debt(personName: "Person C", currency: .PLN, isSettled: true)
    for debt in [a, aPLN, b, settled] { try await env.debts.save(debt) }
    try await env.debts.save(DebtRecord(debtID: a.id, kind: .lent, day: "2026-02-10", amountMinor: 10_00), leg: nil)
    try await env.debts.save(DebtRecord(debtID: aPLN.id, kind: .borrowed, day: "2026-02-10", amountMinor: 3_00), leg: nil)
    try await env.debts.save(DebtRecord(debtID: b.id, kind: .borrowed, day: "2026-02-10", amountMinor: 100_00), leg: nil)
    try await env.debts.save(DebtRecord(debtID: settled.id, kind: .lent, day: "2026-02-10", amountMinor: 5_00), leg: nil)
    let summary = Calc.debtSummary(try await env.debts.book(), currency: .PLN, converter: Self.converter)
    #expect(summary.owedToMe.minorUnits == 43_00)
    #expect(summary.iOwe.minorUnits == 103_00)
    #expect(summary.people.map(\.personName) == ["Person B", "Person A"])
    #expect(summary.people.last?.balances.count == 2)
  }

  // MARK: Migration v10

  /// A pre-v10 database (migrated to v9) with two debt accounts, written with raw SQL.
  static func preV10Database() throws -> any DatabaseWriter {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(database, upTo: "v9: category createdAt")
    try database.write { db in
      func account(_ id: Int, _ name: String, _ currency: String, _ kind: String, _ opening: Int64) throws {
        try db.execute(
          sql: """
            INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate", "position")
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [F.id(id).uuidString.lowercased(), name, currency, kind, opening, F.at("2026-01-01", "00:00"), id])
      }
      try account(1, "Bank", "PLN", "bank", 1_000_00)
      try account(2, "Card", "EUR", "card", 100_00)
      try account(3, "Person B", "PLN", "debt", 0)
      try account(4, "Person C", "PLN", "debt", -50_00)
      try db.execute(
        sql: #"INSERT INTO "categories" ("id", "name", "kind", "position") VALUES (?, 'Food', 'expense', 0)"#,
        arguments: [F.id(10).uuidString.lowercased()])
      func txn(
        _ id: Int, _ type: String, _ day: String, from: Int, _ amount: Int64, to: Int? = nil, toAmount: Int64? = nil,
        category: Int? = nil
      ) throws {
        try db.execute(
          sql: """
            INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "categoryID", "toAccountID",
              "toAmountMinor", "payee", "createdAt")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            F.id(id).uuidString.lowercased(), type, F.at(day), F.id(from).uuidString.lowercased(), amount,
            category.map { F.id($0).uuidString.lowercased() }, to.map { F.id($0).uuidString.lowercased() }, toAmount,
            "Row \(id)", F.at(day),
          ])
      }
      try txn(101, "transfer", "2026-02-01", from: 1, 100_00, to: 3)
      try txn(102, "transfer", "2026-02-10", from: 3, 30_00, to: 1)
      try db.execute(
        sql: """
          INSERT INTO "attachedRecords" ("id", "txnID", "kind", "categoryID", "amountMinor") VALUES (?, ?, 'expense', ?, 500)
          """, arguments: [F.id(201).uuidString.lowercased(), F.id(102).uuidString.lowercased(), F.id(10).uuidString.lowercased()])
      try txn(103, "expense", "2026-02-15", from: 3, 20_00, category: 10)
      try db.execute(
        sql: #"INSERT INTO "importFingerprints" ("id", "txnID") VALUES ('saldo:103', ?)"#,
        arguments: [F.id(103).uuidString.lowercased()])
      try db.execute(
        sql: #"INSERT INTO "importFingerprints" ("id", "txnID") VALUES ('saldo:101', ?)"#,
        arguments: [F.id(101).uuidString.lowercased()])
      try txn(104, "transfer", "2026-02-20", from: 2, 10_00, to: 3, toAmount: 43_00)
      try txn(105, "transfer", "2026-03-01", from: 4, 70_00, to: 1)
      try db.execute(
        sql: """
          INSERT INTO "categoryRules" ("id", "pattern", "origin", "action", "transferAccountID")
          VALUES (?, 'person', 'manual', 'transfer', ?)
          """, arguments: [F.id(301).uuidString.lowercased(), F.id(3).uuidString.lowercased()])
    }
    return database
  }

  @Test("R-DEBT-8: v10 turns debt accounts into debts; own balances, net worth and reports stay equal")
  func migrationFromDebtAccounts() async throws {
    let database = try Self.preV10Database()
    try AbacusDatabase.migrator().migrate(database)

    let accounts = try await SQLiteAccountRepository(database: database, calendar: F.calendar).accounts(includeArchived: true)
    let txns = try await SQLiteTxnRepository(database: database, calendar: F.calendar).transactions(matching: TxnQuery())
    let book = try await SQLiteDebtRepository(database: database, calendar: F.calendar).book()
    let balances = Calc.balances(accounts: accounts, txns: txns, calendar: F.calendar)
    // Own accounts: exactly as before (by hand: 1000 − 100 + 30 + 70; 100 − 10 EUR).
    #expect(balances[F.id(1)]?.minorUnits == 1_000_00)
    #expect(balances[F.id(2)]?.minorUnits == 90_00)
    let sql = try await SQLiteAccountRepository(database: database, calendar: F.calendar).balances(asOf: Day("2100-01-01")!)
    #expect(sql[F.id(1)] == 1_000_00 && sql[F.id(2)] == 90_00)
    // Debt accounts: archived, empty, zero.
    for id in [F.id(3), F.id(4)] {
      let account = try #require(accounts.first { $0.id == id })
      #expect(account.isArchived && account.openingBalanceMinor == 0 && (balances[id]?.minorUnits ?? 0) == 0)
      #expect(!txns.contains { $0.txn.accountID == id || $0.txn.toAccountID == id })
    }
    // Debts with the old balances: B = 100 − 30 − 5 − 20 + 43 = 88; C = −50 − 70 = −120.
    let debtB = try #require(book.debts.first { $0.sourceAccountID == F.id(3) })
    let debtC = try #require(book.debts.first { $0.sourceAccountID == F.id(4) })
    #expect(debtB.personName == "Person B" && debtB.currency == .PLN && debtB.countsInNetWorth && !debtB.isSettled)
    let debtBalances = Calc.debtBalances(book)
    #expect(debtBalances[debtB.id]?.minorUnits == 88_00)
    #expect(debtBalances[debtC.id]?.minorUnits == -120_00)
    #expect(book.entries(of: debtB.id).map(\.record.kind) == [.lent, .theyRepaid, .theyRepaid, .theyRepaid, .lent])
    #expect(book.entries(of: debtC.id).map(\.record.kind) == [.borrowed, .borrowed])
    // Legs in place: same ids, own side kept.
    let leg101 = try #require(txns.first { $0.txn.id == F.id(101) }?.txn)
    #expect(leg101.accountID == F.id(1) && leg101.toAccountID == nil && leg101.amountMinor == 100_00 && leg101.debtRecordID != nil)
    let leg102 = try #require(txns.first { $0.txn.id == F.id(102) })
    #expect(leg102.txn.accountID == F.id(1) && leg102.txn.isOneSidedInflow && leg102.lines.isEmpty)
    #expect(!txns.contains { $0.txn.id == F.id(103) })
    // Net worth equal: 1000 + 90 × 4.3 + 88 − 120 = 1355.
    let netWorth = Calc.netWorth(
      accounts: accounts, txns: txns, currency: .PLN, converter: Self.converter, debts: book, calendar: F.calendar)
    #expect(netWorth.total.minorUnits == 1_355_00)
    // Reports equal: February expenses Food 5 + 20.
    let categories = try await SQLiteCategoryRepository(database: database).categories(kind: nil, includeArchived: true)
    let ledger = book.reportLedger(calendar: F.calendar)
    let february = Calc.expensesByCategory(
      month: Month("2026-02")!, accounts: accounts + ledger.accounts, categories: categories, txns: txns + ledger.txns,
      currency: .PLN, converter: Self.converter, refundsReduceSpending: false, calendar: F.calendar)
    #expect(february.total.minorUnits == 25_00)
    // Fingerprints: the leg keeps its own, the replaced expense's moved to its record.
    let found = try await SQLiteImportStore(database: database, calendar: F.calendar).existingFingerprints(["saldo:101", "saldo:103"])
    #expect(found.count == 2)
    // The transfer rule to the debt account is disabled, not deleted.
    let rules = try await SQLiteRuleRepository(database: database).rules()
    #expect(rules.count == 1 && rules.first?.isEnabled == false)
    // Running the conversion again changes nothing.
    let again = try await database.write { db in try DebtConversion.convertDebtAccounts(db, calendar: F.calendar) }
    #expect(again == DebtConversion.Result())
  }
}
