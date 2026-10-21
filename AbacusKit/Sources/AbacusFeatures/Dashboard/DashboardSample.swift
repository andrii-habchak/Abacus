import AbacusDomain
import AbacusFX
import Foundation

/// `PreviewData` stretched over a full synthetic year for the dashboard's previews and
/// screenshots: accounts opened in October 2025, a salary, rent, groceries and the like every
/// month from November 2025 to September 2026, month-start and month-end rates, an August
/// over budget (three categories over) and a September near it. Never real data (R-NF-6).
public enum DashboardSample {
  static let openingDay = "2025-10-01"
  static let firstMonth = Month(year: 2025, month: 11)
  static let lastMonth = Month(year: 2026, month: 9)

  /// The preview accounts, opened a year earlier.
  public static var accounts: [Account] {
    PreviewData.accounts.map { account in
      var account = account
      if !account.isArchived { account.openingDate = PreviewData.at(openingDay) }
      return account
    }
  }

  /// One month's synthetic flows (amounts in minor units of the account's currency).
  struct MonthPlan {
    var groceries: [Int64]
    var eatingOut: Int64
    var fuel: Int64
    var taxi: Int64
    var health: Int64
    var travel: Int64 = 0
  }

  static func plan(for month: Month) -> MonthPlan {
    switch (month.year, month.month) {
    case (2026, 8): MonthPlan(groceries: [640_00, 710_00, 600_00], eatingOut: 720_00, fuel: 180_00, taxi: 60_00, health: 120_00, travel: 2_400_00)
    case (2026, 9): MonthPlan(groceries: [520_00, 480_00, 500_00], eatingOut: 520_00, fuel: 0, taxi: 45_00, health: 90_00)
    case (2026, 3): MonthPlan(groceries: [560_00, 540_00, 610_00], eatingOut: 380_00, fuel: 170_00, taxi: 40_00, health: 310_00, travel: 1_200_00)
    default:
      MonthPlan(
        groceries: [520_00 + Int64(month.month) * 9_00, 560_00, 590_00], eatingOut: 410_00 + Int64(month.month % 4) * 25_00,
        fuel: 175_00, taxi: 35_00, health: 150_00)
    }
  }

  /// Transactions before `PreviewData`'s own (which cover late September and October).
  public static var extraTxns: [Txn] {
    var txns: [Txn] = []
    var n = 10_000
    func add(_ type: TxnType, _ day: String, _ payee: String, _ account: Account, _ minor: Int64, cat: Int? = nil,
             to: Account? = nil, received: Int64? = nil) {
      n += 1
      txns.append(Txn(
        id: PreviewData.id(n), type: type, occurredAt: PreviewData.at(day), accountID: account.id, amountMinor: minor,
        categoryID: cat.map(PreviewData.id), toAccountID: to?.id, toAmountMinor: received, payee: payee,
        createdAt: PreviewData.at(day)))
    }
    var month = firstMonth
    while month <= lastMonth {
      let p = plan(for: month)
      let m = month.string
      add(.income, "\(m)-10", "Salary", PreviewData.revolutEUR, 2_300_00, cat: 251)
      add(.transfer, "\(m)-11", "To PLN account", PreviewData.revolutEUR, 1_600_00, to: PreviewData.pkoPersonal, received: 6_900_00)
      add(.expense, "\(m)-12", "Rent \(m)", PreviewData.pkoPersonal, 4_000_00, cat: 205)
      for (index, amount) in p.groceries.enumerated() {
        add(.expense, "\(m)-\(String(format: "%02d", 4 + index * 9))", ["Lidl", "Biedronka", "Auchan"][index], PreviewData.pkoPersonal, amount, cat: 202)
      }
      add(.expense, "\(m)-17", "Restaurant", PreviewData.pkoPersonal, p.eatingOut, cat: 203)
      if p.fuel > 0 { add(.expense, "\(m)-08", "Orlen", PreviewData.pkoCreditCard, p.fuel, cat: 208) }
      add(.expense, "\(m)-19", "Bolt", PreviewData.pkoPersonal, p.taxi, cat: 207)
      add(.expense, "\(m)-14", "Pharmacy", PreviewData.pkoPersonal, p.health, cat: 209)
      add(.expense, "\(m)-20", "Electricity", PreviewData.pkoPersonal, 470_00, cat: 210)
      add(.expense, "\(m)-08", "Orange", PreviewData.pkoPersonal, 35_00, cat: 211)
      if p.travel > 0 { add(.expense, "\(m)-24", "Flights", PreviewData.pkoPersonal, p.travel, cat: 214) }
      if p.fuel > 0 { add(.transfer, "\(m)-25", "Card repayment", PreviewData.pkoPersonal, p.fuel, to: PreviewData.pkoCreditCard, received: p.fuel) }
      month = month.adding(months: 1)
    }
    return txns
  }

  /// UAH per unit at each month start and end, October 2025 to September 2026 (synthetic,
  /// drifting towards `PreviewData`'s October rates).
  public static var extraRates: [FXRate] {
    let path: [(Currency, [String])] = [
      (.PLN, ["10.62", "10.70", "10.66", "10.75", "10.81", "10.78", "10.90", "10.96", "11.05", "11.02", "11.12", "11.20"]),
      (.EUR, ["45.80", "46.10", "46.02", "46.40", "46.75", "46.60", "47.05", "47.30", "47.62", "47.50", "47.95", "48.20"]),
      (.USD, ["41.25", "41.40", "41.32", "41.10", "41.05", "41.18", "41.30", "41.22", "41.45", "41.38", "41.50", "41.55"]),
    ]
    var rates: [FXRate] = []
    var n = 9_000
    var month = Month(year: 2025, month: 10)
    for index in 0..<12 {
      for day in [month.firstDay, month.lastDay()] where day < Day(year: 2026, month: 9, day: 22) {
        for (currency, values) in path {
          n += 1
          rates.append(FXRate(
            id: PreviewData.id(n), day: day.string, base: currency, quote: .UAH,
            rateE8: RateScale.scaled(Decimal(string: values[index])!), provider: "NBU", fetchedAt: PreviewData.at(day.string)))
        }
      }
      month = month.adding(months: 1)
    }
    return rates
  }

  public static func store() -> DashboardPreviewStore {
    DashboardPreviewStore(
      accounts: accounts, categories: PreviewData.categories, txns: extraTxns + PreviewData.txns,
      attachedRecords: PreviewData.attachedRecords, plans: [PreviewData.budgetPlan],
      allocations: PreviewData.budgetAllocations, settings: PreviewData.settings)
  }

  public static func rateTable() -> RateTable {
    RateTable(rates: extraRates + PreviewData.fxRates, today: PreviewData.today)
  }
}
