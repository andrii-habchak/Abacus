import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Testing

/// R-HOME-6: the income donut, income vs expenses, and the remembered widget order.
@MainActor
@Suite("Dashboard widgets (R-HOME-6)")
struct DashboardWidgetsTests {
  static let format = DashboardFormat(locale: Locale(identifier: "en_US"), calendar: .current)
  let october = Month(year: 2026, month: 10)

  func model(
    store: DashboardPreviewStore = .previewData(), currency: Currency = .PLN
  ) async -> DashboardModel {
    let model = DashboardModel(dependencies: .preview(store: store, format: Self.format), displayCurrency: currency)
    await model.load()
    return model
  }

  // MARK: Income donut

  @Test("R-HOME-6: the income donut by category, largest first, refunds as their own slice with the setting off")
  func incomeDonut() async throws {
    let income = try #require(await model().income)
    #expect(income.kind == .income)
    #expect(income.month == october)
    #expect(income.title == "Monthly income")
    #expect(income.totalLabel == "Received")
    #expect(income.slices.map(\.name) == ["Salary", "Refunds", "Cashback"])
    #expect(income.slices.allSatisfy { $0.kind == .income })
    #expect(income.slices.first?.colorHex == "#2E9E4F")
    #expect(income.slices[1].drillsDown == false)
    #expect(income.slices[1].colorHex == DashboardDonut.neutralColor)
    let amounts = income.slices.map(\.amount.minorUnits)
    #expect(amounts == amounts.sorted(by: >))
    #expect(income.total.minorUnits == amounts.reduce(0, +))
    #expect(income.slices[1].amount.minorUnits == 120_00)
    #expect(income.chartLabel == "Income by category, October 2026")
    #expect(income.emptyText("May 2026") == "No income in May 2026.")
  }

  @Test("R-HOME-6, R-SET-3: with refunds reducing spending the income donut has no Refunds slice")
  func incomeDonutRefundsOn() async throws {
    let store = DashboardPreviewStore.previewData()
    try await store.settingsRepository.set(.refundsReduceSpending, "true")
    let income = try #require(await model(store: store).income)
    #expect(income.slices.map(\.name) == ["Salary", "Cashback"])
  }

  @Test("R-HOME-6: picking an income slice selects it in the income donut only and drills down to income of that category and month")
  func incomeDrillDown() async throws {
    let model = await model()
    let salary = try #require(model.income?.slices.first)
    let target = try #require(model.select(salary))
    #expect(target == DashboardDrillDown.Target(kind: .income, categoryID: PreviewData.id(251), month: october))
    #expect(model.selectedIncomeSlice == salary.id)
    #expect(model.selectedSlice == nil)
    let query = DashboardDrillDown.query(target)
    #expect(query.types == [.income])
    #expect(query.categoryIDs == [PreviewData.id(251)])
    #expect(query.fromDay == Day("2026-10-01"))
    #expect(query.toDay == Day("2026-10-31"))
    let filters = TransactionFilters.drillDown(target)
    #expect(filters.types == [.income])
    #expect(filters.categoryIDs == [PreviewData.id(251)])
    #expect(model.select(try #require(model.income?.slices[1])) == nil)  // Refunds: no drill-down
    await model.showPreviousMonth()
    #expect(model.selectedIncomeSlice == nil)
  }

  @Test("R-HOME-6: uncategorised income drills down to income without a category")
  func uncategorisedIncome() async throws {
    let query = DashboardDrillDown.query(categoryID: nil, month: october, kind: .income)
    #expect(query.types == [.income])
    #expect(query.includeUncategorised)
    #expect(query.categoryIDs.isEmpty)
    // The expenses drill-downs are unchanged.
    #expect(DashboardDrillDown.query(categoryID: nil, month: october).types == [.expense])
    #expect(DashboardDrillDown.query(categoryID: PreviewData.id(201), month: october).types.isEmpty)
    #expect(TransactionFilters.drillDown(category: PreviewData.id(201), month: october).types == Set(TxnType.allCases))
  }

  // MARK: Income vs expenses

  @Test("R-HOME-6: twelve months ending at the selected month; the selected month equals the donuts' totals")
  func incomeVsExpenses() async throws {
    let model = await model()
    let data = try #require(model.incomeVsExpenses)
    #expect(data.bars.count == 12)
    #expect(data.bars.first?.month == Month(year: 2025, month: 11))
    #expect(data.bars.last?.month == october)
    #expect(data.bars.filter(\.isSelected).map(\.month) == [october])
    let last = try #require(data.bars.last)
    #expect(last.income == model.income?.total)
    #expect(last.expense == model.expenses?.total)
    #expect(last.net == last.income - last.expense)
    #expect(data.income.minorUnits == data.bars.reduce(0) { $0 + $1.income.minorUnits })
    #expect(data.net == data.income - data.expense)
    #expect(data.rangeText == "November 2025 – October 2026")
    #expect(last.axisLabel == "Oct")
    #expect(last.netText.hasPrefix(last.net.minorUnits < 0 ? "−" : "+"))

    await model.showPreviousMonth()
    let shifted = try #require(model.incomeVsExpenses)
    #expect(shifted.bars.last?.month == Month(year: 2026, month: 9))
    #expect(shifted.bars.last?.expense == model.expenses?.total)
    #expect(shifted.bars.last?.isSelected == true)
  }

  @Test("R-HOME-4, R-HOME-6: income vs expenses follows the display currency")
  func incomeVsExpensesCurrency() async throws {
    let model = await model(currency: .PLN)
    #expect(model.incomeVsExpenses?.currency == .PLN)
    model.setDisplayCurrency(.EUR)
    let data = try #require(model.incomeVsExpenses)
    #expect(data.currency == .EUR)
    #expect(data.bars.allSatisfy { $0.income.currency == .EUR && $0.expense.currency == .EUR })
  }

  // MARK: Layout

  @Test("R-HOME-6: the default order; widths: net worth, income vs expenses and debts are full width")
  func defaultLayout() {
    let layout = DashboardLayout.default
    #expect(layout.order == [.netWorth, .budget, .expenses, .income, .incomeVsExpenses, .debts])
    #expect(layout.isDefault)
    #expect(DashboardWidget.allCases.filter(\.isFullWidth) == [.netWorth, .incomeVsExpenses, .debts])
    #expect(Set(DashboardLayout.defaultOrder) == Set(DashboardWidget.allCases))
  }

  @Test("R-HOME-6: reading the stored order drops unknown ids and duplicates and appends widgets it lacks")
  func storedLayout() {
    let stored = #"["income","futureWidget","netWorth","income","expenses"]"#
    let layout = DashboardLayout(stored: stored)
    #expect(layout.order == [.income, .netWorth, .expenses, .budget, .incomeVsExpenses, .debts])
    #expect(DashboardLayout(stored: layout.stored) == layout)
    #expect(DashboardLayout(stored: nil) == .default)
    #expect(DashboardLayout(stored: "") == .default)
    #expect(DashboardLayout(stored: "not json") == .default)
    #expect(DashboardLayout(stored: "[]") == .default)
  }

  @Test("R-HOME-6: a drop puts the dragged widget in the target's place; steps skip hidden widgets")
  func moves() {
    var layout = DashboardLayout.default
    layout.move(.netWorth, to: .income)
    #expect(layout.order == [.budget, .expenses, .income, .netWorth, .incomeVsExpenses, .debts])
    layout.move(.incomeVsExpenses, to: .budget)
    #expect(layout.order == [.incomeVsExpenses, .budget, .expenses, .income, .netWorth, .debts])
    layout.move(.budget, to: .budget)
    #expect(layout.order == [.incomeVsExpenses, .budget, .expenses, .income, .netWorth, .debts])

    var stepped = DashboardLayout.default
    let visible: [DashboardWidget] = [.netWorth, .budget, .expenses, .income, .incomeVsExpenses]
    stepped.move(.incomeVsExpenses, by: 1, among: visible)  // last visible: no change
    #expect(stepped == .default)
    stepped.move(.income, by: -1, among: visible)
    #expect(stepped.order == [.netWorth, .budget, .income, .expenses, .incomeVsExpenses, .debts])
    stepped.move(.netWorth, by: -1, among: visible)
    #expect(stepped.order == [.netWorth, .budget, .income, .expenses, .incomeVsExpenses, .debts])
  }

  @Test("R-HOME-6: rows — full width alone, half width two by two when wide, one per row when narrow")
  func rows() {
    let order: [DashboardWidget] = [.budget, .netWorth, .expenses, .income, .incomeVsExpenses, .debts]
    #expect(
      DashboardLayout.rows(order, columns: 2)
        == [[.budget], [.netWorth], [.expenses, .income], [.incomeVsExpenses], [.debts]])
    #expect(DashboardLayout.rows(DashboardLayout.defaultOrder, columns: 2).first == [.netWorth])
    #expect(DashboardLayout.rows(DashboardLayout.defaultOrder, columns: 2)[1] == [.budget, .expenses])
    #expect(DashboardLayout.rows(DashboardLayout.defaultOrder, columns: 2)[2] == [.income])
    #expect(DashboardLayout.rows(order, columns: 1).allSatisfy { $0.count == 1 })
  }

  @Test("R-HOME-6: the order is remembered in the settings and read back by the next load; reset clears it")
  func layoutPersistence() async throws {
    let store = DashboardPreviewStore.previewData()
    let first = await model(store: store)
    #expect(first.layout == .default)
    await first.moveWidget(.incomeVsExpenses, to: .netWorth)
    #expect(first.layout.order.first == .incomeVsExpenses)
    let stored = try await store.settingsRepository.value(.dashboardLayout)
    #expect(stored == first.layout.stored)

    let second = await model(store: store)
    #expect(second.layout == first.layout)

    await second.moveWidget(.budget, by: 1, among: [.incomeVsExpenses, .netWorth, .budget, .expenses, .income])
    #expect(second.layout.order == [.incomeVsExpenses, .netWorth, .expenses, .budget, .income, .debts])

    await second.resetLayout()
    #expect(second.layout == .default)
    #expect(try await store.settingsRepository.value(.dashboardLayout) == DashboardLayout.default.stored)
  }

  @Test("R-HOME-6: a stored order from another version loads without failing the dashboard")
  func unknownStoredIDs() async throws {
    let store = DashboardPreviewStore.previewData()
    try await store.settingsRepository.set(.dashboardLayout, #"["debts","savingsGoals","budget"]"#)
    let model = await model(store: store)
    #expect(model.phase == .loaded)
    #expect(model.layout.order == [.debts, .budget, .netWorth, .expenses, .income, .incomeVsExpenses])
  }
}
