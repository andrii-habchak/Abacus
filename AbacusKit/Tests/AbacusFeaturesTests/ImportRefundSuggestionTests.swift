import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C35: the wizard's refund suggestion on a row: the offer text, Accept, Not a refund, Choose
/// another… (existing expenses and expenses of the file), commit, undo and the bulk bar
/// (synthetic PKO rows).
@MainActor
struct ImportRefundSuggestionTests {
  private static let account = Account(
    id: PreviewData.id(9501), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let groceries = AbacusDomain.Category(id: PreviewData.id(9510), name: "Groceries", kind: .expense)
  private static let travel = AbacusDomain.Category(id: PreviewData.id(9511), name: "Travel", kind: .expense)

  private static let header =
    #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#

  private static func card(_ day: String, _ amount: String, _ merchant: String, ref: String) -> String {
    #""\#(day)","\#(day)","Płatność kartą","\#(amount)","PLN","+100.00","Tytuł:  0000000000000000000000\#(ref) ","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","Data wykonania operacji: \#(day)","Oryginalna kwota operacji: \#(amount.dropFirst())","Numer karty: 000000******0000","""#
  }

  private static func file(_ rows: [String]) -> Data {
    (([header] + rows).joined(separator: "\r\n") + "\r\n").data(using: .windowsCP1250)!
  }

  private static func date(_ day: String) -> Date {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    return ImportHarness.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
  }

  private func harness(expenses: [(String, Int64, String, AbacusDomain.Category)] = []) async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [Self.account])
    try await h.saveCategory(Self.groceries)
    try await h.saveCategory(Self.travel)
    let txns = SQLiteTxnRepository(database: h.database, calendar: ImportHarness.calendar)
    for (day, minor, payee, category) in expenses {
      try await txns.save(
        Txn(
          type: .expense, occurredAt: Self.date(day), accountID: Self.account.id, amountMinor: minor,
          categoryID: category.id, payee: payee, source: .manual), lines: [])
    }
    return h
  }

  private func open(_ h: ImportHarness, _ rows: [String]) async {
    await h.model.open(data: Self.file(rows), fileName: "pko.csv")
    if h.model.needsTargetAccount { await h.model.chooseTargetAccount(Self.account.id) }
  }

  @Test("an incoming row shows the offer, Accept makes it a refund in the expense's category, commit links it, undo removes it")
  func offerAcceptCommitUndo() async throws {
    let h = try await harness(expenses: [("2026-01-05", 45_00, "GROCERY EXAMPLE", Self.travel)])
    await open(h, [Self.card("2026-01-12", "+45.00", "GROCERY EXAMPLE", ref: "1")])
    let model = h.model
    let item = try #require(model.rowItems.first)
    let refund = try #require(item.refund)
    #expect(refund.state == .offered && !refund.isInFile)
    #expect(refund.text.hasPrefix("Looks like a refund of GROCERY EXAMPLE · 05.01.2026 · "))
    #expect(refund.text.contains("45"))
    #expect(item.needsCategory)

    model.acceptRefundOffer(forRow: item.id)
    let accepted = try #require(model.rowItems.first)
    #expect(accepted.refund?.state == .accepted && accepted.refund?.text.hasPrefix("Refund of GROCERY EXAMPLE") == true)
    #expect(accepted.statusLabel == "New refund" && !accepted.needsCategory)
    #expect(accepted.category == .none)
    #expect(model.categoryAssignmentRows.isEmpty)

    await model.commit()
    #expect(model.step == .done)
    #expect(model.summary?.refundsLinked == 1)
    let all = try await h.txns().map(\.txn)
    let imported = try #require(all.first { $0.refundOfID != nil })
    #expect(imported.isRefund && imported.type == .expense && imported.categoryID == Self.travel.id)

    model.requestUndoOfLastImport()
    await model.confirmUndo()
    #expect(try await h.txns().count == 1)
  }

  @Test("Not a refund keeps an ordinary income row, shows Undo, and the offer comes back only after it")
  func declineAndReset() async throws {
    let h = try await harness(expenses: [("2026-01-05", 45_00, "GROCERY EXAMPLE", Self.groceries)])
    await open(h, [Self.card("2026-01-12", "+45.00", "GROCERY EXAMPLE", ref: "1")])
    let model = h.model
    let id = try #require(model.rowItems.first?.id)
    model.declineRefund(forRow: id)
    #expect(model.rowItems.first?.refund?.state == .declined)
    model.setCategory(.existing(Self.travel.id), forRow: id)
    #expect(model.rowItems.first?.refund?.state == .declined)
    #expect(model.preview?.row(id)?.refundOf == nil)
    model.resetRefund(forRow: id)
    #expect(model.rowItems.first?.refund?.state == .offered)
  }

  @Test("Choose another…: the sheet lists existing expenses and expenses of the file; a pick accepts the row")
  func chooseAnother() async throws {
    let h = try await harness(expenses: [("2026-01-05", 80_00, "OTHER SHOP", Self.travel)])
    await open(h, [
      Self.card("2026-01-08", "-60.00", "FILE SHOP", ref: "1"), Self.card("2026-01-12", "+40.00", "UNRELATED", ref: "2"),
    ])
    let model = h.model
    // Nothing is suggested (40.00 matches no description), but "Choose another…" opens the search.
    #expect(model.rowItems.allSatisfy { $0.refund == nil })
    let id = try #require(model.preview?.rows.first { $0.canBeRefund }?.id)
    model.beginRefundPicker(forRow: id)
    let picker = try #require(model.refundPicker)
    await picker.model.load()
    #expect(Set(picker.model.options.map(\.title)) == ["OTHER SHOP", "FILE SHOP"])
    picker.model.search = "file"
    await picker.model.load()
    let option = try #require(picker.model.options.first)
    #expect(picker.model.options.count == 1 && option.title == "FILE SHOP")
    model.chooseRefundOption(option)
    #expect(model.refundPicker == nil)
    let accepted = try #require(model.rowItems.first { $0.id == id })
    #expect(accepted.refund?.state == .accepted && accepted.refund?.isInFile == true)

    // The existing expense can be chosen instead.
    model.beginRefundPicker(forRow: id)
    let again = try #require(model.refundPicker)
    again.model.search = "other"
    await again.model.load()
    model.chooseRefundOption(try #require(again.model.options.first))
    #expect(model.preview?.row(id)?.refundOf?.payee == "OTHER SHOP")
    #expect(model.preview?.row(id)?.category == .existing(Self.travel.id))
  }

  @Test("a purchase and its refund in one file are linked on commit; the bulk bar offers no category for the refund row")
  func sameFile() async throws {
    let h = try await harness()
    await open(h, [
      Self.card("2026-02-01", "-19.99", "TICKETS EXAMPLE", ref: "1"), Self.card("2026-02-03", "+19.99", "TICKETS EXAMPLE", ref: "2"),
    ])
    let model = h.model
    let refundID = try #require(model.rowItems.first { $0.refund?.state == .offered }?.id)
    let purchaseID = try #require(model.rowItems.first { $0.id != refundID }?.id)
    #expect(model.rowItems.first { $0.id == refundID }?.refund?.isInFile == true)
    model.setCategory(.existing(Self.groceries.id), forRow: purchaseID)
    model.acceptRefundOffer(forRow: refundID)
    model.select(refundID, mode: .replace)
    #expect(model.bulk.categoryKinds.isEmpty && model.bulk.selected == 1)
    await model.commit()
    let all = try await h.txns().map(\.txn)
    let imported = try #require(all.first { $0.refundOfID != nil })
    #expect(imported.categoryID == Self.groceries.id && all.count == 2)
    #expect(imported.refundOfID == all.first { $0.refundOfID == nil }?.id)
  }
}
