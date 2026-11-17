import AbacusDomain
import Foundation
import Testing

/// N5c: forecast vs actual overlay (R-REC-19, R-REC-13) and the accuracy panel (R-REC-20).
/// Synthetic data only.
@Suite("Forecast overlay and accuracy")
struct ForecastOverlayTests {
  static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
  static let bank = id(1)  // PLN
  static let card = id(2)  // EUR
  static let rent = id(10)
  static let salary = id(11)
  static let saving = id(12)
  static let phone = id(13)  // overdue at the snapshot day
  static let taken = Day("2026-11-01")!
  static let today = Day("2026-11-12")!
  static let rates = SnapshotRates(asOf: Day("2026-10-31"), base: .UAH, toBase: [.PLN: 10, .EUR: 45])

  static func snapshot(rates: SnapshotRates = rates, debts: [Currency: Int64] = [:]) -> ForecastSnapshotContent {
    let header = ForecastSnapshot(id: id(100), takenDay: taken.string, horizonDays: 30, startBalancesJSON: "", ratesJSON: "")
    let items = [
      ForecastSnapshotItem(snapshotID: header.id, itemID: phone, day: "2026-10-28", accountID: bank, amountMinor: -50_00),
      ForecastSnapshotItem(
        snapshotID: header.id, itemID: saving, day: "2026-11-03", accountID: bank, toAccountID: card, amountMinor: -100_00,
        toAmountMinor: 22_00),
      ForecastSnapshotItem(snapshotID: header.id, itemID: rent, day: "2026-11-05", accountID: bank, amountMinor: -300_00),
      ForecastSnapshotItem(snapshotID: header.id, itemID: salary, day: "2026-11-10", accountID: bank, amountMinor: 500_00),
      ForecastSnapshotItem(snapshotID: header.id, itemID: rent, day: "2026-12-05", accountID: bank, amountMinor: -300_00),
    ]
    let start = SnapshotStartBalances(
      accounts: [
        SnapshotAccountBalance(accountID: bank, currency: .PLN, isLiability: false, balanceMinor: 1_000_00),
        SnapshotAccountBalance(accountID: card, currency: .EUR, isLiability: false, balanceMinor: 100_00),
      ],
      debts: debts)
    return ForecastSnapshotContent(snapshot: header, start: start, rates: rates, items: items)
  }

  /// What happened: the transfer on 11-03, rent paid 310.00 on 11-06, groceries 40.00 on 11-08,
  /// phone and salary not paid.
  static func actual(from: Day = taken, through: Day = today, debts: [Day: [Currency: Int64]] = [:]) -> ActualDailyBalances {
    var days: [Day] = []
    var bankValues: [Int64] = []
    var cardValues: [Int64] = []
    var day = from
    while day <= through {
      var b: Int64 = 1_000_00
      var c: Int64 = 100_00
      if day >= Day("2026-11-03")! { b -= 100_00; c += 22_00 }
      if day >= Day("2026-11-06")! { b -= 310_00 }
      if day >= Day("2026-11-08")! { b -= 40_00 }
      days.append(day)
      bankValues.append(b)
      cardValues.append(c)
      day = day.plusDays(1)
    }
    return ActualDailyBalances(
      days: days, currencies: [bank: .PLN, card: .EUR], balances: [bank: bankValues, card: cardValues], debts: debts)
  }

  static let occurrences = [
    ScheduledOccurrence(
      itemID: saving, expectedDay: "2026-11-03", expectedAmountMinor: 100_00, status: .paid, actualDay: "2026-11-03",
      actualAmountMinor: 100_00),
    ScheduledOccurrence(
      itemID: rent, expectedDay: "2026-11-05", expectedAmountMinor: 300_00, status: .paid, actualDay: "2026-11-06",
      actualAmountMinor: 310_00),
  ]

  @Test("R-REC-19: account series — forecast from the snapshot, actual from daily balances, gap and split")
  func accountOverlay() throws {
    let overlay = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(), occurrences: Self.occurrences, selection: .account(Self.bank),
      today: Self.today))
    #expect(overlay.currency == .PLN)
    #expect(overlay.forecast.count == 31)
    // The overdue phone bill counts on the snapshot day (Q12).
    #expect(overlay.forecast[0].valueMinor == 950_00)
    #expect(overlay.forecast.first { $0.day == Day("2026-11-03")! }?.valueMinor == 850_00)
    #expect(overlay.forecast.first { $0.day == Day("2026-11-10")! }?.valueMinor == 1_050_00)
    #expect(overlay.forecast.last?.valueMinor == 1_050_00)  // 12-05 rent is past the horizon (12-01)
    // Actual equals the daily balances fed in.
    #expect(overlay.actual.map(\.valueMinor) == Self.actual().balances[Self.bank])
    #expect(overlay.gapDay == Self.today)
    #expect(overlay.actualAtGap == 550_00)
    #expect(overlay.forecastAtGap == 1_050_00)
    #expect(overlay.gapMinor == -500_00)
    let split = try #require(overlay.split)
    // Scheduled: forecast +50.00 (−50 −100 −300 +500), actual −410.00 → −460.00; the rest is groceries.
    #expect(split.scheduledMinor == -460_00)
    #expect(split.otherMinor == -40_00)
    #expect(split.scheduledMinor + split.otherMinor == overlay.gapMinor)
  }

  @Test("R-REC-19, R-REC-13: net worth at the snapshot's rates; transfers net out; split sums to the gap")
  func netWorthOverlay() throws {
    let overlay = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(), occurrences: Self.occurrences, selection: .netWorth(.PLN),
      today: Self.today))
    #expect(overlay.currency == .PLN && overlay.unconverted.isEmpty)
    // 1 EUR = 4.5 PLN at the stored rates. Start 1000 + 450 − 50 (phone) = 1400.
    #expect(overlay.forecast[0].valueMinor == 1_400_00)
    // Transfer day: −100 PLN, +22 EUR (99 PLN).
    #expect(overlay.forecast.first { $0.day == Day("2026-11-03")! }?.valueMinor == 1_399_00)
    #expect(overlay.actualAtGap == 1_099_00)  // 550 + 122 EUR × 4.5
    #expect(overlay.forecastAtGap == 1_599_00)
    let split = try #require(overlay.split)
    #expect(split.scheduledMinor == -460_00)
    #expect(split.otherMinor == -40_00)
    #expect(split.scheduledMinor + split.otherMinor == overlay.gapMinor)
    // Other display currency: same picture at the same stored rates (UAH = 10 × PLN).
    let uah = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(), occurrences: Self.occurrences, selection: .netWorth(.UAH),
      today: Self.today))
    #expect(uah.gapMinor == -5_000_00)
  }

  @Test("R-REC-19: only the stored rates count — a later rate does not move the overlay")
  func storedRatesOnly() throws {
    let before = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(), occurrences: Self.occurrences, selection: .netWorth(.PLN),
      today: Self.today))
    // A rate moved since: today's converter would say EUR 50. The overlay never asks it, so a
    // snapshot rebuilt from JSON gives the identical result.
    let json = try SnapshotJSON.encode(Self.rates)
    var reloaded = Self.snapshot()
    reloaded.rates = try SnapshotJSON.decode(SnapshotRates.self, json)
    let after = try #require(ForecastOverlay.make(
      snapshot: reloaded, actual: Self.actual(), occurrences: Self.occurrences, selection: .netWorth(.PLN), today: Self.today))
    #expect(before.forecast == after.forecast && before.actual == after.actual && before.gapMinor == after.gapMinor)
    // A currency without a stored rate is left out on both sides and named.
    let noEUR = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(rates: SnapshotRates(asOf: nil, base: .UAH, toBase: [.PLN: 10])), actual: Self.actual(),
      occurrences: Self.occurrences, selection: .netWorth(.PLN), today: Self.today))
    #expect(noEUR.unconverted == [.EUR])
    #expect(noEUR.gapMinor == -500_00)
    #expect(noEUR.split?.scheduledMinor == -360_00 - 100_00)
  }

  @Test("R-REC-13: debt terms count in net worth, held at the snapshot's value in the forecast")
  func debts() throws {
    let overlay = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(debts: [.EUR: 10_00]),
      actual: Self.actual(debts: [Self.today: [.EUR: 10_00]]), occurrences: Self.occurrences, selection: .netWorth(.PLN),
      today: Self.today))
    #expect(overlay.forecast[0].valueMinor == 1_445_00)
    #expect(overlay.forecast.last?.valueMinor == 1_644_00)  // 1050 + 549 + 10 EUR debt
    #expect(overlay.gapMinor == -500_00)
    // Debts never enter an account series.
    let account = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(debts: [.EUR: 10_00]), actual: Self.actual(), occurrences: [], selection: .account(Self.bank),
      today: Self.today))
    #expect(account.forecast[0].valueMinor == 950_00)
  }

  @Test("R-REC-19: snapshot older than the data or the horizon — clamped")
  func clamped() throws {
    // Data only from 11-04.
    let late = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(from: Day("2026-11-04")!), occurrences: Self.occurrences,
      selection: .account(Self.bank), today: Self.today))
    #expect(late.actual.first?.day == Day("2026-11-04")!)
    #expect(late.gapMinor == -500_00)
    // Today after the horizon end (2026-12-01): the gap is measured at the horizon end.
    let old = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(through: Day("2026-12-15")!), occurrences: Self.occurrences,
      selection: .account(Self.bank), today: Day("2026-12-15")!))
    #expect(old.gapDay == Day("2026-12-01")!)
    #expect(old.actual.last?.day == Day("2026-12-15")!)
    #expect(old.forecastAtGap == 1_050_00)
    // Data entirely before the snapshot: no actual line, no gap.
    let none = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(from: Day("2026-10-01")!, through: Day("2026-10-31")!),
      occurrences: [], selection: .account(Self.bank), today: Self.today))
    #expect(none.actual.isEmpty && none.gapMinor == nil && none.split == nil)
  }

  @Test("R-REC-19: a paid occurrence before the snapshot day or after the gap day is not counted as happened")
  func paidOutsideWindow() throws {
    let early = ScheduledOccurrence(
      itemID: Self.phone, expectedDay: "2026-10-28", expectedAmountMinor: 50_00, status: .paid, actualDay: "2026-11-01",
      actualAmountMinor: 50_00)
    let overlay = try #require(ForecastOverlay.make(
      snapshot: Self.snapshot(), actual: Self.actual(through: Day("2026-11-04")!), occurrences: Self.occurrences + [early],
      selection: .account(Self.bank), today: Day("2026-11-04")!))
    // Through 11-04: forecast −50 (phone) −100 (transfer); actual −100 (transfer, the phone on the
    // snapshot day is already in the start balance; rent paid later is not yet).
    #expect(overlay.split?.scheduledMinor == 50_00)
    #expect(overlay.gapMinor == 50_00)
    #expect(overlay.split?.otherMinor == 0)
  }

  // MARK: Accuracy (R-REC-20)

  static let template = ScheduledItem(
    id: rent, type: .expense, accountID: bank, amountMinor: 100_00, payee: "Rent", startDay: "2026-01-05")

  static func paid(_ day: String, _ actualDay: String, _ amount: Int64, expected: Int64 = 100_00) -> ScheduledOccurrence {
    ScheduledOccurrence(
      itemID: rent, expectedDay: day, expectedAmountMinor: expected, status: .paid, actualDay: actualDay,
      actualAmountMinor: amount)
  }

  @Test("R-REC-20: per-item expected vs actual day and amount, counts, on-time share, average deviation")
  func accuracyRows() throws {
    let occurrences = [
      Self.paid("2026-01-05", "2026-01-07", 103_10),
      Self.paid("2026-02-05", "2026-02-04", 100_00),
      ScheduledOccurrence(itemID: Self.rent, expectedDay: "2026-03-05", expectedAmountMinor: 100_00, status: .skipped),
      ScheduledOccurrence(itemID: Self.rent, expectedDay: "2026-04-05", expectedAmountMinor: 100_00, status: .missed),
    ]
    let report = ForecastAccuracy.report(items: [Self.template], occurrences: occurrences)
    let row = try #require(report.items.first)
    #expect(row.item?.payee == "Rent")
    #expect(row.rows.map(\.dayDelta) == [2, -1, nil, nil])
    #expect(row.rows.map(\.amountDeltaMinor) == [3_10, 0, nil, nil])
    #expect(abs((row.rows[0].amountDeltaPercent ?? 0) - 3.1) < 0.0001)
    #expect(row.summary.paid == 2 && row.summary.skipped == 1 && row.summary.missed == 1)
    #expect(row.summary.onTimeShare == 0.5)
    #expect(abs((row.summary.averageAbsDeviationPercent ?? 0) - 1.55) < 0.0001)
    #expect(row.suggestedAmountMinor == nil)
    #expect(report.overall == row.summary)
  }

  @Test("R-REC-20: \"Update amount to X\" after three drifting payments, not before")
  func updateAmount() {
    let drifting = [
      Self.paid("2026-01-05", "2026-01-05", 100_00),
      Self.paid("2026-02-05", "2026-02-05", 105_00),
      Self.paid("2026-03-05", "2026-03-05", 106_00),
      Self.paid("2026-04-05", "2026-04-05", 107_00),
    ]
    #expect(ForecastAccuracy.suggestedAmount(template: 100_00, occurrences: drifting) == 107_00)
    // Two drifting payments are not enough; one within 2 % breaks the run; a cheaper price counts too.
    #expect(ForecastAccuracy.suggestedAmount(template: 100_00, occurrences: Array(drifting.prefix(3))) == nil)
    #expect(ForecastAccuracy.suggestedAmount(
      template: 100_00, occurrences: drifting + [Self.paid("2026-05-05", "2026-05-05", 101_50)]) == nil)
    #expect(ForecastAccuracy.suggestedAmount(
      template: 100_00,
      occurrences: [
        Self.paid("2026-01-05", "2026-01-05", 90_00), Self.paid("2026-02-05", "2026-02-05", 90_00),
        Self.paid("2026-03-05", "2026-03-05", 90_00),
      ]) == 90_00)
    // Exactly 2 % is not "more than 2 %".
    #expect(ForecastAccuracy.suggestedAmount(
      template: 100_00,
      occurrences: (1...3).map { Self.paid("2026-0\($0)-05", "2026-0\($0)-05", 102_00) }) == nil)
    let report = ForecastAccuracy.report(items: [Self.template], occurrences: drifting)
    #expect(report.items.first?.suggestedAmountMinor == 107_00)
  }

  @Test("R-REC-20: scope by a snapshot's period vs all time; works without snapshots; deleted items keep rows")
  func scope() throws {
    let occurrences = [
      Self.paid("2026-01-05", "2026-01-05", 100_00),
      Self.paid("2026-11-05", "2026-11-08", 100_00),
      ScheduledOccurrence(itemID: Self.id(99), expectedDay: "2026-11-02", expectedAmountMinor: 20_00, status: .missed),
    ]
    let all = ForecastAccuracy.report(items: [Self.template], occurrences: occurrences)
    #expect(all.items.count == 2)
    #expect(all.overall.paid == 2 && all.overall.missed == 1)
    let deleted = try #require(all.items.first { $0.itemID == Self.id(99) })
    #expect(deleted.item == nil)
    let period = ForecastAccuracy.report(
      items: [Self.template], occurrences: occurrences, period: Self.taken...Self.today)
    #expect(period.overall.paid == 1)
    #expect(period.items.first { $0.itemID == Self.rent }?.rows.map(\.dayDelta) == [3])
    #expect(period.overall.onTimeShare == 0)
    #expect(ForecastAccuracy.report(items: [Self.template], occurrences: []).items.isEmpty)
  }
}
