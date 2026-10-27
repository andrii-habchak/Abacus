import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@Suite("Transactions · filters → query")
struct TransactionFiltersTests {
  let today = PreviewData.today
  let food = PreviewData.id(201)
  let groceries = PreviewData.id(202)
  let eatingOut = PreviewData.id(203)
  let housing = PreviewData.id(204)

  @Test("R-LIST-1: default is the last 30 days, every type, newest first")
  func defaultQuery() throws {
    let query = try #require(TransactionFilters.default.query(today: today))
    #expect(query == TxnQuery.lastThirtyDays(today: today))
    #expect(query.fromDay == Day("2026-09-22"))
    #expect(query.toDay == Day("2026-10-21"))
    #expect(query.types.isEmpty)
    #expect(query.newestFirst)
    #expect(!TransactionFilters.default.hasActiveFilters)
  }

  @Test(
    "R-LIST-2: date presets",
    arguments: [
      (TransactionFilters.Preset.last30Days, "2026-09-22", "2026-10-21"),
      (.thisMonth, "2026-10-01", "2026-10-31"),
      (.lastMonth, "2026-09-01", "2026-09-30"),
      (.last3Months, "2026-07-22", "2026-10-21"),
      (.thisYear, "2026-01-01", "2026-12-31"),
    ])
  func presets(preset: TransactionFilters.Preset, from: String, to: String) throws {
    let filters = TransactionFilters(dateRange: .preset(preset))
    let query = try #require(filters.query(today: today))
    #expect(query.fromDay == Day(from))
    #expect(query.toDay == Day(to))
    #expect(filters.hasActiveFilters == (preset != .last30Days))
  }

  @Test("R-LIST-2: a custom range is inclusive and its ends are put in order")
  func customRange() throws {
    var filters = TransactionFilters()
    filters.setCustomRange(from: Day("2026-10-10")!, to: Day("2026-10-01")!)
    let query = try #require(filters.query(today: today))
    #expect(query.fromDay == Day("2026-10-01"))
    #expect(query.toDay == Day("2026-10-10"))
    #expect(filters.isDateFiltered)
  }

  @Test("R-LIST-2: categories, accounts, types and event go into the query")
  func combined() throws {
    var filters = TransactionFilters()
    filters.categoryIDs = [food]
    filters.toggleAccount(PreviewData.pkoPersonal.id)
    filters.toggleType(.transfer)
    filters.eventID = PreviewData.lyonTrip.id
    let query = try #require(filters.query(today: today))
    #expect(query.categoryIDs == [food])
    #expect(query.accountIDs == [PreviewData.pkoPersonal.id])
    #expect(query.types == [.expense, .income])
    #expect(query.eventIDs == [PreviewData.lyonTrip.id])
    #expect(filters.hasActiveFilters)
  }

  @Test("R-LIST-2: with every type off nothing can match (no query)")
  func noTypes() {
    var filters = TransactionFilters()
    for type in TxnType.allCases { filters.toggleType(type) }
    #expect(filters.query(today: today) == nil)
    #expect(filters.isTypeFiltered)
  }

  @Test("R-LIST-6: search is trimmed and counts as a filter; blanks do not")
  func search() throws {
    var filters = TransactionFilters()
    filters.search = "   "
    #expect(!filters.hasActiveFilters)
    filters.search = "  Lunch "
    #expect(try #require(filters.query(today: today)).search == "Lunch")
    #expect(filters.hasActiveFilters)
  }

  @Test("R-LIST-3: sort order is not a filter and survives Clear filters")
  func clearKeepsSort() throws {
    var filters = TransactionFilters()
    filters.newestFirst = false
    #expect(!filters.hasActiveFilters)
    filters.categoryIDs = [food]
    filters.search = "x"
    filters.dateRange = .preset(.thisYear)
    filters.clear()
    #expect(!filters.hasActiveFilters)
    #expect(filters.newestFirst == false)
    #expect(try #require(filters.query(today: today)).newestFirst == false)
  }

  @Test("R-HOME-3 / R-EVT-3: drill-down and event shortcuts")
  func shortcuts() throws {
    let drill = TransactionFilters.drillDown(category: groceries, month: Month(year: 2026, month: 9))
    let query = try #require(drill.query(today: today))
    #expect(query.fromDay == Day("2026-09-01"))
    #expect(query.toDay == Day("2026-09-30"))
    #expect(query.categoryIDs == [groceries])

    let event = try #require(TransactionFilters.event(PreviewData.lyonTrip).query(today: today))
    #expect(event.eventIDs == [PreviewData.lyonTrip.id])
    // Any date: the event's own dates only steer auto-tagging (R-EVT-2).
    #expect(event.fromDay == Day("1900-01-01"))
    #expect(event.toDay == Day("9999-12-31"))
    #expect(event.types.isEmpty)
  }

  // MARK: Category multi-select

  var tree: TransactionCategoryTree { TransactionCategoryTree(PreviewData.categories) }

  @Test("R-LIST-2: menu lists parents “(all)” with their children, expense before income")
  func menuOrder() {
    let labels = tree.options.map(\.label)
    #expect(Array(labels.prefix(5)) == ["Food (all)", "Groceries", "Eating out", "Housing (all)", "Rent"])
    #expect(labels.firstIndex(of: "Salary")! > labels.firstIndex(of: "Travel")!)
    #expect(tree.options.first { $0.name == "Groceries" }?.isChild == true)
    #expect(tree.path(eatingOut) == "Food › Eating out")
    #expect(tree.path(food) == "Food")
  }

  @Test("R-LIST-2: a selected parent covers and ticks its children")
  func parentCoversChildren() {
    let selection = tree.toggled(food, in: [groceries])
    #expect(selection == [food])
    #expect(tree.isChecked(groceries, in: selection))
    #expect(tree.isChecked(eatingOut, in: selection))
    #expect(!tree.isChecked(housing, in: selection))
    #expect(tree.expanded(selection) == [food, groceries, eatingOut])
    #expect(tree.toggled(food, in: selection).isEmpty)
  }

  @Test("R-LIST-2: unticking a child of a selected parent keeps its siblings")
  func childOfSelectedParent() {
    let selection = tree.toggled(groceries, in: [food])
    #expect(selection == [eatingOut])
    #expect(tree.toggled(groceries, in: selection) == [eatingOut, groceries])
  }

  @Test("R-LIST-2: chip label")
  func chipLabel() {
    #expect(tree.label(for: []) == "All categories")
    #expect(tree.label(for: [groceries]) == "Food › Groceries")
    #expect(tree.label(for: [groceries, housing]) == "2 categories")
  }
}
