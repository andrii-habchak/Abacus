import AbacusDomain
import Foundation
import Testing

@Suite("N5 Forecast (R-REC-13…15, R-REC-9)")
struct ForecastEngineTests {
  let main = Fx.account(1, .PLN, .bank)
  let savings = Fx.account(2, .PLN, .savings)
  let usd = Fx.account(3, .USD, .bank)
  let card = Fx.account(4, .PLN, .creditCard, opening: -500_00)
  let today = Day("2026-11-03")!

  func item(
    _ type: TxnType = .expense, _ amount: Int64, on account: Account, start: String, unit: ScheduleUnit = .month,
    to: Account? = nil, toAmount: Int64? = nil, status: ScheduledItemStatus = .active
  ) -> ScheduledItem {
    ScheduledItem(
      type: type, accountID: account.id, toAccountID: to?.id, amountMinor: amount, toAmountMinor: toAmount, unit: unit,
      startDay: start, status: status)
  }

  func run(
    _ items: [ScheduledItem], accounts: [Account]? = nil, balances: [Account.ID: Int64]? = nil, horizon: Int = 90,
    resolved: Set<OccurrenceKey> = []
  ) -> Forecast {
    let accs = accounts ?? [main, savings, usd, card]
    return ForecastEngine.run(
      accounts: accs, balances: balances ?? [main.id: 1_000_00, savings.id: 5_000_00, usd.id: 200_00, card.id: -500_00],
      items: items, resolved: resolved, today: today, horizonDays: horizon)
  }

  @Test("R-REC-13: no items gives a flat line at today's balance")
  func flat() {
    let f = run([])
    #expect(f.days.count == 91)
    #expect(Set(f.balances[main.id]!) == [1_000_00])
    #expect(f.warnings.isEmpty)
  }

  @Test("R-REC-13: one monthly expense steps the balance on its days")
  func monthly() {
    let f = run([item(.expense, 100_00, on: main, start: "2026-01-15")])
    let s = f.series(for: main.id)
    #expect(s.first { $0.day.string == "2026-11-14" }?.valueMinor == 1_000_00)
    #expect(s.first { $0.day.string == "2026-11-15" }?.valueMinor == 900_00)
    #expect(s.first { $0.day.string == "2026-12-15" }?.valueMinor == 800_00)
    #expect(s.last?.valueMinor == 700_00)  // 15 Nov, 15 Dec, 15 Jan; the 90 days end on 1 Feb
  }

  @Test("R-REC-13: income adds; transfer moves money and leaves net worth flat")
  func incomeAndTransfer() {
    let f = run(
      [
        item(.income, 3_000_00, on: main, start: "2026-11-10", unit: .year),
        item(.transfer, 400_00, on: main, start: "2026-11-05", unit: .year, to: savings),
      ], horizon: 30)
    let expectedMain: Int64 = 1_000_00 + 3_000_00 - 400_00
    let expectedSavings: Int64 = 5_000_00 + 400_00
    #expect(f.series(for: main.id).last?.valueMinor == expectedMain)
    #expect(f.series(for: savings.id).last?.valueMinor == expectedSavings)
    let transferOnly = run([item(.transfer, 400_00, on: main, start: "2026-11-05", unit: .year, to: savings)], horizon: 30)
    let nw = transferOnly.netWorth { currency, value in currency == .PLN ? value : nil }
    #expect(Set(nw.points.map(\.valueMinor)).count == 1)
    #expect(nw.unconverted == [.USD])
  }

  @Test("R-REC-13: cross-currency transfer uses toAmount; liability card payment reduces the debt")
  func crossCurrencyAndLiability() {
    let f = run(
      [
        item(.transfer, 400_00, on: main, start: "2026-11-05", unit: .year, to: usd, toAmount: 100_00),
        item(.transfer, 200_00, on: main, start: "2026-11-06", unit: .year, to: card),
      ], horizon: 30)
    #expect(f.series(for: usd.id).last?.valueMinor == 300_00)
    #expect(f.series(for: card.id).last?.valueMinor == -300_00)
    let expectedMain: Int64 = 1_000_00 - 600_00
    #expect(f.series(for: main.id).last?.valueMinor == expectedMain)
  }

  @Test("R-REC-13: net worth converts with one flat rate for the whole horizon")
  func netWorthRates() {
    let f = run(
      [item(.expense, 100_00, on: usd, start: "2026-11-04", unit: .day)], accounts: [usd], balances: [usd.id: 1_000_00],
      horizon: 3)
    let nw = f.netWorth { currency, value in currency == .USD ? value * 4 : nil }
    #expect(nw.points.map(\.valueMinor) == [4_000_00, 3_600_00, 3_200_00, 2_800_00])
    #expect(nw.unconverted.isEmpty)
  }

  @Test("Archived accounts, paused/ended items and resolved occurrences are excluded")
  func exclusions() {
    let archived = Fx.account(5, .PLN, .bank, archived: true)
    let paused = item(.expense, 100_00, on: main, start: "2026-11-05", status: .paused)
    let ended = item(.expense, 100_00, on: main, start: "2026-11-05", status: .ended)
    let onArchived = item(.expense, 100_00, on: archived, start: "2026-11-05")
    let paid = item(.expense, 100_00, on: main, start: "2026-11-05")
    let f = run(
      [paused, ended, onArchived, paid], accounts: [main, archived], balances: [main.id: 1_000_00, archived.id: 0],
      horizon: 10, resolved: [OccurrenceKey(itemID: paid.id, day: Day("2026-11-05")!)])
    #expect(f.balances[archived.id] == nil)
    #expect(Set(f.balances[main.id]!) == [1_000_00])
    #expect(f.occurrences.isEmpty)
  }

  @Test("R-REC-9: overdue within grace counts on today; past grace is missed and excluded")
  func overdue() {
    let recent = item(.expense, 50_00, on: main, start: "2026-10-28", unit: .year)  // 6 days ago
    let old = item(.expense, 70_00, on: main, start: "2026-10-01", unit: .year)  // 33 days ago
    let f = run([recent, old], horizon: 5)
    #expect(f.occurrences.count == 1)
    #expect(f.occurrences[0].isOverdue)
    #expect(f.series(for: main.id).first?.valueMinor == 950_00)
    let missed = ScheduledOccurrences.missed(items: [recent, old], resolved: [], today: today)
    #expect(missed.map(\.item.id) == [old.id])
    #expect(missed.first?.day.string == "2026-10-01")
    let wide = ForecastEngine.run(
      accounts: [main], balances: [main.id: 1_000_00], items: [old], today: today, horizonDays: 5, graceDays: 40)
    #expect(wide.occurrences.count == 1)
  }

  @Test("R-REC-14: horizons 30/60/90 truncate; default is 90")
  func horizons() {
    for h in ForecastEngine.horizonChoices {
      let f = run([item(.expense, 1_00, on: main, start: "2026-11-04", unit: .day)], horizon: h)
      #expect(f.days.count == h + 1)
      #expect(f.series(for: main.id).last?.valueMinor == 1_000_00 - Int64(h) * 1_00)
    }
    #expect(ForecastEngine.defaultHorizonDays == 90)
  }

  @Test("R-REC-15: first day below zero with causing occurrences; none when never")
  func warnings() {
    let rent = item(.expense, 800_00, on: main, start: "2026-11-20")
    let salary = item(.income, 500_00, on: main, start: "2026-11-25", unit: .year)
    let f = run([rent, salary])
    let w = f.warnings
    #expect(w.count == 1)
    #expect(w[0].accountID == main.id)
    #expect(w[0].day.string == "2026-12-20")
    #expect(w[0].balanceMinor == 1_000_00 - 1_600_00 + 500_00)
    #expect(w[0].causes.contains { $0.itemID == rent.id })
    #expect(!w[0].causes.contains { $0.itemID == salary.id })
    #expect(run([item(.expense, 10_00, on: main, start: "2026-11-20")]).warnings.isEmpty)
    #expect(f.lowest(for: main.id)?.valueMinor == f.series(for: main.id).map(\.valueMinor).min())
  }

  @Test("R-REC-15: a liability going further negative is not warned about")
  func liabilityNotWarned() {
    let f = run([item(.expense, 900_00, on: card, start: "2026-11-05")])
    #expect(f.warnings.isEmpty)
  }

  @Test("R-REC-13 oracle: the forecast equals replaying the same items as real transactions")
  func oracle() {
    let items = [
      item(.expense, 49_99, on: main, start: "2026-01-15"),  // last due 19 days ago: past grace, not overdue
      item(.income, 2_500_00, on: main, start: "2026-11-10"),
      item(.transfer, 300_00, on: main, start: "2026-11-07", unit: .week, to: savings),
    ]
    let f = run(items)
    var expectedMain: [Int64] = []
    var expectedSavings: [Int64] = []
    var running: [Account.ID: Int64] = [main.id: 1_000_00, savings.id: 5_000_00]
    for day in f.days {
      for it in items {
        for _ in it.schedule!.occurrences(from: day, through: day) {
          let txn = Txn(
            type: it.type, occurredAt: Fx.date(day.string), accountID: it.accountID, amountMinor: it.amountMinor,
            toAccountID: it.toAccountID, toAmountMinor: it.toAmountMinor)
          for e in Calc.mainEffects(of: txn) { running[e.accountID, default: 0] += e.amountMinor }
        }
      }
      expectedMain.append(running[main.id]!)
      expectedSavings.append(running[savings.id]!)
    }
    #expect(f.balances[main.id] == expectedMain)
    #expect(f.balances[savings.id] == expectedSavings)
  }

  @Test("R-REC-21: 90 days, 30 accounts, 100 items is fast")
  func performance() {
    let accounts = (1...30).map { Fx.account($0, .PLN) }
    let items = (0..<100).map { i in
      item(.expense, 10_00, on: accounts[i % 30], start: "2026-0\(1 + i % 9)-\(10 + i % 18)", unit: i % 2 == 0 ? .month : .week)
    }
    let elapsed = ContinuousClock().measure {
      _ = ForecastEngine.run(accounts: accounts, balances: [:], items: items, today: today, horizonDays: 90)
    }
    #expect(elapsed < .milliseconds(500))
  }
}
