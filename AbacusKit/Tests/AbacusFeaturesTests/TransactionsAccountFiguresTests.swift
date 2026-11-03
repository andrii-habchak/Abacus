import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@Suite("Transactions · N6 account figures")
@MainActor
struct TransactionsAccountFiguresTests {
  @Test("N6: Balance, Cleared and Uncleared show only while exactly one account is filtered")
  func onlyForOneAccount() async {
    let model = TransactionsViewModel.preview()
    await model.load()
    #expect(model.accountFigures == nil)

    model.filters.toggleAccount(PreviewData.cashPLN.id)
    await model.reload()
    let figures = model.accountFigures
    #expect(figures?.balance.isEmpty == false)
    #expect(figures?.cleared.isEmpty == false)
    #expect(figures?.uncleared.isEmpty == false)

    model.filters.toggleAccount(PreviewData.monobank.id)
    await model.reload()
    #expect(model.accountFigures == nil)

    model.clearFilters()
    await model.reload()
    #expect(model.accountFigures == nil)
  }

  @Test("N6: the cleared filter reads All by default and keeps its three choices")
  func clearedFilterChoices() {
    #expect(TransactionFilters().cleared == .all)
    #expect(ClearedFilter.allCases.map(\.title) == ["All", "Cleared", "Uncleared"])
  }
}
