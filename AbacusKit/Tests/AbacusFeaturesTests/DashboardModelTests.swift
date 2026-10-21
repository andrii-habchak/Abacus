import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Synchronization
import Testing

/// Dashboard view model on `PreviewData` and the synthetic year (`DashboardSample`).
@MainActor
@Suite("Dashboard")
struct DashboardModelTests {
  static let format = DashboardFormat(locale: Locale(identifier: "en_US"), calendar: .current)
  let today = PreviewData.today
  let october = Month(year: 2026, month: 10)
  let august = Month(year: 2026, month: 8)

  func model(
    _ dependencies: DashboardDependencies = .preview(format: DashboardModelTests.format), currency: Currency = .UAH
  ) async -> DashboardModel {
    let model = DashboardModel(dependencies: dependencies, displayCurrency: currency)
    await model.load()
    return model
  }

  func sample(currency: Currency = .UAH, fetchFailed: Bool = false) async -> DashboardModel {
    await model(.sample(fetchFailed: fetchFailed, format: Self.format), currency: currency)
  }

  func money(_ units: String, _ currency: Currency) -> Money { Money(Decimal(string: units)!, currency) }
  func pln(_ units: String) -> String { Self.format.money(money(units, .PLN)) }

  // MARK: Net worth (R-HOME-1)

  @Test("R-HOME-1: headline is today's net worth of non-archived accounts at the latest rate")
  func headline() async throws {
    let model = await model()
    let netWorth = try #require(model.netWorth)
    let rates = RateTable(rates: PreviewData.fxRates, today: today)
    let expected = Calc.netWorth(accounts: PreviewData.accounts, txns: txns(), currency: .UAH, converter: rates)
    #expect(netWorth.total == expected.total)
    #expect(netWorth.isComplete)
    #expect(netWorth.assets == expected.assets)
    #expect(netWorth.liabilities == expected.liabilities)
    #expect(netWorth.liabilitiesText.hasPrefix("−₴"))
    #expect(netWorth.points.last?.isToday == true)
    #expect(netWorth.points.last?.value == expected.total)
  }

  @Test("R-HOME-1, R-ACC-4: the account breakdown lists non-archived accounts, native and converted")
  func accountBreakdown() async throws {
    let netWorth = try #require(await model().netWorth)
    #expect(netWorth.accounts.map(\.name) == PreviewData.accounts.filter { !$0.isArchived }.map(\.name))
    let card = try #require(netWorth.accounts.first { $0.id == PreviewData.pkoCreditCard.id })
    #expect(card.isLiability)
    #expect(card.kind == "Credit card")
    #expect(card.balance.currency == .PLN)
    #expect(card.converted?.currency == .UAH)
    #expect(card.balanceText.hasPrefix("-"))
  }

  @Test("R-HOME-1: twelve monthly points ending today, change since the previous month end")
  func series() async throws {
    let netWorth = try #require(await sample().netWorth)
    #expect(netWorth.points.count == 12)
    #expect(netWorth.points.first?.day == Day("2025-11-30"))
    #expect(netWorth.points.dropLast().allSatisfy { !$0.isToday })
    #expect(netWorth.points.allSatisfy { $0.value != nil })
    let last = try #require(netWorth.points.last?.value)
    let previous = try #require(netWorth.points[10].value)
    #expect(netWorth.points[10].day == Day("2026-09-30"))
    #expect(netWorth.change == last - previous)
    let text = try #require(netWorth.changeText)
    #expect(text.hasSuffix("since end of September"))
    #expect(text.hasPrefix(last.minorUnits >= previous.minorUnits ? "+₴" : "−₴"))
    #expect(netWorth.points[10].detail.hasPrefix("September 2026: ₴"))
    #expect(netWorth.points[10].detail.hasSuffix("· at month end"))
    #expect(netWorth.points[11].detail.hasSuffix("· today"))
    #expect(netWorth.chartLabel == "Net worth at the end of each month, November 2025 to October 2026")
    let range = try #require(netWorth.valueRange)
    #expect(netWorth.points.allSatisfy { range.contains($0.value!.decimal) })
  }

  @Test("R-HOME-1, D27: month ends without rates are left off the chart and reported, never converted at 1")
  func missingMonthEnds() async throws {
    // PreviewData has rates from 22 Sep 2026 only; accounts open on 1 Jan 2026.
    let model = await model()
    let netWorth = try #require(model.netWorth)
    let byDay = Dictionary(uniqueKeysWithValues: netWorth.points.map { ($0.day, $0) })
    // Before the accounts opened every balance is zero: no rate needed.
    #expect(byDay[Day("2025-12-31")!]?.value == .zero(.UAH))
    // January–August: foreign balances without a rate.
    for month in 1...8 {
      let end = Month(year: 2026, month: month).lastDay()
      #expect(byDay[end]?.value == nil, "\(end)")
      #expect(byDay[end]?.detail.hasSuffix("not shown, exchange rates missing") == true)
    }
    #expect(byDay[Day("2026-09-30")!]?.value != nil)
    #expect(netWorth.plotted.count == 4)
    #expect(netWorth.change != nil)
    #expect(netWorth.missing.days.count == 8)
    #expect(netWorth.missing.rates.map(\.to) .allSatisfy { $0 == .UAH })
    #expect(Set(netWorth.missing.rates.map(\.from)) == [.PLN, .USD, .EUR])
    let text = try #require(model.missingRatesText)
    #expect(text.contains("no rate for EUR→UAH, PLN→UAH, USD→UAH on Jan 31, 2026 – Aug 31, 2026"))
  }

  @Test("R-FX-1: missing historical days are requested once per load")
  func requestsMissingRates() async throws {
    let requested = Mutex<[Set<Day>]>([])
    var dependencies = DashboardDependencies.preview(format: Self.format)
    dependencies.requestRates = { days in requested.withLock { $0.append(days) } }
    _ = await model(dependencies)
    let calls = requested.withLock { $0 }
    #expect(calls.count == 1)
    #expect(calls.first?.contains(Day("2026-08-31")!) == true)
    #expect(calls.first?.contains(Day("2026-09-30")!) == false)
  }

  // MARK: Budget (R-HOME-2, R-BUD-1…3)

  @Test("R-HOME-2: categories over, near and ok; the badge counts the rows over (unallocated included)")
  func overBudgetMonth() async throws {
    let model = await sample(currency: .PLN)
    await model.show(month: august)
    let budget = try #require(model.budget)
    let status = Dictionary(uniqueKeysWithValues: budget.rows.map { ($0.name, $0.status) })
    #expect(status["Rent"] == .near)  // 4,000 of 4,000
    #expect(status["Groceries"] == .over)  // 1,950 of 1,800
    #expect(status["Eating out"] == .over)  // 720 of 600
    #expect(status["Transport"] == .ok)  // fuel + taxi under the parent's limit
    #expect(status["Health"] == .ok)
    #expect(status["Unallocated (other categories)"] == .over)  // bills + travel 2,905 of 1,700
    #expect(budget.overCount == 3)
    #expect(budget.badgeText == "3 categories over")
    #expect(budget.status == .over)
    #expect(budget.spent == money("9935", .PLN))
    #expect(budget.remainingText == "Over budget by \(pln("935")) · 110% used")
    let groceries = try #require(budget.rows.first { $0.name == "Groceries" })
    #expect(groceries.noteText == "Over by \(pln("150"))")
    #expect(groceries.amountsText == "\(pln("1950")) / \(pln("1800"))")
    #expect(groceries.barFraction == 1)
    #expect(budget.rows.last?.isUnallocated == true)
    #expect(model.monthNote == "Closed month")
  }

  @Test("R-HOME-2: on track, remaining and % used, days left in the current month")
  func currentMonth() async throws {
    let model = await sample(currency: .PLN)
    let budget = try #require(model.budget)
    #expect(budget.month == october)
    #expect(budget.badgeText == "On track")
    #expect(budget.overCount == 0)
    #expect(budget.daysLeft == 10)
    #expect(model.monthNote == "10 days left")
    #expect(budget.remainingText.hasSuffix("% used"))
    #expect(budget.remainingText.contains(" left · "))
    let rent = try #require(budget.rows.first { $0.name == "Rent" })
    #expect(rent.status == .near)
    #expect(rent.noteText == "\(pln("0")) left")
  }

  @Test("R-BUD-1: the unallocated row is the total minus the category limits")
  func unallocated() async throws {
    let budget = try #require(await sample(currency: .PLN).budget)
    let row = try #require(budget.rows.last)
    #expect(row.name == "Unallocated (other categories)")
    #expect(row.limit == money("1700", .PLN))
    #expect(budget.limit == money("9000", .PLN))
    #expect(budget.limitText == "of \(pln("9000"))")
    #expect(pln("9000").contains("9,000"))
  }

  @Test("R-BUD-2, R-FX-3: status is decided in the plan's currency, amounts shown in the display currency")
  func budgetInDisplayCurrency() async throws {
    let model = await sample(currency: .UAH)
    let current = try #require(model.budget)
    #expect(current.planCurrency == .PLN)
    #expect(current.shownCurrency == .UAH)
    #expect(current.limit == money("101700", .UAH))  // 9,000 × 11.30 (latest)
    #expect(current.currencyNote == "Budget in PLN, shown in UAH at the latest rate")
    await model.show(month: august)
    let closed = try #require(model.budget)
    #expect(closed.limit == money("100080", .UAH))  // 9,000 × 11.12 (31 Aug)
    #expect(closed.overCount == 3)
    #expect(closed.currencyNote == "Budget in PLN, shown in UAH at the rate of Aug 31, 2026")
  }

  @Test("R-BUD-2, D27: without a plan→display rate the budget stays in the plan's currency and says so")
  func budgetWithoutDisplayRate() async throws {
    let rates = RateTable(rates: PreviewData.fxRates.filter { $0.base != .PLN }, today: today)
    let model = await model(.preview(rates: rates, format: Self.format), currency: .UAH)
    let budget = try #require(model.budget)
    #expect(budget.shownCurrency == .PLN)
    #expect(budget.currencyNote == "No PLN→UAH rate: amounts in PLN")
    #expect(!budget.missing.isEmpty)
    #expect(model.missingRatesText != nil)
  }

  @Test("R-BUD-3: no plan in effect → no budget widget")
  func noPlan() async throws {
    let store = DashboardPreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, txns: PreviewData.txns)
    let model = await model(.preview(store: store, format: Self.format))
    #expect(model.phase == .loaded)
    #expect(model.budget == nil)
    #expect(model.expenses?.isEmpty == false)
  }

  // MARK: Expenses (R-HOME-3)

  @Test("R-HOME-3: donut slices by top-level category, largest first, with subcategories and shares")
  func donut() async throws {
    let expenses = try #require(await model(currency: .PLN).expenses)
    #expect(expenses.month == october)
    #expect(expenses.slices.first?.name == "Housing")
    let amounts = expenses.slices.map(\.amount.minorUnits)
    #expect(amounts == amounts.sorted(by: >))
    #expect(expenses.total.minorUnits == amounts.reduce(0, +))
    let food = try #require(expenses.slices.first { $0.name == "Food" })
    #expect(Set(food.children.map(\.name)) == ["Groceries", "Eating out"])
    #expect(food.colorHex == "#E07B14")
    let shares = expenses.slices.compactMap(\.share).reduce(Decimal(0), +)
    #expect(abs(NSDecimalNumber(decimal: shares - 1).doubleValue) < 0.000_001)
    #expect(expenses.slices.allSatisfy { $0.percentText.hasSuffix("%") })
    #expect(expenses.chartLabel == "Expenses by category, October 2026")
  }

  @Test("R-HOME-3: picking a slice selects it and drills down to its category and month")
  func drillDown() async throws {
    let model = await model()
    await model.showPreviousMonth()
    let slice = try #require(model.expenses?.slices.first { $0.name == "Food" })
    let target = try #require(model.select(slice))
    #expect(target.categoryID == PreviewData.id(201))
    #expect(target.month == Month(year: 2026, month: 9))
    #expect(model.selectedSlice == slice.id)
    let query = DashboardDrillDown.query(categoryID: target.categoryID, month: target.month)
    #expect(query.fromDay == Day("2026-09-01"))
    #expect(query.toDay == Day("2026-09-30"))
    #expect(query.categoryIDs == [PreviewData.id(201)])
    await model.showNextMonth()
    #expect(model.selectedSlice == nil)
  }

  @Test("R-TX-4, R-SET-3: with refunds reducing spending the month's expenses drop by the refund")
  func refundSetting() async throws {
    let off = try #require(await model(currency: .PLN).expenses)
    let store = DashboardPreviewStore.previewData()
    try await store.settingsRepository.set(.refundsReduceSpending, "true")
    let on = try #require(await model(.preview(store: store, format: Self.format), currency: .PLN).expenses)
    #expect(off.total - on.total == money("120", .PLN))  // the Zalando refund
  }

  // MARK: Display currency, month selector, rates (R-HOME-4/5, R-FX-4)

  @Test("R-HOME-4: switching the display currency converts every widget")
  func displayCurrency() async throws {
    let model = await model()
    model.setDisplayCurrency(.EUR)
    let rates = RateTable(rates: PreviewData.fxRates, today: today)
    let expected = Calc.netWorth(accounts: PreviewData.accounts, txns: txns(), currency: .EUR, converter: rates)
    #expect(model.netWorth?.currency == .EUR)
    #expect(model.netWorth?.total == expected.total)
    #expect(model.expenses?.total.currency == .EUR)
    #expect(model.budget?.shownCurrency == .EUR)
    #expect(model.netWorth?.totalText.hasPrefix("€") == true)
  }

  @Test("R-HOME-5: the month selector stops at the current month and at the first month with data")
  func monthSelector() async throws {
    let model = await model()
    #expect(model.month == october)
    #expect(model.monthTitle == "October 2026")
    #expect(!model.canShowNextMonth)
    #expect(model.canShowPreviousMonth)
    await model.showNextMonth()
    #expect(model.month == october)
    await model.showPreviousMonth()
    #expect(model.month == Month(year: 2026, month: 9))
    #expect(model.earliestMonth == Month(year: 2026, month: 9))
    #expect(!model.canShowPreviousMonth)
    #expect(model.expenses?.month == Month(year: 2026, month: 9))
    #expect(model.budget?.month == Month(year: 2026, month: 9))
    await model.show(month: Month(year: 2020, month: 1))
    #expect(model.month == Month(year: 2026, month: 9))
  }

  @Test("R-FX-4: rates as of the latest day; a failed fetch shows the last-known-rates warning")
  func ratesAsOf() async throws {
    let fresh = await model()
    #expect(fresh.ratesText == "NBU rates as of Oct 21, 2026")
    #expect(fresh.ratesWarning == nil)
    let stale = await sample(fetchFailed: true)
    #expect(stale.ratesWarning == "Couldn't reach the rate service. Amounts use the last known rates, from Oct 21, 2026.")
  }

  @Test("A load failure is reported, not shown as zeros")
  func loadFailure() async throws {
    var dependencies = DashboardDependencies.preview(format: Self.format)
    dependencies.txns = FailingTxns()
    let model = await model(dependencies)
    guard case .failed(let message) = model.phase else {
      Issue.record("expected a failure, got \(model.phase)")
      return
    }
    #expect(message.hasPrefix("Couldn't load the dashboard"))
    #expect(model.netWorth == nil)
  }

  // MARK: Helpers

  func txns() -> [TxnWithLines] {
    let lines = Dictionary(grouping: PreviewData.attachedRecords, by: \.txnID)
    return PreviewData.txns.map { TxnWithLines(txn: $0, lines: lines[$0.id] ?? []) }
  }

  struct FailingTxns: TxnRepository {
    struct Failure: Error {}
    func transactions(matching query: TxnQuery) async throws -> [TxnWithLines] { throw Failure() }
    func save(_ txn: Txn, lines: [AttachedRecord]) async throws {}
    func delete(_ id: Txn.ID) async throws {}
  }
}

@Suite("Dashboard preview store")
struct DashboardPreviewStoreTests {
  @Test("R-LIST-2: a parent category matches its children; dates are inclusive")
  func query() async throws {
    let store = DashboardPreviewStore.previewData()
    let food = try await store.txnRepository.transactions(
      matching: TxnQuery(fromDay: Day("2026-10-01"), toDay: Day("2026-10-19"), categoryIDs: [PreviewData.id(201)]))
    #expect(food.map(\.txn.payee) == ["Biedronka", "Café du Parc", "Lidl"])
    let plan = try await store.budgetRepository.plan(for: Month(year: 2026, month: 10))
    #expect(plan?.plan.id == PreviewData.budgetPlan.id)
    #expect(plan?.allocations.count == PreviewData.budgetAllocations.count)
  }
}
