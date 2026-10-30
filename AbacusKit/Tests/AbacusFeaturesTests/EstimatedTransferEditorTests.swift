import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

/// C38: editing a transfer with an estimated amount.
@MainActor
struct EstimatedTransferEditorTests {
  @Test("the flag stays while the amounts and accounts are unchanged and clears when an amount changes")
  func flagFollowsAmounts() async throws {
    var estimated = try #require(PreviewData.txns.first { $0.id == PreviewData.id(415) })
    estimated.isEstimatedTransferAmount = true
    let h = EditorHarness(.edit(estimated.id))
    try await h.store.transactions.save(estimated, lines: [])
    await h.model.load()
    h.model.note = "A new note"
    #expect(try #require(h.model.makeTransaction()).txn.isEstimatedTransferAmount)
    h.model.toAmountText = "7790"
    #expect(try #require(h.model.makeTransaction()).txn.isEstimatedTransferAmount == false)
  }
}
