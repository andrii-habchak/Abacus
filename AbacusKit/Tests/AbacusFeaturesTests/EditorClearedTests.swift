import AbacusDomain
import Foundation
import Testing

@testable import AbacusFeatures

/// N6: the editor's "Cleared" checkbox and the warning for a bank-confirmed row (R-CLR-3, R-CLR-4).
@MainActor
@Suite("Editor · cleared (N6)")
struct EditorClearedTests {
  @Test("R-CLR-4: the checkbox shows when editing, saves the flag; a new transaction starts uncleared")
  func checkbox() async throws {
    let id = PreviewData.id(411)
    let h = await EditorHarness.loaded(.edit(id))
    #expect(h.model.showsCleared)
    #expect(!h.model.isCleared)
    h.model.isCleared = true
    #expect(await h.model.save() == .saved(id))
    #expect(try await h.store.transactions.transaction(id)?.txn.isCleared == true)

    let fresh = await EditorHarness.loaded(.new)
    #expect(!fresh.model.showsCleared)
  }

  @Test("R-CLR-3: changing the amount of a bank-confirmed row shows the warning and keeps the flag")
  func warning() async throws {
    let id = PreviewData.id(411)
    let h = EditorHarness(.edit(id))
    var stored = try #require(try await h.store.transactions.transaction(id)).txn
    stored.isCleared = true
    try await h.store.transactions.save(stored, lines: [])
    await h.model.load()
    #expect(h.model.isCleared && h.model.clearedWarning == nil)
    h.model.note = "changed"  // a note does not warn
    #expect(h.model.clearedWarning == nil)
    h.model.amountText = "1.23"
    #expect(h.model.clearedWarning?.contains("confirmed by the bank") == true)
    #expect(await h.model.save() == .saved(id))
    #expect(try await h.store.transactions.transaction(id)?.txn.isCleared == true)
  }
}
