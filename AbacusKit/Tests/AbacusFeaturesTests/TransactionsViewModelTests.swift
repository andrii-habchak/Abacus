import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@Suite("Transactions · in-memory query")
struct TransactionQueryMatcherTests {
  let store = TransactionsPreviewStore.preview().transactions
  let today = PreviewData.today

  func payees(_ query: TxnQuery) async throws -> [String] {
    try await store.transactions(matching: query).map(\.txn.payee)
  }

  func last30(_ change: (inout TxnQuery) -> Void) -> TxnQuery {
    var query = TxnQuery.lastThirtyDays(today: today)
    change(&query)
    return query
  }

  @Test("R-LIST-1: last 30 days, newest first; the range is inclusive")
  func defaultRange() async throws {
    let all = try await payees(.lastThirtyDays(today: today))
    #expect(all.count == 16)
    #expect(all.first == "Bolt")
    #expect(all.last == "Auchan")
    let oneDay = try await payees(TxnQuery(fromDay: Day("2026-10-08"), toDay: Day("2026-10-08")))
    #expect(Set(oneDay) == ["Orange", "Zalando"])
    #expect(oneDay == ["Orange", "Zalando"])
  }

  @Test("R-LIST-3: oldest first")
  func oldestFirst() async throws {
    let rows = try await payees(last30 { $0.newestFirst = false })
    #expect(rows.first == "Auchan")
    #expect(rows.last == "Bolt")
  }

  @Test("R-LIST-2: a parent category matches its children and attached records")
  func categories() async throws {
    let food = try await payees(last30 { $0.categoryIDs = [PreviewData.id(201)] })
    #expect(Set(food) == ["Biedronka", "Café du Parc", "Lidl", "Pizzeria Napoli", "Auchan"])
    let fees = try await payees(last30 { $0.categoryIDs = [PreviewData.id(213)] })
    #expect(fees == ["To EUR card"])
    let cashback = try await payees(last30 { $0.categoryIDs = [PreviewData.id(252)] })
    #expect(cashback == ["Lidl"])
  }

  @Test("R-LIST-2: accounts match either side of a transfer")
  func accounts() async throws {
    let cash = try await payees(last30 { $0.accountIDs = [PreviewData.cashPLN.id] })
    #expect(cash == ["ATM withdrawal"])
    let revolut = try await payees(last30 { $0.accountIDs = [PreviewData.revolutEUR.id] })
    #expect(revolut == ["To EUR card", "Salary", "Uber"])
  }

  @Test("R-LIST-2: types and event")
  func typesAndEvent() async throws {
    let transfers = try await payees(last30 { $0.types = [.transfer] })
    #expect(transfers == ["ATM withdrawal", "To EUR card", "Currency exchange"])
    let lyon = try await payees(last30 { $0.eventIDs = [PreviewData.lyonTrip.id] })
    #expect(lyon == ["Café du Parc", "Uber"])
  }

  @Test("R-LIST-6: search over description and note, case-insensitive")
  func search() async throws {
    #expect(try await payees(last30 { $0.search = "BOLT" }) == ["Bolt"])
    #expect(try await payees(last30 { $0.search = "lunch" }) == ["Café du Parc"])
    #expect(try await payees(last30 { $0.search = "transfer fee" }) == ["To EUR card"])
    #expect(try await payees(last30 { $0.search = "nothing like this" }).isEmpty)
  }
}

@MainActor
@Suite("Transactions · view model")
struct TransactionsViewModelTests {
  @Test("R-LIST-1: loads the last 30 days on PreviewData")
  func loads() async {
    let model = TransactionsViewModel.preview()
    await model.load()
    #expect(model.content.totals.count == 16)
    #expect(model.dateLabel == "Last 30 days")
    #expect(model.categoryLabel == "All categories")
    #expect(model.accountLabel == "All accounts")
    #expect(model.eventLabel == "Any event")
    #expect(!model.filters.hasActiveFilters)
    #expect(model.accountOptions.map(\.name).contains("Old card") == false)
  }

  @Test("R-LIST-2: filters reload the list; Clear filters restores it")
  func filtering() async {
    let model = TransactionsViewModel.preview()
    await model.load()
    model.toggleCategory(PreviewData.id(201))
    model.filters.toggleType(.income)
    await model.reload()
    #expect(model.categoryLabel == "Food")
    #expect(model.isCategoryChecked(PreviewData.id(202)))
    #expect(model.content.totals.count == 5)
    #expect(model.content.totals.income == .zero(.PLN))

    model.filters.eventID = PreviewData.lyonTrip.id
    model.filters.toggleAccount(PreviewData.monobank.id)
    await model.reload()
    #expect(model.eventLabel == "Event: Lyon trip")
    #expect(model.accountLabel == "Monobank Black")
    #expect(model.content.days.flatMap(\.rows).map(\.title) == ["Café du Parc"])

    model.clearFilters()
    await model.reload()
    #expect(model.content.totals.count == 16)
  }

  @Test("R-LIST-2: no type on → empty state")
  func emptyState() async {
    let model = TransactionsViewModel.preview()
    await model.load()
    model.selection = PreviewData.id(401)
    for type in TxnType.allCases { model.filters.toggleType(type) }
    await model.reload()
    #expect(model.content.isEmpty)
    #expect(model.selection == nil)
  }

  @Test("R-LIST-6: search")
  func search() async {
    let model = TransactionsViewModel.preview()
    await model.load()
    model.filters.search = "jacket"
    await model.reload()
    #expect(model.content.days.flatMap(\.rows).map(\.title) == ["Zalando"])
  }

  @Test("R-LIST-5: switching the display currency recomputes the totals")
  func displayCurrency() async {
    let model = TransactionsViewModel.preview(displayCurrency: .PLN)
    await model.load()
    #expect(model.content.netText == "+zł\u{00A0}9,152.38")
    model.displayCurrency = .EUR
    #expect(model.content.totals.net.currency == .EUR)
    model.refundsReduceSpending = true
    #expect(model.content.totals.net.currency == .EUR)
  }

  @Test("R-LIST-2: custom range label")
  func customLabel() async {
    let model = TransactionsViewModel.preview()
    model.filters.setCustomRange(from: Day("2026-10-01")!, to: Day("2026-10-15")!)
    #expect(model.dateLabel == "Oct 1, 2026 – Oct 15, 2026")
    #expect(model.dateRange == Day("2026-10-01")!...Day("2026-10-15")!)
  }
}
