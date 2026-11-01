import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

private let opening = Date(timeIntervalSince1970: 1_767_225_600)
private let personal = Account(
  id: PreviewData.id(9201), name: "Bank PLN", currency: .PLN, kind: .bank, openingDate: opening)
private let business = Account(
  id: PreviewData.id(9202), name: "Business PLN", currency: .PLN, kind: .bank, openingDate: opening)
private let dollars = Account(
  id: PreviewData.id(9203), name: "Bank USD", currency: .USD, kind: .bank, openingDate: opening)
private let archived = Account(
  id: PreviewData.id(9204), name: "Old PLN", currency: .PLN, kind: .bank, openingDate: opening, isArchived: true)

/// C44: History → "Move to another account…" of an import batch, and the History buttons.
@MainActor
@Suite("Move an import batch to another account (C44)")
struct ImportMoveTests {
  /// `all-types` imported into the personal account (suggestions accepted), back on step 1.
  private func imported(accounts: [Account] = [personal, business, dollars, archived]) async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: accounts)
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(personal.id)
    h.model.acceptSuggestions()
    await h.model.commit()
    #expect(h.model.step == .done)
    h.model.cancel()
    return h
  }

  private func store(_ h: ImportHarness) -> SQLiteImportStore {
    SQLiteImportStore(database: h.database, calendar: ImportHarness.calendar)
  }

  private func fingerprints(_ h: ImportHarness) async throws -> [ImportFingerprint] {
    try await h.database.read { db in try ImportFingerprint.all.fetchAll(db) }
  }

  private func balance(_ h: ImportHarness, _ id: Account.ID) async throws -> Int64 {
    let txns = try await h.txns().map(\.txn)
    return txns.reduce(Int64(0)) { sum, txn in
      switch txn.type {
      case .expense: return txn.accountID == id ? sum + (txn.isRefund ? txn.amountMinor : -txn.amountMinor) : sum
      case .income: return txn.accountID == id ? sum + (txn.isRefund ? -txn.amountMinor : txn.amountMinor) : sum
      case .transfer:
        var s = sum
        if txn.accountID == id { s -= txn.amountMinor }
        if txn.toAccountID == id { s += txn.toAmountMinor ?? txn.amountMinor }
        return s
      }
    }
  }

  @Test("The list shows the batch's rows, all movable ones selected; targets are active accounts in its currency")
  func listAndTargets() async throws {
    let h = try await imported()
    let batch = try #require(h.model.history.first)
    #expect(h.model.canMove(batch))
    await h.model.requestMove(batch)
    let sheet = try #require(h.model.moveSheet)
    let own = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    #expect(sheet.plan.candidates.count == own.count)
    #expect(sheet.selection.count == own.count)
    #expect(sheet.visibleRows.allSatisfy { $0.statusLabel == "Moves" })
    // Same currency, active, not the source: the business account and the ATM's cash account.
    let targets = Set(sheet.targetItems.map(\.id))
    #expect(targets.contains(business.id))
    #expect(!targets.contains(personal.id))
    #expect(!targets.contains(dollars.id))
    #expect(!targets.contains(archived.id))
    #expect(!sheet.canMove)  // no target yet
    #expect(sheet.summaryLines == ["Choose the account these transactions belong to."])

    sheet.targetAccountID = business.id
    #expect(sheet.canMove)
    #expect(sheet.moveButtonTitle == "Move \(own.count) transactions")
    #expect(sheet.visibleRows.allSatisfy { $0.account.hasSuffix("→ Business PLN") })
    // The ATM withdrawal is a transfer to cash: only the bank side moves.
    let atm = try #require(sheet.visibleRows.first { $0.detail.hasPrefix("Transfer to") })
    #expect(atm.note?.text.contains("side moves") == true)
  }

  @Test("Moving keeps edits, re-keys fingerprints, moves the batch and memory; a re-import is detected in the new account")
  func moveAndReimport() async throws {
    let h = try await imported()
    let batch = try #require(h.model.history.first)
    let before = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    let personalBefore = try await balance(h, personal.id)
    // A user edit after the import.
    let edited = try #require(before.first { $0.txn.type == .expense })
    try await h.database.write { db in
      try Txn.find(edited.txn.id).update { $0.note = #bind("edited later") }.execute(db)
    }

    await h.model.requestMove(batch)
    let sheet = try #require(h.model.moveSheet)
    sheet.targetAccountID = business.id
    await h.model.startMove()?.value
    #expect(h.model.moveSheet == nil)
    #expect(h.model.moveNotice == "\(before.count) transactions of “all-types.csv” moved from “Bank PLN” to “Business PLN”.")

    let after = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    #expect(after.count == before.count)
    #expect(after.allSatisfy { $0.txn.accountID == business.id || $0.txn.toAccountID == business.id })
    #expect(after.allSatisfy { $0.txn.accountID != personal.id && $0.txn.toAccountID != personal.id })
    #expect(after.first { $0.txn.id == edited.txn.id }?.txn.note == "edited later")
    #expect(try await balance(h, business.id) == personalBefore)
    #expect(try await balance(h, personal.id) == 0)
    let keys = try await fingerprints(h).filter { $0.batchID == batch.id }
    #expect(!keys.isEmpty)
    #expect(keys.allSatisfy { $0.id.hasPrefix(ImportFingerprint.movedPrefix) })
    #expect(h.model.history.first?.accountID == business.id)
    // The remembered account of PLN statements follows the latest statement.
    let mapping = try await store(h).mappings(source: .pko).first { $0.externalKey == "statement|PLN" }
    #expect(mapping?.targetID == business.id)

    // The same file again into the business account: everything is already imported.
    try await h.open("pko", "all-types")
    #expect(h.model.targetAccountID == business.id)
    #expect(h.model.preview?.counts.new == 0)
    #expect(h.model.targetWarning?.contains("Bank PLN") != true)
    // Into the personal account: new again, with the warning that the rows are in the business account.
    await h.model.chooseTargetAccount(personal.id)
    #expect((h.model.preview?.counts.new ?? 0) > 0)
    #expect(h.model.targetOverlaps[business.id] != nil)
    #expect(h.model.targetWarning?.contains("already imported into “Business PLN”") == true)
  }

  @Test("Undo move puts the rows back; Undo import after a move removes the moved rows")
  func undoMoveAndUndoImport() async throws {
    let h = try await imported()
    let batch = try #require(h.model.history.first)
    let count = try await h.txns().filter { $0.txn.importBatchID == batch.id }.count
    await h.model.requestMove(batch)
    h.model.moveSheet?.targetAccountID = business.id
    await h.model.startMove()?.value
    #expect(h.model.lastMove != nil)

    // What the alert does: the button's action, then the dismissal clears the notice.
    let task = h.model.startUndoLastMove()
    h.model.moveNotice = nil
    await task?.value
    #expect(h.model.lastMove == nil)
    #expect(h.model.moveNotice?.hasPrefix("The move of “all-types.csv” was undone") == true)
    var txns = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    #expect(txns.allSatisfy { $0.txn.accountID == personal.id || $0.txn.toAccountID == personal.id })
    #expect(h.model.history.first?.accountID == personal.id)
    // Moved back: the re-import into the personal account still finds them.
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(personal.id)
    #expect(h.model.preview?.counts.new == 0)
    h.model.cancel()

    // Move again, then undo the import: the moved rows go with it.
    await h.model.requestMove(try #require(h.model.history.first))
    h.model.moveSheet?.targetAccountID = business.id
    await h.model.startMove()?.value
    txns = try await h.txns().filter { $0.txn.importBatchID == batch.id }
    #expect(txns.count == count)
    h.model.requestUndo(try #require(h.model.history.first))
    await h.model.startConfirmedUndo()?.value
    #expect(try await h.txns().filter { $0.txn.importBatchID == batch.id }.isEmpty)
    #expect(try await fingerprints(h).filter { $0.batchID == batch.id }.isEmpty)
    let undone = try #require(h.model.history.first)
    #expect(undone.isUndone)
    #expect(!h.model.canMove(undone))
    #expect(h.model.moveUnavailableReason(undone) == "This import is undone.")
  }

  @Test("Rows touched by a later import can't move; a partial move keeps the batch on its account")
  func refusalsAndPartialMove() async throws {
    let h = try await imported()
    let first = try #require(h.model.history.first)
    // A later statement settles the batch's pending payment.
    try await h.open("pko", "settled-later")
    await h.model.commit()
    h.model.cancel()

    await h.model.requestMove(try #require(h.model.history.first { $0.id == first.id }))
    let sheet = try #require(h.model.moveSheet)
    let refused = sheet.plan.candidates.filter { $0.refusal != nil }
    #expect(refused.count == 1)
    guard case .laterImport(let file) = refused.first?.refusal else {
      Issue.record("Expected a later-import refusal, got \(String(describing: refused.first?.refusal))")
      return
    }
    #expect(file == "settled-later.csv")
    let refusedID = try #require(refused.first?.id.uuidString)
    #expect(!sheet.selection.contains(refusedID))
    #expect(sheet.visibleRows.first { $0.id == refusedID }?.statusLabel == "Can't move")
    sheet.select(refusedID, mode: .toggle)
    #expect(!sheet.selection.contains(refusedID))

    // The store refuses the whole move when a refused row is included (all or nothing).
    let all = sheet.plan.candidates.map(\.id)
    await #expect(throws: ImportMoveError.refused(count: 1)) {
      try await self.store(h).move(first.id, txnIDs: all, to: business.id)
    }
    #expect(try await h.txns().filter { $0.txn.importBatchID == first.id }.allSatisfy {
      $0.txn.accountID == personal.id || $0.txn.toAccountID == personal.id
    })

    // The rest moves; the refused row stays, so the batch stays on the personal account.
    sheet.targetAccountID = business.id
    await h.model.startMove()?.value
    #expect(h.model.moveSheet == nil)
    let txns = try await h.txns()
    #expect(txns.first { $0.txn.id.uuidString == refusedID }?.txn.accountID == personal.id)
    #expect(h.model.history.first { $0.id == first.id }?.accountID == personal.id)
    #expect(h.model.lastMove?.batchMoved == false)
  }

  @Test("A transfer can't move onto its own other side; invalid targets are refused")
  func transferOntoOtherSide() async throws {
    let h = try await imported()
    let batch = try #require(h.model.history.first)
    await h.model.requestMove(batch)
    let sheet = try #require(h.model.moveSheet)
    let atm = try #require(sheet.plan.candidates.first { $0.otherAccountID != nil })
    let cash = try #require(atm.otherAccountID)
    sheet.targetAccountID = cash
    #expect(!sheet.selection.contains(atm.id.uuidString))
    #expect(atm.refusal(movingTo: cash) == .transferToTarget)
    #expect(sheet.movingIDs.count == sheet.plan.candidates.count - 1)

    await #expect(throws: ImportMoveError.invalidTarget) {
      try await self.store(h).move(batch.id, txnIDs: [atm.id], to: dollars.id)
    }
    await #expect(throws: ImportMoveError.invalidTarget) {
      try await self.store(h).move(batch.id, txnIDs: [atm.id], to: archived.id)
    }
    await #expect(throws: ImportMoveError.nothingToMove) {
      try await self.store(h).move(batch.id, txnIDs: [], to: business.id)
    }
  }

  @Test("History: Move is offered only for PKO batches with transactions of their own that are not undone")
  func historyAvailability() async throws {
    let h = try await ImportHarness.empty(accounts: [personal, business])
    let empty = ImportBatch(source: .pko, fileName: "statement.csv", importedAt: ImportHarness.now, accountID: personal.id)
    let saldo = ImportBatch(source: .saldo, fileName: "saldo.csv", importedAt: ImportHarness.now)
    try await store(h).commit(ImportCommit(batch: empty))
    try await store(h).commit(ImportCommit(batch: saldo))
    await h.model.load()
    let emptyBatch = try #require(h.model.history.first { $0.id == empty.id })
    let saldoBatch = try #require(h.model.history.first { $0.id == saldo.id })
    #expect(h.model.moveUnavailableReason(emptyBatch) == "This import has no transactions of its own to move.")
    #expect(h.model.moveUnavailableReason(saldoBatch)?.hasPrefix("Only a PKO statement") == true)
    await h.model.requestMove(emptyBatch)
    #expect(h.model.moveSheet == nil)
    await #expect(throws: ImportMoveError.notMovable) { try await self.store(h).movePlan(saldo.id) }
  }

  @Test("Sorting and selection in the move list behave like the review list")
  func sortAndSelect() async throws {
    let h = try await imported()
    await h.model.requestMove(try #require(h.model.history.first))
    let sheet = try #require(h.model.moveSheet)
    sheet.toggleSort(.amount)
    #expect(sheet.sortDirection(of: .amount) == true)
    let ids = sheet.visibleRows.map(\.id)
    sheet.selectNone()
    #expect(sheet.movingIDs.isEmpty)
    sheet.select(ids[1], mode: .replace)
    sheet.select(ids[3], mode: .range)
    #expect(sheet.selection == Set(ids[1...3]))
    sheet.toggleSort(.amount)
    sheet.toggleSort(.amount)
    #expect(sheet.rowSort == nil)
    sheet.selectAll()
    #expect(sheet.selection.count == sheet.plan.candidates.count)
  }
}
