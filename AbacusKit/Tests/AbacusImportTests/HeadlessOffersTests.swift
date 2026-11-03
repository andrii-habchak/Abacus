import AbacusDomain
import AbacusStore
import Foundation
import Testing

@testable import AbacusImport

/// N3: the headless `abacus-import` accepts the offers the wizard would show (C35 refunds, C38
/// estimated transfers) through `ImportPreview.acceptingOffers()`; synthetic PKO rows.
@Suite("Headless import offers (N3)")
struct HeadlessOffersTests {
  typealias F = PipelineFixture

  @Test("C35: a refund with the same description and amount as an earlier expense is linked on commit")
  func refundLinked() async throws {
    let env = try RefundSuggestionTests.Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    let preview = try await env.preview([
      RefundSuggestionTests.card("2026-01-12", "+45.00"),
      RefundSuggestionTests.card("2026-01-13", "-12.00", "OTHER SHOP", ref: "2"),
    ])
    let offers = preview.acceptingOffers()
    #expect(offers.refunds == 1 && offers.estimates == 0)
    let summary = try await env.pipeline.commit(offers.preview.acceptingDefaults())
    #expect(summary.refundsLinked == 1)
    let refund = try #require(try await env.allTxns().first { $0.amountMinor == 45_00 && $0.id != original.id })
    #expect(refund.refundOfID == original.id && refund.isRefund)
  }

  @Test("C35: a row without an offer is left alone")
  func noOffer() async throws {
    let env = try RefundSuggestionTests.Env()
    try await env.seed()
    try await env.expense("2026-01-05", 45_00)
    let preview = try await env.preview([RefundSuggestionTests.card("2026-01-12", "+44.00")])
    let offers = preview.acceptingOffers()
    #expect(offers.refunds == 0 && offers.estimates == 0)
    let summary = try await env.pipeline.commit(offers.preview.acceptingDefaults())
    #expect(summary.refundsLinked == 0)
  }

  @Test("C38: a row on the other account completes an estimated transfer on commit, no second transaction")
  func estimateCompleted() async throws {
    typealias T = TransferCounterpartTests
    let env = try T.Env()
    try await env.seed()
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-03-10"), accountID: F.pkoUSD.id, amountMinor: 100_00,
      toAccountID: F.pkoAccount.id, toAmountMinor: 400_00, payee: "JAN PRZYKLAD", source: .pko,
      isEstimatedTransferAmount: true)
    try await env.txns.save(transfer, lines: [])
    let preview = try await env.pln([T.plnIn("2026-03-12", "402.50")])
    let offers = preview.acceptingOffers()
    #expect(offers.estimates == 1 && offers.refunds == 0)
    let summary = try await env.pipeline.commit(offers.preview.acceptingDefaults())
    #expect(summary.estimatesCompleted == 1 && summary.created == 0)
    let all = try await env.allTxns()
    #expect(all.count == 1 && all.first?.toAmountMinor == 402_50 && all.first?.isEstimatedTransferAmount == false)
  }

  @Test("C38: without the counterpart repository (the old tool wiring) nothing is offered")
  func noRepositoryNoOffer() async throws {
    typealias T = TransferCounterpartTests
    let env = try T.Env()
    try await env.seed()
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-03-10"), accountID: F.pkoUSD.id, amountMinor: 100_00,
      toAccountID: F.pkoAccount.id, toAmountMinor: 400_00, payee: "JAN PRZYKLAD", source: .pko,
      isEstimatedTransferAmount: true)
    try await env.txns.save(transfer, lines: [])
    let bare = ImportPipeline(
      store: env.store, accounts: env.accounts, categories: SQLiteCategoryRepository(database: env.database),
      events: SQLiteEventRepository(database: env.database),
      rules: SQLiteRuleRepository(database: env.database, calendar: env.calendar), calendar: env.calendar)
    let preview = try await bare.preview(
      data: F.pko([T.plnIn("2026-03-12", "402.50")]), fileName: "pln.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.acceptingOffers().estimates == 0)
  }
}
