import AbacusDomain
import Foundation
import Testing

@Suite("Calc: budget status and event totals")
struct CalcBudgetTests {
  let pln = Fx.account(1, .PLN)
  let eur = Fx.account(2, .EUR)
  let food = Fx.category(10)
  let groceries = Fx.category(11, parent: 10)
  let eatingOut = Fx.category(12, parent: 10)
  let rent = Fx.category(20)
  let transport = Fx.category(30)
  let health = Fx.category(40)
  let fees = Fx.category(50)
  var categories: [AbacusDomain.Category] { [food, groceries, eatingOut, rent, transport, health, fees] }

  var converter: FakeConverter {
    FakeConverter([("2026-09-01", .EUR, .PLN, "4.00"), ("2026-10-15", .EUR, .PLN, "4.50")], latest: [(.EUR, .PLN, "4.50")])
  }

  let planJan = BudgetPlan(id: Fx.id(900), effectiveMonth: "2026-01", totalMinor: 5_000_00, currency: .PLN)
  let planOct = BudgetPlan(id: Fx.id(901), effectiveMonth: "2026-10", totalMinor: 3_000_00, currency: .PLN)
  var plans: [BudgetPlan] { [planOct, planJan] }
  var allocations: [BudgetAllocation] {
    [
      BudgetAllocation(planID: planJan.id, categoryID: rent.id, limitMinor: 4_000_00),
      BudgetAllocation(planID: planOct.id, categoryID: transport.id, limitMinor: 100_00),
      BudgetAllocation(planID: planOct.id, categoryID: rent.id, limitMinor: 2_000_00),
      BudgetAllocation(planID: planOct.id, categoryID: food.id, limitMinor: 500_00),
      BudgetAllocation(planID: planOct.id, categoryID: eatingOut.id, limitMinor: 100_00),
      BudgetAllocation(planID: planOct.id, categoryID: health.id, limitMinor: 200_00),
    ]
  }

  var octoberTxns: [TxnWithLines] {
    [
      Fx.expense(2_000_00, pln, on: "2026-10-01", category: rent),
      Fx.expense(300_00, pln, on: "2026-10-02", category: groceries),  // → Food
      Fx.expense(150_00, pln, on: "2026-10-03", category: food),  // → Food
      Fx.expense(95_00, pln, on: "2026-10-04", category: eatingOut, lines: [Fx.line(10_00, category: fees)]),  // → Eating out; fee → other
      Fx.expense(10_00, eur, on: "2026-10-05", category: transport),  // 40.00
      Fx.expense(10_00, eur, on: "2026-10-16", category: transport),  // 45.00
      Fx.expense(50_00, pln, on: "2026-10-07"),  // uncategorized → other
      Fx.expense(40_00, pln, on: "2026-10-08", category: groceries, refund: true),
      Fx.income(9_000_00, pln, on: "2026-10-09"),
      Fx.transfer(500_00, from: pln, to: eur, received: 110_00, on: "2026-10-10"),
      Fx.expense(777_00, pln, on: "2026-09-30", category: rent),
    ]
  }

  func status(month: String = "2026-10", refunds: Bool = false, txns: [TxnWithLines]? = nil) -> BudgetStatus? {
    Calc.budgetStatus(
      month: Month(month)!, plans: plans, allocations: allocations, accounts: [pln, eur],
      categories: categories, txns: txns ?? octoberTxns, converter: converter,
      refundsReduceSpending: refunds, today: Day("2026-10-21")!, calendar: Fx.calendar)
  }

  @Test("R-BUD-3: the plan in effect is the latest with effectiveMonth ≤ month")
  func planInEffect() {
    #expect(Calc.planInEffect(for: Month("2026-09")!, plans: plans) == planJan)
    #expect(Calc.planInEffect(for: Month("2026-10")!, plans: plans) == planOct)
    #expect(Calc.planInEffect(for: Month("2027-03")!, plans: plans) == planOct)
    #expect(Calc.planInEffect(for: Month("2025-12")!, plans: plans) == nil)
    #expect(status(month: "2025-12") == nil)
  }

  @Test("R-BUD-3: past months keep their plan's limits")
  func pastMonthKeepsLimits() throws {
    let sept = try #require(status(month: "2026-09"))
    #expect(sept.plan == planJan)
    #expect(sept.lines.map(\.limit.minorUnits) == [4_000_00])
    #expect(sept.lines.first?.spent.minorUnits == 777_00)
    #expect(sept.daysLeft == 0)
  }

  @Test("R-BUD-1, R-BUD-2: spent per allocation; a parent's limit covers its children; a child's own limit wins")
  func spentPerAllocation() throws {
    let s = try #require(status())
    #expect(s.lines.map(\.categoryID) == [food.id, eatingOut.id, rent.id, transport.id, health.id])
    let spent = Dictionary(uniqueKeysWithValues: s.lines.map { ($0.categoryID!, $0.spent.minorUnits) })
    #expect(spent[food.id] == 450_00)
    #expect(spent[eatingOut.id] == 95_00)
    #expect(spent[rent.id] == 2_000_00)
    #expect(spent[transport.id] == 85_00)
    #expect(spent[health.id] == 0)
  }

  @Test("R-BUD-1: unallocated = total − limits, spent = other categories (attached fees, uncategorized)")
  func unallocated() throws {
    let s = try #require(status())
    #expect(s.unallocated.isUnallocated)
    #expect(s.unallocated.limit.minorUnits == 3_000_00 - 2_900_00)
    #expect(s.unallocated.spent.minorUnits == 10_00 + 50_00)
    #expect(s.unallocated.status == .ok)  // 60 %
  }

  @Test("R-HOME-2: totals, remaining, % used and days left")
  func totals() throws {
    let s = try #require(status())
    #expect(s.limit.minorUnits == 3_000_00)
    #expect(s.spent.minorUnits == 2_000_00 + 450_00 + 95_00 + 85_00 + 60_00)
    #expect(s.remaining.minorUnits == 3_000_00 - 2_690_00)
    #expect(s.fractionUsed == Decimal(2_690_00) / Decimal(3_000_00))
    #expect(s.status == .ok)
    #expect(s.daysLeft == 10)
    #expect(s.unconverted.isEmpty)
  }

  @Test("R-HOME-2: over the limit is over, ≥ 90 % is near")
  func statuses() throws {
    let s = try #require(status())
    let byCategory = Dictionary(uniqueKeysWithValues: s.lines.map { ($0.categoryID!, $0.status) })
    #expect(byCategory[rent.id] == .near)  // 100 %
    #expect(byCategory[eatingOut.id] == .near)  // 95 %
    #expect(byCategory[food.id] == .near)  // 450 / 500 = 90 %
    #expect(byCategory[transport.id] == .ok)  // 85 %
    #expect(byCategory[health.id] == .ok)
    #expect(s.overCount == 0)
    #expect(Calc.limitStatus(spentMinor: 101, limitMinor: 100) == .over)
    #expect(Calc.limitStatus(spentMinor: 100, limitMinor: 100) == .near)
    #expect(Calc.limitStatus(spentMinor: 89, limitMinor: 100) == .ok)
    #expect(Calc.limitStatus(spentMinor: 1, limitMinor: 0) == .over)
    #expect(Calc.limitStatus(spentMinor: 0, limitMinor: 0) == .ok)
  }

  @Test("R-HOME-2: categories over their limit are counted, the unallocated row included")
  func overCount() throws {
    let extra = octoberTxns + [Fx.expense(1_00, pln, on: "2026-10-20", category: rent), Fx.expense(100_00, pln, on: "2026-10-20")]
    let s = try #require(status(txns: extra))
    #expect(s.lines.first { $0.categoryID == rent.id }?.status == .over)
    #expect(s.lines.first { $0.categoryID == rent.id }?.remaining.minorUnits == -1_00)
    #expect(s.unallocated.status == .over)
    #expect(s.overCount == 2)
  }

  @Test("R-BUD-2, R-SET-3: refunds lower spending only with the setting on")
  func refundsBySetting() throws {
    #expect(try #require(status(refunds: false)).lines.first?.spent.minorUnits == 450_00)
    #expect(try #require(status(refunds: true)).lines.first?.spent.minorUnits == 410_00)
  }

  @Test("R-BUD-2, R-SET-3 (D22): a refund line lowers its category only with the setting on")
  func refundLineBySetting() throws {
    let txns = [Fx.expense(300_00, pln, on: "2026-10-02", category: groceries, lines: [Fx.line(20_00, .income, category: groceries)])]
    #expect(try #require(status(refunds: false, txns: txns)).lines.first?.spent.minorUnits == 300_00)
    #expect(try #require(status(refunds: true, txns: txns)).lines.first?.spent.minorUnits == 280_00)
  }

  @Test("R-HOME-2: days left — 0 for past months, all days for future months")
  func daysLeft() {
    let today = Day("2026-10-21")!
    #expect(Calc.daysLeft(in: Month("2026-10")!, today: today, calendar: Fx.calendar) == 10)
    #expect(Calc.daysLeft(in: Month("2026-09")!, today: today, calendar: Fx.calendar) == 0)
    #expect(Calc.daysLeft(in: Month("2026-11")!, today: today, calendar: Fx.calendar) == 30)
  }

  @Test("R-BUD-2, R-FX-3: a budget expense without a rate is skipped and counted")
  func budgetMissingRate() throws {
    let usd = Fx.account(3, .USD)
    let s = try #require(Calc.budgetStatus(
      month: Month("2026-10")!, plans: plans, allocations: allocations, accounts: [pln, usd],
      categories: categories, txns: [Fx.expense(10_00, usd, on: "2026-10-05", category: rent)], converter: converter,
      refundsReduceSpending: false, today: Day("2026-10-21")!, calendar: Fx.calendar))
    #expect(s.spent.minorUnits == 0)
    #expect(s.unconverted.count == 1)
  }

  // MARK: Events

  @Test("R-EVT-3: event spent in the display currency and by category")
  func eventTotals() throws {
    let trip = Event(id: Fx.id(700), name: "Trip", budgetMinor: 100_00, budgetCurrency: .EUR)
    let txns = [
      Fx.expense(10_00, eur, on: "2026-10-05", category: eatingOut, event: trip),  // 40.00 PLN, 10 EUR
      Fx.expense(90_00, pln, on: "2026-10-16", category: groceries, event: trip, lines: [Fx.line(9_00, category: fees)]),  // 90 + 9 PLN = 22 EUR
      Fx.expense(20_00, eur, on: "2026-10-16", category: transport, event: trip),  // 90.00 PLN
      Fx.income(5_00, eur, on: "2026-10-16", event: trip),
      Fx.expense(999_00, pln, on: "2026-10-16", category: groceries),  // not in the event
    ]
    let result = Calc.eventTotals(
      event: trip, accounts: [pln, eur], categories: categories, txns: txns, currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.txnCount == 4)
    #expect(result.spent.minorUnits == 40_00 + 90_00 + 9_00 + 90_00)
    #expect(result.byCategory.map(\.key) == [.category(food.id), .category(transport.id), .category(fees.id)])
    #expect(result.byCategory.first?.total.minorUnits == 130_00)
    #expect(result.byCategory.first?.children.map(\.key) == [.category(groceries.id), .category(eatingOut.id)])
    #expect(result.budget == Money(minorUnits: 100_00, currency: .EUR))
    #expect(result.spentInBudgetCurrency == Money(minorUnits: 10_00 + 22_00 + 20_00, currency: .EUR))
    #expect(result.budgetStatus == .ok)
    #expect(result.unconverted.isEmpty)
  }

  @Test("R-EVT-3: an event without a budget has no budget status")
  func eventWithoutBudget() {
    let move = Event(id: Fx.id(701), name: "Move")
    let result = Calc.eventTotals(
      event: move, accounts: [pln], categories: categories, txns: [Fx.expense(5_00, pln, on: "2026-10-05", event: move)],
      currency: .PLN, converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.spent.minorUnits == 5_00)
    #expect(result.byCategory.map(\.key) == [.uncategorized])
    #expect(result.budget == nil && result.spentInBudgetCurrency == nil && result.budgetStatus == nil)
  }
}
