import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C40: the transfer popup of the import review (double click on a transfer row) and the account
/// and date pickers of "Find the other side…" (synthetic PKO rows).
@MainActor
struct ImportTransferPopupTests {
  private static let opening = Date(timeIntervalSince1970: 1_767_225_600)
  private static let pln = Account(
    id: PreviewData.id(9701), name: "Main PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: opening, iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let savings = Account(
    id: PreviewData.id(9702), name: "Savings PLN", currency: .PLN, kind: .bank, openingDate: opening,
    iban: "77 7777 7777 7777 7777 7777 7777")
  private static let cash = Account(id: PreviewData.id(9703), name: "Cash PLN", currency: .PLN, kind: .cash, openingDate: opening)
  private static let usd = Account(
    id: PreviewData.id(9704), name: "Dollars", currency: .USD, kind: .bank, openingDate: opening,
    iban: "55 5555 5555 5555 5555 5555 5555")

  private struct Rates: CurrencyConverter {
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
      if from == to { return 1 }
      if from == .USD, to == .PLN { return 4 }
      if from == .PLN, to == .USD { return Decimal(string: "0.25") }
      return nil
    }
    func latestRate(from: Currency, to: Currency) -> Decimal? { rate(from: from, to: to, on: Day("2026-03-01")!) }
    var latestDay: Day? { Day("2026-03-01")! }
  }

  private static let header =
    #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#

  private static func file(_ rows: [String]) -> Data {
    (([header] + rows).joined(separator: "\r\n") + "\r\n").data(using: .windowsCP1250)!
  }

  private static func toSavings(_ day: String) -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-100.00","PLN","+100.00","Rachunek odbiorcy: 77 7777 7777 7777 7777 7777 7777","Nazwa odbiorcy: JAN PRZYKLAD","Tytuł: OSZCZEDNOSCI","","","""#
  }

  private static func date(_ day: String) -> Date {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    return ImportHarness.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
  }

  private struct World {
    let database: any DatabaseWriter
    let model: ImportWizardModel
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: ImportHarness.calendar) }
    func all() async throws -> [Txn] { try await txns.transactions(matching: TxnQuery()).map(\.txn) }
  }

  private func world() async throws -> World {
    let database = try AbacusDatabase.open(at: nil)
    let repository = SQLiteAccountRepository(database: database, calendar: ImportHarness.calendar)
    for account in [Self.pln, Self.savings, Self.cash, Self.usd] { try await repository.save(account) }
    let model = ImportWizardModel(
      dependencies: .live(
        database: database, calendar: ImportHarness.calendar, now: { ImportHarness.now }, converter: { Rates() }))
    await model.load()
    await model.open(data: Self.file([Self.toSavings("2026-03-10")]), fileName: "pko.csv")
    if model.needsTargetAccount { await model.chooseTargetAccount(Self.pln.id) }
    return World(database: database, model: model)
  }

  private func transferRowID(_ model: ImportWizardModel) throws -> String {
    try #require(model.rowItems.first { $0.statusLabel == "New transfer" }).id
  }

  @Test("double click opens the popup with both accounts, why it is a transfer and the day's transactions")
  func opensWithSides() async throws {
    let w = try await world()
    let stored = Txn(
      type: .expense, occurredAt: Self.date("2026-03-10"), accountID: Self.savings.id, amountMinor: 7_00, payee: "ATM FEE",
      source: .manual)
    try await w.txns.save(stored, lines: [])
    let model = w.model
    let id = try transferRowID(model)
    #expect(model.canEditTransfer(row: id))
    model.openTransferEditor(forRow: id)
    let editor = try #require(model.transferEditor)
    #expect(editor.fromAccountID == Self.pln.id && editor.toAccountID == Self.savings.id)
    #expect(editor.statementEnd == .from)
    #expect(editor.title == "Transfer · JAN PRZYKLAD")
    #expect(editor.relations == ["The other account was recognised by its account number in the file"])
    #expect(editor.fromNote.contains("PLN accounts only"))
    #expect(!editor.fromItems.contains { $0.id == Self.usd.id })
    #expect(editor.toItems.contains { $0.id == Self.usd.id })
    #expect(editor.canChangeTransaction)

    await editor.load()
    #expect(editor.fromLines.map(\.badge) == ["This transfer"])
    #expect(Set(editor.toLines.map(\.title)) == ["JAN PRZYKLAD", "ATM FEE"])
    #expect(editor.toLines.first { $0.title == "ATM FEE" }?.subtitle.contains("already in Abacus") == true)
  }

  @Test("Save changes From and To; the row and the commit follow")
  func saveBothSides() async throws {
    let w = try await world()
    let model = w.model
    let id = try transferRowID(model)
    model.openTransferEditor(forRow: id)
    let editor = try #require(model.transferEditor)
    editor.fromAccountID = Self.savings.id
    editor.toAccountID = Self.cash.id
    #expect(editor.hasChanges)
    model.saveTransferEditor()
    #expect(model.transferEditor == nil)
    #expect(model.rowItems.first { $0.id == id }?.account == "Savings PLN → Cash PLN")
    await model.commit()
    let transfer = try #require(try await w.all().first)
    #expect(transfer.accountID == Self.savings.id && transfer.toAccountID == Self.cash.id && transfer.amountMinor == 100_00)
  }

  @Test("a refused change keeps the popup open with the reason")
  func refusedChange() async throws {
    let w = try await world()
    let model = w.model
    let id = try transferRowID(model)
    model.openTransferEditor(forRow: id)
    let editor = try #require(model.transferEditor)
    editor.toAccountID = Self.pln.id
    model.saveTransferEditor()
    #expect(model.transferEditor === editor)
    #expect(editor.errorMessage == "From and To must be different accounts.")
  }

  @Test("another currency on the other side opens Find the other side… inside the popup; a typed amount completes it")
  func otherCurrency() async throws {
    let w = try await world()
    let model = w.model
    let id = try transferRowID(model)
    model.openTransferEditor(forRow: id)
    let editor = try #require(model.transferEditor)
    editor.toAccountID = Self.usd.id
    model.saveTransferEditor()
    let picker = try #require(model.counterpartPicker)
    #expect(picker.accountID == Self.usd.id && picker.model.currencyCode == "USD")
    #expect(picker.model.estimate?.amountText.contains("25") == true)
    #expect(model.transferEditor != nil)
    picker.model.manualText = "26,50"
    model.useManualCounterpart()
    #expect(model.counterpartPicker == nil)
    let refreshed = try #require(model.transferEditor)
    #expect(refreshed.toAccountID == Self.usd.id && !refreshed.hasChanges)
    #expect(refreshed.relations.contains { $0.hasPrefix("Amount on the other account typed by you") && $0.contains("26.50") })
    model.saveTransferEditor()
    #expect(model.transferEditor == nil)
    await model.commit()
    let transfer = try #require(try await w.all().first)
    #expect(transfer.toAccountID == Self.usd.id && transfer.toAmountMinor == 26_50)
  }

  @Test("Change transaction searches the other account on the transfer's day; the sheet's account and window can change")
  func changeTransaction() async throws {
    let w = try await world()
    let sameDay = Txn(
      type: .income, occurredAt: Self.date("2026-03-10"), accountID: Self.savings.id, amountMinor: 100_00, payee: "FROM MAIN",
      source: .pko)
    let otherDay = Txn(
      type: .income, occurredAt: Self.date("2026-03-12"), accountID: Self.savings.id, amountMinor: 100_00, payee: "LATER",
      source: .pko)
    let cashIn = Txn(
      type: .income, occurredAt: Self.date("2026-03-10"), accountID: Self.cash.id, amountMinor: 100_00, payee: "CASH IN",
      source: .manual)
    for txn in [sameDay, otherDay, cashIn] { try await w.txns.save(txn, lines: []) }
    let model = w.model
    let id = try transferRowID(model)
    model.openTransferEditor(forRow: id)
    model.changeTransferTransaction()
    let picker = try #require(model.counterpartPicker)
    #expect(picker.model.fromDay == Day("2026-03-10")! && picker.model.throughDay == Day("2026-03-10")!)
    #expect(picker.accountID == Self.savings.id)
    #expect(picker.model.search.isEmpty)
    await picker.model.load()
    #expect(picker.model.options.map(\.title) == ["FROM MAIN"])

    picker.model.throughDate = Self.date("2026-03-12")
    await picker.model.load()
    #expect(picker.model.options.map(\.title) == ["FROM MAIN", "LATER"])

    picker.model.selectAccount(Self.cash.id)
    #expect(picker.model.title.contains("Cash PLN"))
    picker.model.throughDate = Self.date("2026-03-10")
    await picker.model.load()
    let option = try #require(picker.model.options.first)
    #expect(option.title == "CASH IN" && option.isUsable)
    model.chooseCounterpart(option)
    #expect(model.counterpartPicker == nil)
    let refreshed = try #require(model.transferEditor)
    #expect(refreshed.toAccountID == Self.cash.id)
    #expect(refreshed.relatedTransaction.hasPrefix("“CASH IN” · 10.03.2026"))
    await refreshed.load()
    #expect(refreshed.toLines.contains { $0.badge == "Becomes this transfer" })
    model.cancelTransferEditor()
    await model.commit()
    let all = try await w.all()
    let transfer = try #require(all.first { $0.id == cashIn.id })
    #expect(transfer.type == .transfer && transfer.accountID == Self.pln.id && transfer.toAccountID == Self.cash.id)
    #expect(all.count == 3)
  }

  @Test("an empty search lists every transaction in the window; one moving money the same way cannot be chosen")
  func emptySearchListsAll() async throws {
    let w = try await world()
    let out = Txn(
      type: .expense, occurredAt: Self.date("2026-03-09"), accountID: Self.savings.id, amountMinor: 5_00, payee: "SHOP",
      source: .manual)
    try await w.txns.save(out, lines: [])
    let model = w.model
    let id = try transferRowID(model)
    model.beginCounterpart(forRow: id, to: Self.savings.id)
    let picker = try #require(model.counterpartPicker)
    // C45: the window starts on the transfer's day; SHOP is the day before.
    await picker.model.load()
    #expect(picker.model.options.isEmpty && picker.model.emptyHint?.canWiden == true)
    picker.model.widen()
    await picker.model.load()
    let option = try #require(picker.model.options.first)
    #expect(option.title == "SHOP" && !option.isUsable)
    #expect(option.refusal?.contains("same way") == true)
    model.chooseCounterpart(option)
    #expect(model.counterpartPicker != nil && picker.model.errorMessage?.contains("same way") == true)
    picker.model.search = "nothing like it"
    await picker.model.load()
    #expect(picker.model.options.isEmpty)
    #expect(picker.model.emptyText.contains("matches the search"))
  }
}
