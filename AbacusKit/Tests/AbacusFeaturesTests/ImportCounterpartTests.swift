import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C38: the wizard's "Find the other side…" sheet and the offers to complete an estimated transfer
/// (synthetic PKO rows: a USD account sends to a PLN account of the same owner), and the
/// "estimated amount" text of the Transactions list.
@MainActor
struct ImportCounterpartTests {
  private static let pln = Account(
    id: PreviewData.id(9601), name: "PKO PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let usd = Account(
    id: PreviewData.id(9602), name: "PKO USD", currency: .USD, kind: .bank, openingBalanceMinor: 500_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "55 5555 5555 5555 5555 5555 5555")

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

  private static func usdOut(_ day: String, _ amount: String, ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-\#(amount)","USD","+500.00","Rachunek odbiorcy: 99 9999 9999 9999 9999 9999 9999","Nazwa odbiorcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
  }

  private static func plnIn(_ day: String, _ amount: String, ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 55 5555 5555 5555 5555 5555 5555","Nazwa nadawcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
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

  private func world(rates: Bool = true) async throws -> World {
    let database = try AbacusDatabase.open(at: nil)
    let repository = SQLiteAccountRepository(database: database, calendar: ImportHarness.calendar)
    try await repository.save(Self.pln)
    try await repository.save(Self.usd)
    let converter: @Sendable () async -> (any CurrencyConverter)? = { rates ? Rates() : nil }
    let model = ImportWizardModel(
      dependencies: .live(
        database: database, calendar: ImportHarness.calendar, now: { ImportHarness.now }, converter: converter))
    await model.load()
    return World(database: database, model: model)
  }

  private func open(_ w: World, _ rows: [String], into account: Account) async {
    await w.model.open(data: Self.file(rows), fileName: "pko.csv")
    if w.model.needsTargetAccount { await w.model.chooseTargetAccount(account.id) }
  }

  private func income(_ w: World, _ day: String, _ minor: Int64, _ payee: String) async throws -> Txn {
    let txn = Txn(
      type: .income, occurredAt: Self.date(day), accountID: Self.pln.id, amountMinor: minor, payee: payee, source: .pko)
    try await w.txns.save(txn, lines: [])
    return txn
  }

  // MARK: Transfer to my account

  @Test("picking Transfer to my account for an unknown amount opens the sheet; a found transaction becomes the transfer and undo restores it")
  func findTheOtherSide() async throws {
    let w = try await world()
    let found = try await income(w, "2026-03-11", 398_00, "Wlasny przelew")
    await open(w, [Self.usdOut("2026-03-10", "100.00")], into: Self.usd)
    let model = w.model
    let review = try #require(model.reviewItems.first)
    #expect(review.selected == nil)

    model.selectReviewOption(.transfer, forRow: review.id)
    let picker = try #require(model.counterpartPicker)
    #expect(picker.accountID == Self.pln.id && picker.rowID == review.id)
    #expect(model.reviewItems.first?.selected == nil)
    #expect(picker.model.title.contains("PKO PLN"))
    #expect(picker.model.subtitle.contains("JAN PRZYKLAD") && picker.model.subtitle.contains("10.03.2026"))
    #expect(picker.model.estimate?.rateText == "1 USD = 4.00 PLN")

    await picker.model.load()
    let option = try #require(picker.model.options.first)
    #expect(option.id == found.id && option.title == "Wlasny przelew")
    #expect(option.amountText.contains("398"))
    #expect(option.subtitle.contains("1 day away") && option.subtitle.contains("Income"))
    #expect(option.detail.hasPrefix("Rate 3.98"))
    #expect(option.isUsable)

    model.chooseCounterpart(option)
    #expect(model.counterpartPicker == nil)
    let chosen = try #require(model.reviewItems.first)
    #expect(chosen.selected == .transfer)
    #expect(chosen.counterpart?.text.hasPrefix("Other side: Wlasny przelew · 11.03.2026") == true)
    #expect(chosen.counterpart?.text.contains("becomes this transfer") == true)
    let rowItem = try #require(model.rowItems.first)
    #expect(rowItem.counterpart?.accountID == Self.pln.id)
    #expect(model.canCommit)

    await model.commit()
    #expect(model.step == .done)
    let all = try await w.all()
    #expect(all.count == 1)
    let transfer = try #require(all.first)
    #expect(transfer.id == found.id && transfer.type == .transfer)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 398_00)
    #expect(transfer.accountID == Self.usd.id && transfer.toAccountID == Self.pln.id)

    model.requestUndoOfLastImport()
    await model.confirmUndo()
    let restored = try #require(try await w.all().first)
    #expect(restored.id == found.id && restored.type == .income && restored.accountID == Self.pln.id)
    #expect(restored.amountMinor == 398_00)
  }

  @Test("a refused candidate is shown with its reason and cannot be chosen")
  func refusedCandidate() async throws {
    let w = try await world()
    let found = try await income(w, "2026-03-11", 398_00, "Has a fee")
    try await w.txns.save(found, lines: [AttachedRecord(txnID: found.id, kind: .expense, amountMinor: 1_00)])
    await open(w, [Self.usdOut("2026-03-10", "100.00")], into: Self.usd)
    let model = w.model
    model.selectReviewOption(.transfer, forRow: try #require(model.reviewItems.first).id)
    let picker = try #require(model.counterpartPicker)
    await picker.model.load()
    let option = try #require(picker.model.options.first)
    #expect(!option.isUsable)
    #expect(option.refusal?.contains("attached records") == true)
    model.chooseCounterpart(option)
    #expect(model.counterpartPicker != nil)
    #expect(picker.model.errorMessage?.contains("attached records") == true)
    #expect(model.reviewItems.first?.selected == nil)
  }

  @Test("a typed amount is parsed (comma or dot), checked, and makes a transfer that is not flagged")
  func typedAmount() async throws {
    let w = try await world()
    await open(w, [Self.usdOut("2026-03-10", "100.00")], into: Self.usd)
    let model = w.model
    model.selectReviewOption(.transfer, forRow: try #require(model.reviewItems.first).id)
    let picker = try #require(model.counterpartPicker)

    picker.model.manualText = ""
    model.useManualCounterpart()
    #expect(model.counterpartPicker != nil && picker.model.errorMessage?.contains("PLN") == true)
    picker.model.manualText = "-5"
    #expect(picker.model.manualAmountMinor == nil)
    picker.model.manualText = "abc"
    #expect(picker.model.manualAmountMinor == nil)
    picker.model.manualText = " 397,50 "
    #expect(picker.model.manualAmountMinor == 397_50)
    model.useManualCounterpart()
    #expect(model.counterpartPicker == nil)
    #expect(model.reviewItems.first?.counterpart?.text.hasPrefix("Other side typed by you:") == true)

    await model.commit()
    let transfer = try #require(try await w.all().first)
    #expect(transfer.toAmountMinor == 397_50 && !transfer.isEstimatedTransferAmount)
  }

  @Test("the estimate fills the amount at the rate, flags the transfer; without a rate it is not offered")
  func estimate() async throws {
    let w = try await world()
    await open(w, [Self.usdOut("2026-03-10", "100.00")], into: Self.usd)
    let model = w.model
    model.selectReviewOption(.transfer, forRow: try #require(model.reviewItems.first).id)
    let picker = try #require(model.counterpartPicker)
    #expect(picker.model.estimate?.amountMinor == 400_00)
    model.useEstimatedCounterpart()
    #expect(model.counterpartPicker == nil)
    #expect(model.reviewItems.first?.counterpart?.text.hasPrefix("Estimated other side:") == true)
    await model.commit()
    let transfer = try #require(try await w.all().first)
    #expect(transfer.toAmountMinor == 400_00 && transfer.isEstimatedTransferAmount)

    let bare = try await world(rates: false)
    await open(bare, [Self.usdOut("2026-03-10", "100.00")], into: Self.usd)
    bare.model.selectReviewOption(.transfer, forRow: try #require(bare.model.reviewItems.first).id)
    #expect(bare.model.counterpartPicker?.model.estimate == nil)
    bare.model.useEstimatedCounterpart()
    #expect(bare.model.counterpartPicker != nil)
    #expect(bare.model.reviewItems.first?.selected == nil)
  }

  @Test("the bulk Account action opens the sheet for one selected row and explains for several")
  func bulkAccount() async throws {
    let w = try await world()
    await open(w, [Self.usdOut("2026-03-10", "100.00", ref: "1"), Self.usdOut("2026-03-12", "50.00", ref: "2")], into: Self.usd)
    let model = w.model
    model.tab = .transactions
    let ids = model.rowItems.map(\.id)
    model.select(ids[0], mode: .replace)
    model.bulkSetTransfer(to: Self.pln.id)
    #expect(model.counterpartPicker?.rowID == ids[0])
    model.cancelCounterpart()
    #expect(model.counterpartPicker == nil)

    model.select(ids[0], mode: .replace)
    model.select(ids[1], mode: .toggle)
    model.bulkSetTransfer(to: Self.pln.id)
    #expect(model.counterpartPicker == nil)
    #expect(model.bulkMessage?.contains("Select one row") == true)
  }

  // MARK: A later import completes an estimated transfer

  private func estimatedTransfer(_ w: World) async throws -> Txn {
    let transfer = Txn(
      type: .transfer, occurredAt: Self.date("2026-03-10"), accountID: Self.usd.id, amountMinor: 100_00,
      toAccountID: Self.pln.id, toAmountMinor: 400_00, payee: "JAN PRZYKLAD", source: .pko, isEstimatedTransferAmount: true)
    try await w.txns.save(transfer, lines: [])
    return transfer
  }

  @Test("the offer reads 'Looks like the other side of the transfer on …'; Accept links the row, commit completes the transfer, undo restores the estimate")
  func offerAcceptCommitUndo() async throws {
    let w = try await world()
    let transfer = try await estimatedTransfer(w)
    await open(w, [Self.plnIn("2026-03-12", "402.50")], into: Self.pln)
    let model = w.model
    let offered = try #require(model.rowItems.first?.estimate)
    #expect(offered.state == .offered)
    #expect(offered.text.hasPrefix("Looks like the other side of the transfer on 10.03.2026 · "))
    #expect(offered.text.contains("400") && offered.text.contains("estimated"))
    #expect(model.reviewItems.first?.estimate?.state == .offered)

    model.acceptEstimateOffer(forRow: try #require(model.rowItems.first).id)
    let item = try #require(model.rowItems.first)
    #expect(item.estimate?.state == .accepted && item.statusLabel == "Completes transfer" && !item.isDimmed)
    #expect(item.note?.text == "Linked to the estimated transfer")
    #expect(model.canCommit)
    #expect(model.reviewItems.isEmpty)

    await model.commit()
    #expect(model.summary?.estimatesCompleted == 1)
    let done = try #require(try await w.all().first)
    #expect(done.id == transfer.id && done.toAmountMinor == 402_50 && !done.isEstimatedTransferAmount)

    model.requestUndoOfLastImport()
    await model.confirmUndo()
    let restored = try #require(try await w.all().first)
    #expect(restored.toAmountMinor == 400_00 && restored.isEstimatedTransferAmount)
  }

  @Test("Not this clears the offer, Undo brings it back")
  func notThis() async throws {
    let w = try await world()
    _ = try await estimatedTransfer(w)
    await open(w, [Self.plnIn("2026-03-12", "402.50")], into: Self.pln)
    let model = w.model
    let id = try #require(model.rowItems.first).id
    model.declineEstimate(forRow: id)
    #expect(model.rowItems.first?.estimate?.state == .declined)
    model.resetEstimate(forRow: id)
    #expect(model.rowItems.first?.estimate?.state == .offered)
  }

  // MARK: The list

  @Test("a transfer with an estimated amount shows 'estimated amount' as its secondary text; others do not")
  func listText() {
    let reference = TransactionsReference(accounts: [Self.pln, Self.usd], categories: [], events: [])
    func text(_ estimated: Bool, to destination: Account = Self.pln) -> String? {
      let txn = Txn(
        type: .transfer, occurredAt: Self.date("2026-03-10"), accountID: Self.usd.id, amountMinor: 100_00,
        toAccountID: destination.id, toAmountMinor: 400_00, payee: "Own", isEstimatedTransferAmount: estimated)
      let list = TransactionListContent(
        rows: [TxnWithLines(txn: txn, lines: [])], reference: reference, displayCurrency: .PLN, converter: Rates(),
        today: Day("2026-03-12")!)
      return list.days.first?.rows.first?.amountDetail
    }
    let estimated = text(true)
    #expect(estimated?.hasSuffix(" · estimated amount") == true)
    #expect(estimated?.hasPrefix("→ ") == true && estimated?.contains("400") == true)
    let plain = text(false)
    #expect(plain?.contains("400") == true && plain?.contains("estimated") == false)
  }
}
