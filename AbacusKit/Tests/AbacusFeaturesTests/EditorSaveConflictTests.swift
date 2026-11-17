import AbacusDomain
import Foundation
import Testing

@testable import AbacusFeatures

/// N2: Save over a transaction another program changed or deleted meanwhile asks first
/// (R-TX-7 edit; the stored row read when the sheet opened is the fingerprint).
@MainActor
@Suite("Editor · save conflict (N2)")
struct EditorSaveConflictTests {
  let id = PreviewData.id(411)

  /// Another program edits the stored row behind the open sheet.
  func changeBehind(_ h: EditorHarness, note: String = "changed elsewhere") async throws {
    let stored = try #require(try await h.store.transactions.transaction(id))
    var txn = stored.txn
    txn.note = note
    try await h.store.transactions.save(txn, lines: stored.lines)
  }

  @Test("N2 fingerprint: equal rows match, a changed value or a deleted row conflicts")
  func fingerprint() async throws {
    let h = EditorHarness()
    let row = try #require(try await h.store.transactions.transaction(id))
    #expect(EditorSaveConflict(opened: row, now: row) == nil)
    var changed = row
    changed.txn.amountMinor += 1
    #expect(EditorSaveConflict(opened: row, now: changed) == .changed)
    #expect(EditorSaveConflict(opened: row, now: nil) == .deleted)
  }

  @Test("N2 unchanged row: Save saves without asking")
  func noConflict() async throws {
    let h = await EditorHarness.loaded(.edit(id))
    h.model.note = "mine"
    #expect(await h.model.save() == .saved(id))
    #expect(h.model.saveConflict == nil)
    #expect(try await h.store.transactions.transaction(id)?.txn.note == "mine")
  }

  @Test("N2 changed elsewhere: Save asks; Replace writes this version")
  func replace() async throws {
    let h = await EditorHarness.loaded(.edit(id))
    h.model.note = "mine"
    try await changeBehind(h)
    #expect(await h.model.save() == nil)
    #expect(h.model.saveConflict == .changed)
    #expect(h.model.saveConflict?.title == "This transaction was changed by another program.")
    #expect(try await h.store.transactions.transaction(id)?.txn.note == "changed elsewhere")
    #expect(await h.model.replaceChangedRecord() == .saved(id))
    #expect(h.model.saveConflict == nil)
    #expect(try await h.store.transactions.transaction(id)?.txn.note == "mine")
  }

  @Test("N2 changed elsewhere: Cancel reloads the sheet with the stored row")
  func cancelReloads() async throws {
    let h = await EditorHarness.loaded(.edit(id))
    h.model.note = "mine"
    try await changeBehind(h)
    #expect(await h.model.save() == nil)
    h.model.dismissSaveConflict()
    await h.model.reloadAfterConflict()
    #expect(h.model.saveConflict == nil)
    #expect(h.model.isLoaded)
    #expect(h.model.note == "changed elsewhere")
    // The reloaded sheet saves without asking again.
    h.model.note = "second try"
    #expect(await h.model.save() == .saved(id))
  }

  @Test("N2 deleted elsewhere: Save asks; Replace stores this version again")
  func deleted() async throws {
    let h = await EditorHarness.loaded(.edit(id))
    h.model.note = "mine"
    try await h.store.transactions.delete(id)
    #expect(await h.model.save() == nil)
    #expect(h.model.saveConflict == .deleted)
    #expect(await h.model.replaceChangedRecord() == .saved(id))
    #expect(try await h.store.transactions.transaction(id)?.txn.note == "mine")
  }

  @Test("N2 a duplicate is a new transaction: no conflict check")
  func duplicateSkipsCheck() async throws {
    let h = await EditorHarness.loaded(.edit(id))
    try await changeBehind(h)
    h.model.duplicate()
    let result = await h.model.save()
    #expect(result != nil)
    #expect(h.model.saveConflict == nil)
  }
}
