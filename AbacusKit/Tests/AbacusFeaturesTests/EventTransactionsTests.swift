import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Testing

/// "Show N transactions" of an event (R-EVT-3) and the type filter on that list (R-LIST-2).
@MainActor
@Suite("Transactions · event filter")
struct EventTransactionsFilterTests {
  let lyon = PreviewData.lyonTrip

  /// PreviewData plus three Lyon-trip transactions outside the event's dates and of other
  /// types: a flight booked before the trip, a reimbursement and a card top-up after it.
  var extra: [Txn] {
    let calendar = Calendar.current
    func at(_ day: String) -> Date { Day(day)!.date(calendar: calendar).addingTimeInterval(12 * 3600) }
    return [
      Txn(
        id: PreviewData.id(9101), type: .expense, occurredAt: at("2026-09-02"),
        accountID: PreviewData.pkoPersonal.id, amountMinor: 610_00, categoryID: PreviewData.id(214),
        payee: "Flight to Lyon", eventID: lyon.id),
      Txn(
        id: PreviewData.id(9102), type: .income, occurredAt: at("2026-10-20"),
        accountID: PreviewData.pkoPersonal.id, amountMinor: 150_00, categoryID: PreviewData.id(253),
        payee: "Trip reimbursement", eventID: lyon.id),
      Txn(
        id: PreviewData.id(9103), type: .transfer, occurredAt: at("2026-09-28"),
        accountID: PreviewData.monobank.id, amountMinor: 440_00, toAccountID: PreviewData.revolutEUR.id,
        toAmountMinor: 10_00, payee: "Top-up for the trip", eventID: lyon.id),
    ]
  }

  func model(filters: TransactionFilters) -> TransactionsViewModel {
    let store = TransactionsPreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, events: PreviewData.events,
      txns: PreviewData.txns + extra, attachedRecords: PreviewData.attachedRecords)
    return TransactionsViewModel(
      transactions: store.transactions, accounts: store.accounts, categories: store.categories,
      events: store.events, converter: RateTable.transactionsPreview, displayCurrency: .PLN,
      filters: filters, today: { PreviewData.today })
  }

  func payees(_ model: TransactionsViewModel) -> Set<String> { Set(model.rows.map(\.txn.payee)) }

  @Test("R-EVT-3: Show transactions lists every transaction of the event — any type, any date")
  func everyTaggedTransaction() async {
    let filters = TransactionFilters.event(lyon)
    #expect(filters.types == Set(TxnType.allCases))
    #expect(!filters.isTypeFiltered)
    #expect(filters.eventID == lyon.id)
    #expect(filters.dateRange == TransactionFilters.allDates)

    let model = model(filters: filters)
    await model.load()
    let tagged = (PreviewData.txns + extra).filter { $0.eventID == lyon.id }
    // The count matches what the event view counts (EventTotals.txnCount: every tagged one).
    #expect(model.rows.count == tagged.count)
    #expect(payees(model) == ["Café du Parc", "Uber", "Flight to Lyon", "Trip reimbursement", "Top-up for the trip"])
    #expect(model.eventLabel == "Event: Lyon trip")
    #expect(model.dateLabel == "All dates")
    #expect(model.query?.types == [])
  }

  @Test("R-LIST-2: the type toggles work on an event's list and combine with the event")
  func toggleTypes() async {
    let model = model(filters: .event(lyon))
    await model.load()

    model.filters.toggleType(.expense)
    await model.reload()
    #expect(payees(model) == ["Trip reimbursement", "Top-up for the trip"])
    #expect(model.filters.eventID == lyon.id)

    model.filters.toggleType(.transfer)
    await model.reload()
    #expect(payees(model) == ["Trip reimbursement"])

    model.filters.toggleType(.income)
    await model.reload()
    #expect(model.rows.isEmpty)
    #expect(model.query == nil)

    model.filters.toggleType(.expense)
    await model.reload()
    #expect(payees(model) == ["Café du Parc", "Uber", "Flight to Lyon"])

    model.filters.toggleType(.income)
    model.filters.toggleType(.transfer)
    await model.reload()
    #expect(model.rows.count == 5)
    #expect(!model.filters.isTypeFiltered)
  }

  @Test("R-EVT-3: a new Show transactions replaces earlier filters, types included")
  func replacesEarlierFilters() {
    var earlier = TransactionFilters.drillDown(category: nil, month: Month(year: 2026, month: 10))
    #expect(earlier.types == [.expense])
    earlier = .event(lyon)
    #expect(earlier.types == Set(TxnType.allCases))
    #expect(!earlier.includeUncategorised)
    #expect(earlier.categoryIDs.isEmpty)
  }
}

@MainActor
@Suite("Manage · Events search and archive")
struct EventsSearchArchiveTests {
  let store = ManagePreviewStore.sample()

  func model() async -> EventsModel {
    let model = EventsModel(dependencies: ManageFixture.dependencies(store), displayCurrency: .UAH)
    await model.load()
    return model
  }

  @Test("R-MGMT-11: the page search filters events by name, ignoring case and accents")
  func search() async {
    let model = await model()
    #expect(model.rows.map(\.name) == ["Lyon trip", "Car", "Relocation"])
    model.search = "LYON"
    #expect(model.rows.map(\.name) == ["Lyon trip"])
    model.search = "  car "
    #expect(model.rows.map(\.name) == ["Car"])
    model.search = "relocatión"
    #expect(model.rows.map(\.name) == ["Relocation"])
    model.search = "nothing"
    #expect(model.rows.isEmpty)
    model.search = ""
    #expect(model.rows.count == 3)
  }

  @Test("R-MGMT-4: an archived event's name, dates and budget are read-only; its colour is not")
  func archivedIsReadOnly() async throws {
    let model = await model()
    model.select(ManageSample.lyonTrip.id)
    #expect(!model.isReadOnly)
    await model.archiveOrUnarchive()
    model.select(ManageSample.lyonTrip.id)
    #expect(model.isReadOnly)
    let before = try #require(model.event(ManageSample.lyonTrip.id))

    model.draft?.name = "Renamed"
    model.draft?.budget = "1"
    model.draft?.hasEnd = false
    #expect(!model.isDirty)
    #expect(!model.canSave)

    model.draft?.colorHex = "#123456"
    #expect(model.canSave)
    await model.save()
    let saved = try #require(model.event(ManageSample.lyonTrip.id))
    #expect(saved.colorHex == "#123456")
    #expect(saved.name == before.name)
    #expect(saved.budgetMinor == before.budgetMinor)
    #expect(saved.endDay == before.endDay)

    await model.archiveOrUnarchive()
    model.select(ManageSample.lyonTrip.id)
    #expect(!model.isReadOnly)
    model.newEvent()
    #expect(!model.isReadOnly)
  }
}
