import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

private let opening = Date(timeIntervalSince1970: 1_767_225_600)
private let personal = Account(
  id: PreviewData.id(9301), name: "Bank PLN", currency: .PLN, kind: .bank, openingDate: opening)
private let business = Account(
  id: PreviewData.id(9302), name: "Business PLN", currency: .PLN, kind: .bank, openingDate: opening)

/// C48: what the owner sees after "Move to another account": the rows in the target account's list
/// (and gone from the source), balances and the screens' caches, and the "Moved from" trace.
@MainActor
@Suite("Moved import batch: lists, balances, trace (C48)")
struct ImportMoveHistoryTests {
  private func imported() async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [personal, business])
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(personal.id)
    h.model.acceptSuggestions()
    await h.model.commit()
    #expect(h.model.step == .done)
    h.model.cancel()
    return h
  }

  /// Not `TransactionFilters.allDates`: its upper bound (31 Dec 9999) overflows to a 5-digit year
  /// in a UTC calendar and matches nothing (noted in docs/status/C48.md).
  static let allDates = TransactionFilters.DateRange.custom(
    from: Day(year: 2000, month: 1, day: 1), to: Day(year: 2100, month: 12, day: 31))

  private func move(_ h: ImportHarness) async throws -> ImportBatch {
    let batch = try #require(h.model.history.first)
    await h.model.requestMove(batch)
    let sheet = try #require(h.model.moveSheet)
    sheet.targetAccountID = business.id
    await h.model.startMove()?.value
    #expect(h.model.moveSheet == nil)
    return batch
  }

  private var txnRepository: (ImportHarness) -> SQLiteTxnRepository {
    { SQLiteTxnRepository(database: $0.database, calendar: ImportHarness.calendar) }
  }

  private func listed(_ h: ImportHarness, account: Account.ID) async throws -> [Txn] {
    try await txnRepository(h).transactions(matching: TxnQuery(accountIDs: [account])).map(\.txn)
  }

  private func balances(_ h: ImportHarness) async throws -> [Account.ID: Int64] {
    try await SQLiteAccountRepository(database: h.database, calendar: ImportHarness.calendar)
      .balances(asOf: Day(year: 2030, month: 1, day: 1))
  }

  private func traces(_ h: ImportHarness) async throws -> [TxnMove] {
    try await h.database.read { db in try TxnMove.all.fetchAll(db) }
  }

  @Test("(a) After a move the target account's list has the rows, the source's has none, balances follow")
  func listsAndBalances() async throws {
    let h = try await imported()
    let before = try await listed(h, account: personal.id)
    #expect(!before.isEmpty)
    let balancesBefore = try await balances(h)
    #expect(try await listed(h, account: business.id).isEmpty)

    _ = try await move(h)

    let onTarget = try await listed(h, account: business.id)
    #expect(Set(onTarget.map(\.id)) == Set(before.map(\.id)))
    #expect(try await listed(h, account: personal.id).isEmpty)
    let balancesAfter = try await balances(h)
    #expect(balancesAfter[business.id] == (balancesBefore[business.id] ?? 0) + (balancesBefore[personal.id] ?? 0))
    #expect(balancesAfter[personal.id] == 0)
    // The list's own aggregate counts them on the target too.
    let summary = try await txnRepository(h).summary(matching: TxnQuery(accountIDs: [business.id]))
    #expect(summary.count == before.count)
  }

  @Test("(a) Transactions, Accounts and Dashboard reload after a move (onDataChanged → session.dataChanged)")
  func screensReload() async throws {
    let h = try await imported()
    let calendar = ImportHarness.calendar
    let session = AppSession.live(
      database: h.database, source: StubSource(rates: []), calendar: calendar, now: { ImportHarness.now },
      formats: Formats(locale: Locale(identifier: "en_GB"), calendar: calendar))
    await session.start()
    defer { session.stop() }
    await session.dataChanged()
    session.transactions.filters.dateRange = Self.allDates
    session.transactions.filters.accountIDs = [business.id]
    await session.transactions.reload()
    #expect(session.transactions.rows.isEmpty)
    let sourceBalance = try #require(session.accounts.balances[personal.id])
    #expect(sourceBalance.minorUnits != 0)

    // The wizard reports the change exactly as the app wires it (RootView).
    h.model.onDataChanged = { Task { await session.dataChanged() } }
    let batch = try await move(h)
    await session.dataChanged()  // the Task above may still be running; this one is awaited

    await session.transactions.reload()
    let rows = session.transactions.rows.map(\.txn)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.importBatchID == batch.id && ($0.accountID == business.id || $0.toAccountID == business.id) })
    #expect(session.accounts.balances[personal.id]?.minorUnits == 0)
    #expect(session.accounts.balances[business.id]?.minorUnits == sourceBalance.minorUnits)
    #expect(session.dashboard.phase == .loaded)
    // Every row of the list carries the trace badge.
    let moved = session.transactions.content.days.flatMap(\.rows)
    #expect(moved.count == rows.count)
    #expect(moved.allSatisfy { $0.badges.contains { $0.kind == .moved && $0.label == "Moved from Bank PLN" } })
  }

  @Test("(b) A moved transaction says where it came from and when; the source side shows nothing")
  func trace() async throws {
    let h = try await imported()
    let batch = try await move(h)
    let stored = try await traces(h)
    let own = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    #expect(Set(stored.map(\.txnID)) == Set(own.map(\.txn.id)))
    #expect(stored.allSatisfy { $0.fromAccountID == personal.id && $0.toAccountID == business.id && $0.batchID == batch.id })

    let store = SQLiteImportStore(database: h.database, calendar: ImportHarness.calendar)
    let read = try await store.moves(for: own.map(\.txn.id) + [UUID()])
    #expect(read.count == own.count)

    // The list row: badge text and hover text.
    let reference = TransactionsReference(accounts: [personal, business])
    let builder = TransactionListContent.Builder(
      summary: TxnListSummary(rows: own), reference: reference, displayCurrency: .PLN, converter: RateTable(),
      today: Day(year: 2030, month: 1, day: 1), calendar: ImportHarness.calendar)
    let content = builder.content(rows: own, moves: read)
    let row = try #require(content.days.flatMap(\.rows).first)
    #expect(row.badges.contains { $0.kind == .moved && $0.label == "Moved from Bank PLN" })
    let note = try #require(row.movedNote)
    #expect(note.hasPrefix("Moved from Bank PLN to Business PLN · "))
    // Not moved: no trace, no badge.
    let plain = builder.content(rows: own)
    #expect(plain.days.flatMap(\.rows).allSatisfy { !$0.badges.contains { $0.kind == .moved } && $0.movedNote == nil })

    // The editor shows the same note.
    var editorDeps = TransactionEditorDependencies.preview()
    editorDeps.transactions = txnRepository(h)
    editorDeps.accounts = SQLiteAccountRepository(database: h.database, calendar: ImportHarness.calendar)
    editorDeps.categories = SQLiteCategoryRepository(database: h.database)
    editorDeps.events = SQLiteEventRepository(database: h.database)
    editorDeps.moves = store
    let editor = TransactionEditorModel(mode: .edit(try #require(own.first).txn.id), dependencies: editorDeps)
    await editor.load()
    #expect(editor.movedNote?.hasPrefix("Moved from Bank PLN to Business PLN · ") == true)
  }

  @Test("(b) The list view model reads the traces with the rows")
  func viewModelTraces() async throws {
    let h = try await imported()
    _ = try await move(h)
    let calendar = ImportHarness.calendar
    let model = TransactionsViewModel(
      transactions: txnRepository(h),
      accounts: SQLiteAccountRepository(database: h.database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: h.database),
      events: SQLiteEventRepository(database: h.database), converter: RateTable(), displayCurrency: .PLN,
      calendar: calendar, today: { Day(year: 2030, month: 1, day: 1) },
      moves: SQLiteImportStore(database: h.database, calendar: calendar))
    model.filters.dateRange = Self.allDates
    await model.load()
        #expect(!model.rows.isEmpty)
    #expect(model.moveTraces.count == model.rows.count)
    #expect(model.content.days.flatMap(\.rows).allSatisfy { $0.movedNote != nil })
  }

  @Test("Undo move leaves no trace; moving on keeps the latest; Undo import clears the traces")
  func undoInterplay() async throws {
    let h = try await imported()
    let batch = try await move(h)
    #expect(!(try await traces(h)).isEmpty)

    // Undo move: the same transactions go back; their traces go away.
    await h.model.startUndoLastMove()?.value
    #expect(try await traces(h).isEmpty)
    #expect(try await listed(h, account: business.id).isEmpty)
    #expect(!(try await listed(h, account: personal.id)).isEmpty)

    // Move again, then undo the import: transactions and their traces are gone, nothing dangles.
    _ = try await move(h)
    #expect(!(try await traces(h)).isEmpty)
    try await SQLiteImportStore(database: h.database, calendar: ImportHarness.calendar).undo(batch.id)
    #expect(try await traces(h).isEmpty)
    #expect(try await h.txns().isEmpty)
  }

  @Test("A chain A→B→C says 'from B'; moving back to B shows 'from A' again")
  func chain() async throws {
    let third = Account(id: PreviewData.id(9303), name: "Savings PLN", currency: .PLN, kind: .bank, openingDate: opening)
    let h = try await ImportHarness.empty(accounts: [personal, business, third])
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(personal.id)
    h.model.acceptSuggestions()
    await h.model.commit()
    h.model.cancel()
    let batch = try #require(h.model.history.first)
    let store = SQLiteImportStore(database: h.database, calendar: ImportHarness.calendar)
    let plan = try await store.movePlan(batch.id)
    let ids = plan.candidates.filter { $0.refusal == nil }.map(\.id)
    try await store.move(batch.id, txnIDs: ids, from: personal.id, to: business.id, at: Date(timeIntervalSince1970: 1_000))
    try await store.move(batch.id, txnIDs: ids, from: business.id, to: third.id, at: Date(timeIntervalSince1970: 2_000))
    var latest = try await store.moves(for: ids)
    #expect(latest.values.allSatisfy { $0.fromAccountID == business.id && $0.toAccountID == third.id })
    try await store.move(batch.id, txnIDs: ids, from: third.id, to: business.id, at: Date(timeIntervalSince1970: 3_000))
    latest = try await store.moves(for: ids)
    #expect(latest.values.allSatisfy { $0.fromAccountID == personal.id && $0.toAccountID == business.id })
  }
}
