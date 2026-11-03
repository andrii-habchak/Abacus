import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// N6: the Reconcile screen's model (R-CLR-5, R-CLR-6) and the cleared filter of the list (R-CLR-4).
@MainActor
@Suite("Reconcile screen (N6)")
struct ReconcileModelTests {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
  }()

  static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
  static func at(_ day: String) -> Date {
    let d = Day(day)!
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))!
  }

  static let bank = Account(id: id(1), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 2000_00, openingDate: at("2026-09-30"))
  static let cash = Account(id: id(2), name: "Cash PLN", currency: .PLN, kind: .cash, openingBalanceMinor: 300_00, openingDate: at("2026-09-30"))

  struct Fixture {
    var database: any DatabaseWriter
    var dependencies: ManageDependencies
  }

  static func fixture() async throws -> Fixture {
    let database = try AbacusDatabase.open(at: nil)
    let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
    try await accounts.save(bank)
    try await accounts.save(cash)
    let dependencies = ManageDependencies(
      accounts: accounts, categories: SQLiteCategoryRepository(database: database),
      txns: SQLiteTxnRepository(database: database, calendar: calendar), budget: SQLiteBudgetRepository(database: database),
      events: SQLiteEventRepository(database: database), rules: SQLiteRuleRepository(database: database, calendar: calendar),
      settings: SQLiteSettingsRepository(database: database), converter: { RateTable() },
      today: { Day("2026-10-25")! }, format: ManageFormat(locale: Locale(identifier: "en_US"), calendar: calendar),
      debts: nil)
    var copy = dependencies
    copy.reconcile = SQLiteReconcileRepository(database: database, calendar: calendar)
    return Fixture(database: database, dependencies: copy)
  }

  static func save(_ f: Fixture, _ txn: Txn) async throws {
    try await SQLiteTxnRepository(database: f.database, calendar: calendar).save(txn, lines: [])
  }

  static func expense(_ n: Int, _ day: String, _ minor: Int64, account: Account = bank, cleared: Bool = false, source: TxnSource = .manual, pending: Bool = false, booked: String? = nil) -> Txn {
    Txn(
      id: id(100 + n), type: .expense, occurredAt: at(day), accountID: account.id, amountMinor: minor, payee: "T\(n)", source: source,
      isPendingAtBank: pending, bookedDay: booked, isCleared: cleared)
  }

  @Test("R-CLR-5: the walkthrough: difference, ticking, adding, editing, deleting, settling, finishing")
  func walkthrough() async throws {
    let f = try await Self.fixture()
    for txn in [
      Self.expense(1, "2026-10-02", 100_00, cleared: true, source: .pko),
      Self.expense(2, "2026-10-12", 46_00),  // hand-typed; the bank booked it
      Self.expense(3, "2026-10-17", 23_00, source: .pko, pending: true),
      Self.expense(4, "2026-10-19", 64_00),  // hand-typed; not on the statement
    ] { try await Self.save(f, txn) }
    let model = ReconcileModel(dependencies: f.dependencies, accountID: Self.bank.id, offer: (Day("2026-10-21")!, 1854_00))
    await model.load()
    #expect(model.phase == .setup && model.closingMinor == 1854_00 && model.canStart)
    model.start()
    // Opening 2000 − 100 cleared = 1900 against the statement's 1854: the statement is lower by 46.
    #expect(model.differenceMinor == -46_00 && !model.isBalanced)
    #expect(model.toCheck.map(\.payee) == ["T4", "T3", "T2"])
    #expect(model.toCheck.first { $0.payee == "T3" }.map { !$0.canTick && $0.canSettle && $0.canDelete } == true)

    model.setTicked(Self.id(102), true)
    #expect(model.isBalanced)
    // Staging only: nothing is written yet.
    #expect(model.hasStaged)
    let before = try await SQLiteTxnRepository(database: f.database, calendar: Self.calendar).transaction(Self.id(102))
    #expect(before?.txn.isCleared == false)

    // Add a payment the statement has: counted at once, already cleared.
    model.beginAdd()
    model.addForm?.description = "Parking"
    model.addForm?.amountText = "-10.00"
    #expect(model.canSaveAdd)
    model.saveAdd()
    #expect(model.differenceMinor == 10_00)
    // Edit the typed 46.00 to 36.00 and the sum lines up again.
    model.beginEdit(Self.id(102))
    model.editForm?.amountText = "36.00"
    model.commitEdit()
    #expect(model.isBalanced)
    model.delete(Self.id(104))
    model.markSettled(Self.id(103))
    #expect(model.isBalanced && model.toCheck.map(\.payee).contains("T3"))

    await model.finish()
    #expect(model.notice?.hasPrefix("Reconciled PKO Personal to") == true)
    let rows = try await SQLiteTxnRepository(database: f.database, calendar: Self.calendar)
      .transactions(matching: TxnQuery(accountIDs: [Self.bank.id]))
    func txn(_ n: Int) -> Txn? { rows.first { $0.txn.id == Self.id(100 + n) }?.txn }
    #expect(txn(2)?.isCleared == true && txn(2)?.amountMinor == 36_00)
    #expect(txn(4) == nil)
    #expect(txn(3)?.isPendingAtBank == false && txn(3)?.isCleared == false)
    #expect(rows.contains { $0.txn.payee == "Parking" && $0.txn.isCleared })
    let last = try await SQLiteReconcileRepository(database: f.database, calendar: Self.calendar).lastReconciliations()[Self.bank.id]
    #expect(last?.closingMinor == 1854_00 && last?.statementDay == "2026-10-21")
  }

  @Test("R-CLR-5: Finish needs a zero difference, or an explicit correction")
  func correction() async throws {
    let f = try await Self.fixture()
    try await Self.save(f, Self.expense(1, "2026-10-02", 100_00, cleared: true, source: .pko))
    let model = ReconcileModel(dependencies: f.dependencies, accountID: Self.bank.id, offer: (Day("2026-10-21")!, 1905_00))
    await model.load()
    model.start()
    #expect(model.differenceMinor == 5_00 && model.correctionText?.hasPrefix("+") == true)
    await model.finish()  // refused: not balanced
    #expect(model.notice == nil)
    await model.finish(withCorrection: true)
    #expect(model.notice?.contains("balance correction") == true)
    let rows = try await SQLiteTxnRepository(database: f.database, calendar: Self.calendar).transactions(matching: TxnQuery(accountIDs: [Self.bank.id]))
    let correction = try #require(rows.first { $0.txn.isBalanceCorrection }?.txn)
    #expect(correction.type == .income && correction.amountMinor == 5_00 && correction.isCleared)
  }

  @Test("R-CLR-6: cash compares the whole balance; Finish marks every row up to the date cleared; a difference becomes a correction")
  func cash() async throws {
    let f = try await Self.fixture()
    try await Self.save(f, Self.expense(1, "2026-10-22", 42_00, account: Self.cash))
    try await Self.save(f, Self.expense(2, "2026-10-23", 15_00, account: Self.cash))
    try await Self.save(f, Self.expense(3, "2026-10-30", 20_00, account: Self.cash))  // after the count date
    let model = ReconcileModel(dependencies: f.dependencies, accountID: Self.cash.id)
    await model.load()
    #expect(model.isCash)
    model.statementDay = Self.at("2026-10-24")
    model.closingText = "238.00"
    model.start()
    // 300 − 42 − 15 = 243 against the counted 238.
    #expect(model.differenceMinor == -5_00)
    #expect(model.afterDate.map(\.payee) == ["T3"])
    await model.finish(withCorrection: true)
    let rows = try await SQLiteTxnRepository(database: f.database, calendar: Self.calendar).transactions(matching: TxnQuery(accountIDs: [Self.cash.id]))
    #expect(rows.filter { $0.txn.payee == "T1" || $0.txn.payee == "T2" }.allSatisfy { $0.txn.isCleared })
    #expect(rows.first { $0.txn.payee == "T3" }?.txn.isCleared == false)
    #expect(rows.contains { $0.txn.isBalanceCorrection && $0.txn.type == .expense && $0.txn.amountMinor == 5_00 })
  }

  @Test("R-CLR-5: Cancel discards every staged change; a bank-file row cannot be deleted or edited here")
  func cancelAndRefusals() async throws {
    let f = try await Self.fixture()
    try await Self.save(f, Self.expense(1, "2026-10-02", 100_00, cleared: true, source: .pko))
    try await Self.save(f, Self.expense(2, "2026-10-12", 46_00))
    let model = ReconcileModel(dependencies: f.dependencies, accountID: Self.bank.id, offer: (Day("2026-10-21")!, 1854_00))
    await model.load()
    model.start()
    model.showCleared = true
    let bankRow = try #require(model.alreadyCleared.first)
    #expect(!bankRow.canDelete && !bankRow.canEdit)
    model.setTicked(Self.id(102), true)
    model.delete(Self.id(102))
    #expect(model.toCheck.isEmpty)
    var closed = false
    model.onClose = { closed = true }
    model.cancel()
    #expect(closed && !model.hasStaged)
    #expect(model.toCheck.map(\.payee) == ["T2"])
  }

  @Test("R-CLR-4: the cleared filter and the row indicator; mark cleared, uncleared and settled from the list")
  func listFilterAndMarks() async throws {
    let f = try await Self.fixture()
    for txn in [
      Self.expense(1, "2026-10-02", 100_00, cleared: true, source: .pko),
      Self.expense(2, "2026-10-12", 46_00),
      Self.expense(3, "2026-10-17", 23_00, source: .pko, pending: true),
    ] { try await Self.save(f, txn) }
    let store = SQLiteTxnRepository(database: f.database, calendar: Self.calendar)
    func ids(_ filter: ClearedFilter) async throws -> Set<Txn.ID> {
      Set(try await store.transactions(matching: TxnQuery(cleared: filter)).map(\.txn.id))
    }
    #expect(try await ids(.all).count == 3)
    #expect(try await ids(.cleared) == [Self.id(101)])
    #expect(try await ids(.uncleared) == [Self.id(102), Self.id(103)])

    let model = TransactionsViewModel(
      transactions: store, accounts: SQLiteAccountRepository(database: f.database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: f.database), events: SQLiteEventRepository(database: f.database),
      converter: RateTable(), displayCurrency: .PLN,
      filters: TransactionFilters(dateRange: TransactionFilters.allDates), calendar: Self.calendar,
      today: { Day("2026-10-25")! }, reconcile: SQLiteReconcileRepository(database: f.database, calendar: Self.calendar))
    await model.load()
    let marks = Dictionary(uniqueKeysWithValues: model.content.days.flatMap(\.rows).map { ($0.id, $0.cleared) })
    #expect(marks[Self.id(101)] == .cleared && marks[Self.id(102)] == .uncleared && marks[Self.id(103)] == .pending)
    var filters = TransactionFilters.default
    #expect(!filters.hasActiveFilters)
    filters.cleared = .uncleared
    #expect(filters.hasActiveFilters)

    await model.setCleared([Self.id(102), Self.id(103)], true)  // the hold is skipped
    #expect(try await store.transaction(Self.id(102))?.txn.isCleared == true)
    #expect(try await store.transaction(Self.id(103))?.txn.hasNoClearedSide == true)
    await model.markSettled([Self.id(103)])
    let held = try await #require(store.transaction(Self.id(103))).txn
    #expect(!held.isPendingAtBank && !held.isCleared)
    model.filters.cleared = .all
    await model.reload()
    await model.setCleared([Self.id(102)], false)
    #expect(try await store.transaction(Self.id(102))?.txn.isCleared == false)
  }
}
