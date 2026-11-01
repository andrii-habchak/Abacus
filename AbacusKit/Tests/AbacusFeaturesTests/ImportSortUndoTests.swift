import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

private let opening = Date(timeIntervalSince1970: 1_767_225_600)
private let personal = Account(
  id: PreviewData.id(9101), name: "Bank PLN", currency: .PLN, kind: .bank, openingDate: opening)
private let business = Account(
  id: PreviewData.id(9102), name: "Business PLN", currency: .PLN, kind: .bank, openingDate: opening)

/// C41: column sorting of the review rows, undo from the confirmation dialog, and the checks of
/// the PKO "Import into" account.
@MainActor
@Suite("Import review sorting, undo and target account (C41)")
struct ImportSortUndoTests {
  private func reviewAllTypes() async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [personal])
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(personal.id)
    #expect(h.model.preview != nil)
    return h
  }

  // MARK: Sorting

  @Test("Header click sorts ascending, then descending, then back to the file's order")
  func sortCycle() async throws {
    let h = try await reviewAllTypes()
    let model = h.model
    let fileOrder = model.visibleRows.map(\.id)
    #expect(model.rowSort == nil)

    model.toggleSort(.amount)
    #expect(model.sortDirection(of: .amount) == true)
    #expect(model.sortDirection(of: .date) == nil)
    let amounts = model.visibleRows.map { signed(model, $0.id) }
    #expect(amounts == amounts.sorted())
    #expect(amounts.first! < 0 && amounts.last! > 0)

    model.toggleSort(.amount)
    #expect(model.sortDirection(of: .amount) == false)
    let descending = model.visibleRows.map { signed(model, $0.id) }
    #expect(descending == amounts.sorted(by: >))

    model.toggleSort(.amount)
    #expect(model.rowSort == nil)
    #expect(model.visibleRows.map(\.id) == fileOrder)
  }

  @Test("Date and text columns sort by value; equal keys keep the file's order; another column starts ascending")
  func sortColumns() async throws {
    let h = try await reviewAllTypes()
    let model = h.model
    let fileOrder = model.visibleRows.map(\.id)

    model.toggleSort(.date)
    let days = model.visibleRows.map { model.preview!.row($0.id)!.day }
    #expect(days == days.sorted())
    // Same day: the file's order.
    for (a, b) in zip(model.visibleRows, model.visibleRows.dropFirst())
    where model.preview!.row(a.id)!.day == model.preview!.row(b.id)!.day {
      #expect(fileOrder.firstIndex(of: a.id)! < fileOrder.firstIndex(of: b.id)!)
    }
    model.toggleSort(.date)
    let daysDown = model.visibleRows.map { model.preview!.row($0.id)!.day }
    #expect(daysDown == days.sorted(by: >))

    model.toggleSort(.description)
    #expect(model.sortDirection(of: .description) == true)
    let payees = model.visibleRows.map(\.payee)
    #expect(payees == payees.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

    model.toggleSort(.status)
    let statuses = model.visibleRows.map { RowStatus.allCases.firstIndex(of: $0.status)! }
    #expect(statuses == statuses.sorted())

    model.toggleSort(.category)
    #expect(model.visibleRows.count == fileOrder.count)
    model.toggleSort(.account)
    #expect(Set(model.visibleRows.map(\.id)) == Set(fileOrder))
  }

  @Test("Selection stays across a sort; Shift ranges over the sorted order")
  func selectionFollowsSort() async throws {
    let h = try await reviewAllTypes()
    let model = h.model
    let first = model.visibleRows[0].id
    model.select(first, mode: .replace)

    model.toggleSort(.amount)
    #expect(model.selection == [first])
    let sorted = model.visibleRows.map(\.id)
    model.select(sorted[1], mode: .replace)
    model.select(sorted[3], mode: .range)
    #expect(model.selection == Set(sorted[1...3]))
    #expect(model.selectableIDs == sorted)
  }

  @Test("A card filter and a sort combine")
  func sortWithinFilter() async throws {
    let h = try await reviewAllTypes()
    let model = h.model
    model.selectFilter(.new)
    model.toggleSort(.amount)
    #expect(model.visibleRows.allSatisfy { $0.status == .new })
    let amounts = model.visibleRows.map { signed(model, $0.id) }
    #expect(amounts == amounts.sorted())
  }

  private func signed(_ model: ImportWizardModel, _ id: String) -> Int64 {
    let row = model.preview!.row(id)!
    return row.isInflow ? row.amountMinor : -row.amountMinor
  }

  // MARK: Undo

  @Test("Undo Import works when the dialog clears the pending batch before the task runs")
  func undoSurvivesDialogDismissal() async throws {
    let h = try await ImportHarness.empty(accounts: [personal])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(personal.id)
    await h.model.commit()
    let imported = try await h.txns().count
    #expect(imported > 0)
    h.model.cancel()

    let item = try #require(h.model.historyItems.first)
    #expect(h.model.batchCounts[item.id] == imported)
    h.model.requestUndo(item.batch)
    #expect(h.model.undoConfirmationMessage.hasPrefix("\(imported) transaction"))
    // What the dialog does: the button's action, then the dismissal (`cancelUndo`).
    let task = h.model.startConfirmedUndo()
    h.model.cancelUndo()
    await task?.value

    #expect(try await h.txns().isEmpty)
    #expect(h.model.historyItems.first?.isUndone == true)
    #expect(h.model.undoNotice == "The import of “settled-later.csv” was undone: \(imported) transaction\(imported == 1 ? "" : "s") removed.")
  }

  @Test("Undo of a batch without transactions of its own says so")
  func undoEmptyBatch() async throws {
    let h = try await ImportHarness.empty(accounts: [personal])
    let batch = ImportBatch(source: .pko, fileName: "statement.csv", importedAt: ImportHarness.now, accountID: personal.id)
    try await SQLiteImportStore(database: h.database, calendar: ImportHarness.calendar).commit(ImportCommit(batch: batch))
    await h.model.load()
    #expect(h.model.batchCounts[batch.id] == 0)

    h.model.requestUndo(try #require(h.model.history.first))
    #expect(h.model.undoConfirmationMessage.hasPrefix("This import has no transactions of its own"))
    await h.model.startConfirmedUndo()?.value
    #expect(h.model.historyItems.first?.isUndone == true)
    #expect(h.model.undoNotice?.contains("had no transactions of its own to remove") == true)
  }

  // MARK: Target account

  @Test("Two accounts in the file's currency: the remembered one is flagged as a guess")
  func ambiguousRememberedTarget() async throws {
    let h = try await ImportHarness.empty(accounts: [personal, business])
    try await h.open("pko", "settled-later")
    #expect(h.model.needsTargetAccount)
    #expect(h.model.targetWarning == nil)
    await h.model.chooseTargetAccount(personal.id)
    #expect(h.model.targetWarning == nil)  // chosen just now
    await h.model.commit()
    h.model.cancel()

    try await h.open("pko", "settled-later")
    #expect(h.model.targetRemembered)
    #expect(h.model.targetAccountID == personal.id)
    // Its rows are in the remembered account itself: only the ambiguity is mentioned.
    #expect(h.model.targetWarning?.hasPrefix("2 accounts are in PLN.") == true)
  }

  @Test("One account in the currency: no warning")
  func singleAccountNoWarning() async throws {
    let h = try await ImportHarness.empty(accounts: [personal])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(personal.id)
    await h.model.commit()
    h.model.cancel()
    try await h.open("pko", "settled-later")
    #expect(h.model.targetRemembered)
    #expect(h.model.targetWarning == nil)
  }

  @Test("Changing Import into after the file was imported elsewhere warns; undo from History clears it")
  func importedElsewhereThenUndo() async throws {
    let h = try await ImportHarness.empty(accounts: [personal, business])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(personal.id)
    await h.model.commit()
    let imported = try await h.txns().count
    h.model.cancel()

    // The same file again, now meant for the business account.
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(business.id)
    #expect(h.model.targetOverlaps[personal.id] == imported)
    #expect(
      h.model.targetWarning
        == "\(imported) rows of this file are already imported into “Bank PLN”. Undo that import in History first, or they will be in both accounts.")
    #expect(h.model.preview?.counts.new == imported)

    // Undo the first import from History while the file is still under review.
    let batch = try #require(h.model.history.first { $0.accountID == personal.id })
    h.model.requestUndo(batch)
    await h.model.startConfirmedUndo()?.value
    #expect(h.model.step == .review)
    #expect(h.model.targetAccountID == business.id)
    #expect(h.model.targetOverlaps.isEmpty)
    #expect(h.model.targetWarning == nil)
    await h.model.commit()
    let txns = try await h.txns()
    #expect(txns.count == imported)
    #expect(txns.allSatisfy { $0.txn.accountID == business.id })
  }

  @Test("Undoing the batch of the file's own target rebuilds the review: its rows are new again")
  func undoRebuildsReview() async throws {
    let h = try await ImportHarness.empty(accounts: [personal])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(personal.id)
    await h.model.commit()
    h.model.cancel()
    try await h.open("pko", "settled-later")
    #expect(h.model.preview?.counts.new == 0)
    #expect(!h.model.canCommit)

    h.model.requestUndo(try #require(h.model.history.first))
    await h.model.startConfirmedUndo()?.value
    #expect(h.model.step == .review)
    #expect(h.model.preview?.counts.alreadyImported == 0)
    #expect(h.model.canCommit)
  }

  @Test("Pipeline: rows already imported per account, read-only")
  func alreadyImportedRowsPerAccount() async throws {
    let h = try await ImportHarness.empty(accounts: [personal, business])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(personal.id)
    await h.model.commit()
    let data = try ImportHarness.fixture("pko", "settled-later")
    let pipeline = ImportWizardDependencies.live(database: h.database, calendar: ImportHarness.calendar).pipeline
    let found = try await pipeline.alreadyImportedRows(of: data, in: [personal.id, business.id])
    #expect(Array(found.keys) == [personal.id])
    #expect(try await pipeline.alreadyImportedRows(of: Data("x".utf8), in: [personal.id]).isEmpty)
  }
}
