import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C45: "Find the other side of the transfer" lists every stored transaction of the chosen account
/// in the window (an empty search = all of them), the window starts on the transfer's day, and an
/// empty list offers "Widen to ±5 days" and the other accounts that do have transactions then.
/// Synthetic PKO rows: a PLN statement sends money to an own USD account (found by its number).
@MainActor
struct ImportCounterpartSheetTests {
  private static let opening = Date(timeIntervalSince1970: 1_767_225_600)
  private static let pln = Account(
    id: PreviewData.id(9801), name: "Firma PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: opening, iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let usd = Account(
    id: PreviewData.id(9802), name: "Firma USD", currency: .USD, kind: .bank, openingDate: opening,
    iban: "55 5555 5555 5555 5555 5555 5555")
  private static let cash = Account(id: PreviewData.id(9803), name: "Cash USD", currency: .USD, kind: .cash, openingDate: opening)

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

  /// 400 PLN out to the own USD account.
  private static func toUSD(_ day: String) -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-400.00","PLN","+600.00","Rachunek odbiorcy: 55 5555 5555 5555 5555 5555 5555","Nazwa odbiorcy: JAN PRZYKLAD","Tytuł: WYMIANA","","","""#
  }

  private static func date(_ day: String, hour: Int = 12) -> Date {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    return ImportHarness.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
  }

  private struct World {
    let database: any DatabaseWriter
    let model: ImportWizardModel
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: ImportHarness.calendar) }
    func save(_ txn: Txn) async throws { try await txns.save(txn, lines: []) }
  }

  private func world(stored: [Txn], rows: [String] = [toUSD("2026-03-10")]) async throws -> World {
    let database = try AbacusDatabase.open(at: nil)
    let repository = SQLiteAccountRepository(database: database, calendar: ImportHarness.calendar)
    for account in [Self.pln, Self.usd, Self.cash] { try await repository.save(account) }
    let w = World(database: database, model: ImportWizardModel(
      dependencies: .live(
        database: database, calendar: ImportHarness.calendar, now: { ImportHarness.now }, converter: { Rates() })))
    for txn in stored { try await w.save(txn) }
    await w.model.load()
    await w.model.open(data: Self.file(rows), fileName: "pko.csv")
    if w.model.needsTargetAccount { await w.model.chooseTargetAccount(Self.pln.id) }
    return w
  }

  private func rowID(_ model: ImportWizardModel) throws -> String {
    try #require(model.rowItems.first?.id)
  }

  private static func txn(
    _ type: TxnType, _ day: String, hour: Int = 12, account: Account, to: Account? = nil, _ minor: Int64, _ payee: String
  ) -> Txn {
    Txn(
      type: type, occurredAt: date(day, hour: hour), accountID: account.id, amountMinor: minor, toAccountID: to?.id,
      toAmountMinor: to == nil ? nil : minor, payee: payee, source: .manual)
  }

  @Test("with an empty search the sheet lists every stored transaction of the account on the transfer's day")
  func sameDayListsAllStored() async throws {
    let w = try await world(stored: [
      Self.txn(.income, "2026-03-10", hour: 1, account: Self.usd, 99_50, "FX IN"),
      Self.txn(.expense, "2026-03-10", hour: 23, account: Self.usd, 3_00, "CARD FEE"),
      Self.txn(.transfer, "2026-03-10", account: Self.cash, to: Self.usd, 20_00, "FROM CASH"),
      Self.txn(.income, "2026-03-11", account: Self.usd, 100_00, "NEXT DAY"),
    ])
    let model = w.model
    let id = try rowID(model)
    #expect(model.needsCounterpart(forRow: id, to: Self.usd.id))
    model.beginCounterpart(forRow: id, to: Self.usd.id)
    let picker = try #require(model.counterpartPicker).model
    // The window is the transfer's day; the user widens it with the date pickers.
    #expect(picker.fromDay == Day("2026-03-10")! && picker.throughDay == Day("2026-03-10")!)
    #expect(picker.search.isEmpty)
    await picker.load()
    #expect(Set(picker.options.map(\.title)) == ["FX IN", "CARD FEE", "FROM CASH"])
    #expect(picker.options.first?.title == "FX IN" && picker.options.first?.isUsable == true)
    #expect(picker.emptyHint == nil)
  }

  @Test("a transaction another row of this import already takes over stays listed, greyed with the reason")
  func takenStaysListed() async throws {
    let w = try await world(
      stored: [Self.txn(.income, "2026-03-10", account: Self.usd, 100_00, "FX IN")],
      rows: [Self.toUSD("2026-03-10"), Self.toUSD("2026-03-10").replacingOccurrences(of: "WYMIANA", with: "WYMIANA 2")])
    let model = w.model
    let ids = model.rowItems.map(\.id)
    try #require(ids.count == 2)
    model.beginCounterpart(forRow: ids[0], to: Self.usd.id)
    let first = try #require(model.counterpartPicker).model
    await first.load()
    model.chooseCounterpart(try #require(first.options.first))
    #expect(model.counterpartPicker == nil)
    // The second row's sheet still shows it, not usable, with the reason.
    model.beginCounterpart(forRow: ids[1], to: Self.usd.id)
    let second = try #require(model.counterpartPicker).model
    await second.load()
    let option = try #require(second.options.first)
    #expect(second.options.count == 1 && option.title == "FX IN" && !option.isUsable)
    #expect(option.refusal == "Another row of this import already uses it.")
    // The first row's own sheet ("Change…") keeps offering it.
    model.cancelCounterpart()
    model.beginCounterpart(forRow: ids[0], to: Self.usd.id)
    let again = try #require(model.counterpartPicker).model
    await again.load()
    #expect(again.options.first?.title == "FX IN" && again.options.first?.isUsable == true)
  }

  @Test("an empty day offers Widen to ±5 days and the accounts that have transactions that day")
  func emptyDayHints() async throws {
    let w = try await world(stored: [
      Self.txn(.income, "2026-03-13", account: Self.usd, 100_00, "THREE DAYS LATER"),
      Self.txn(.income, "2026-03-10", account: Self.cash, 50_00, "CASH SAME DAY"),
    ])
    let model = w.model
    let id = try rowID(model)
    model.beginCounterpart(forRow: id, to: Self.usd.id)
    let picker = try #require(model.counterpartPicker).model
    await picker.load()
    #expect(picker.options.isEmpty)
    #expect(picker.emptyText == "No transactions on “Firma USD” on 10 Mar 2026.")
    let hint = try #require(picker.emptyHint)
    #expect(hint.canWiden)
    #expect(hint.otherAccounts.map(\.name) == ["Cash USD"])
    #expect(hint.otherAccounts.first?.count == 1)

    picker.widen()
    #expect(picker.fromDay == Day("2026-03-05")! && picker.throughDay == Day("2026-03-15")!)
    await picker.load()
    #expect(picker.options.map(\.title) == ["THREE DAYS LATER"])

    picker.selectAccount(Self.cash.id)
    await picker.load()
    #expect(picker.options.map(\.title) == ["CASH SAME DAY"])
  }
}
