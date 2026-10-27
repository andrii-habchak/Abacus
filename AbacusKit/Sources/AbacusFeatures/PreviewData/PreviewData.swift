import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Synthetic data for SwiftUI previews, UI lanes on mock data, and tests. Mirrors the approved
/// prototypes (docs/design/). Never real data (R-NF-6). IDs are deterministic.
public enum PreviewData {
  /// "Today" in the preview world.
  public static let today = Day(year: 2026, month: 10, day: 21)

  public static func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  static func at(_ day: String, _ time: String = "12:00") -> Date {
    let d = Day(day)!
    let hm = time.split(separator: ":").compactMap { Int($0) }
    return Calendar.current.date(
      from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hm[0], minute: hm[1])
    )!
  }

  // MARK: Accounts

  public static let monobank = Account(
    id: id(101), name: "Monobank Black", currency: .UAH, kind: .card,
    openingBalanceMinor: 52_000_00, openingDate: at("2026-01-01"), groupName: "Monobank", colorHex: "#2E9E4F", position: 0)
  public static let pkoPersonal = Account(
    id: id(102), name: "PKO Personal", currency: .PLN, kind: .bank,
    openingBalanceMinor: 19_800_00, openingDate: at("2026-01-01"), iban: "PL00000000000000000000000001",
    groupName: "PKO", colorHex: "#0A64D6", position: 1)
  public static let pkoUSD = Account(
    id: id(103), name: "PKO USD", currency: .USD, kind: .bank,
    openingBalanceMinor: 3_000_00, openingDate: at("2026-01-01"), iban: "PL00000000000000000000000002",
    groupName: "PKO", colorHex: "#7A9E1F", position: 2)
  public static let pkoCreditCard = Account(
    id: id(104), name: "PKO Credit Card", currency: .PLN, kind: .creditCard,
    openingBalanceMinor: -1_030_00, openingDate: at("2026-01-01"), groupName: "PKO", colorHex: "#E5484D", position: 3)
  public static let revolutEUR = Account(
    id: id(105), name: "Revolut EUR", currency: .EUR, kind: .card,
    openingBalanceMinor: -886_00, openingDate: at("2026-01-01"), groupName: "Revolut", colorHex: "#4F5BD5", position: 4)
  public static let cashPLN = Account(
    id: id(106), name: "Cash PLN", currency: .PLN, kind: .cash,
    openingBalanceMinor: 0, openingDate: at("2026-01-01"), colorHex: "#C99A00", position: 5)
  public static let eurDeposit = Account(
    id: id(107), name: "EUR Deposit", currency: .EUR, kind: .savings,
    openingBalanceMinor: 5_000_00, openingDate: at("2026-01-01"), colorHex: "#0F96B0", position: 6)
  public static let loanFromFriend = Account(
    id: id(108), name: "Loan from friend", currency: .UAH, kind: .debt,
    openingBalanceMinor: -8_000_00, openingDate: at("2026-01-01"), colorHex: "#B04BC4", position: 7)
  public static let oldCard = Account(
    id: id(109), name: "Old card", currency: .UAH, kind: .card,
    openingBalanceMinor: 0, openingDate: at("2025-01-01"), colorHex: "#A35A2A", position: 8, isArchived: true)

  public static let accounts = [
    monobank, pkoPersonal, pkoUSD, pkoCreditCard, revolutEUR, cashPLN, eurDeposit, loanFromFriend, oldCard,
  ]

  // MARK: Categories

  static func cat(_ n: Int, _ name: String, _ kind: CategoryKind = .expense, parent: Int? = nil, color: String) -> AbacusDomain.Category {
    AbacusDomain.Category(id: id(n), name: name, kind: kind, parentID: parent.map(id), colorHex: color, position: n)
  }

  public static let categories: [AbacusDomain.Category] = [
    cat(201, "Food", color: "#E07B14"),
    cat(202, "Groceries", parent: 201, color: "#7A9E1F"),
    cat(203, "Eating out", parent: 201, color: "#1E9E7E"),
    cat(204, "Housing", color: "#0A64D6"),
    cat(205, "Rent", parent: 204, color: "#B04BC4"),
    cat(206, "Transport", color: "#7B4FCF"),
    cat(207, "Taxi", parent: 206, color: "#C99A00"),
    cat(208, "Fuel", parent: 206, color: "#E5484D"),
    cat(209, "Health", color: "#C93B6E"),
    cat(210, "Bills", color: "#0F96B0"),
    cat(211, "Mobile", parent: 210, color: "#4F5BD5"),
    cat(212, "Clothing", color: "#A35A2A"),
    cat(213, "Fees", color: "#D4703C"),
    cat(214, "Travel", color: "#C99A00"),
    cat(251, "Salary", .income, color: "#2E9E4F"),
    cat(252, "Cashback", .income, color: "#1E9E7E"),
    cat(253, "Refunds", .income, color: "#0A64D6"),
  ]

  // MARK: Events

  public static let lyonTrip = Event(
    id: id(301), name: "Lyon trip", startDay: "2026-10-01", endDay: "2026-10-19", colorHex: "#7B4FCF")
  public static let relocation = Event(id: id(302), name: "Relocation", colorHex: "#1E9E7E")
  public static let events = [lyonTrip, relocation]

  // MARK: Transactions

  static func expense(
    _ n: Int, _ day: String, _ time: String, _ payee: String, cat: Int, _ account: Account,
    _ minor: Int64, refund: Bool = false, pending: Bool = false, event: Event? = nil, note: String = "",
    original: (Int64, String)? = nil, source: TxnSource = .manual
  ) -> Txn {
    Txn(
      id: id(n), type: .expense, occurredAt: at(day, time), accountID: account.id, amountMinor: minor,
      categoryID: id(cat), isRefund: refund, originalAmountMinor: original?.0,
      originalCurrencyCode: original?.1, payee: payee, note: note, eventID: event?.id, source: source,
      isPendingAtBank: pending, createdAt: at(day, time))
  }

  public static let txns: [Txn] = [
    expense(401, "2026-10-21", "15:07", "Bolt", cat: 207, pkoPersonal, 23_40, pending: true, source: .pko),
    expense(402, "2026-10-21", "12:41", "City Pharmacy", cat: 209, pkoPersonal, 31_20, pending: true, source: .pko),
    Txn(
      id: id(403), type: .transfer, occurredAt: at("2026-10-20", "18:02"), accountID: pkoPersonal.id,
      amountMinor: 500_00, toAccountID: cashPLN.id, toAmountMinor: 500_00, payee: "ATM withdrawal",
      source: .pko),
    expense(404, "2026-10-19", "09:15", "Biedronka", cat: 202, pkoPersonal, 17_35, source: .pko),
    expense(
      405, "2026-10-18", "13:20", "Café du Parc", cat: 203, monobank, 440_00, event: lyonTrip,
      note: "Lunch with the team", original: (10_00, "EUR")),
    Txn(
      id: id(406), type: .transfer, occurredAt: at("2026-10-15", "10:00"), accountID: monobank.id,
      amountMinor: 4_400_00, toAccountID: revolutEUR.id, toAmountMinor: 100_00, payee: "To EUR card"),
    expense(407, "2026-10-12", "08:00", "Rent October", cat: 205, pkoPersonal, 4_000_00, note: "Standing order"),
    Txn(
      id: id(408), type: .income, occurredAt: at("2026-10-10", "11:30"), accountID: revolutEUR.id,
      amountMinor: 3_200_00, categoryID: id(251), payee: "Salary"),
    expense(409, "2026-10-08", "19:44", "Orange", cat: 211, pkoPersonal, 35_00),
    expense(410, "2026-10-08", "10:12", "Zalando", cat: 212, pkoPersonal, 120_00, refund: true, note: "Returned jacket"),
    expense(411, "2026-10-05", "17:55", "Lidl", cat: 202, pkoPersonal, 86_40),
    expense(412, "2026-10-03", "22:10", "Uber", cat: 207, revolutEUR, 14_20, event: lyonTrip),
    expense(413, "2026-09-30", "07:48", "Orlen", cat: 208, pkoCreditCard, 210_00),
    expense(414, "2026-09-28", "20:30", "Pizzeria Napoli", cat: 203, monobank, 640_00),
    Txn(
      id: id(415), type: .transfer, occurredAt: at("2026-09-25", "14:05"), accountID: pkoUSD.id,
      amountMinor: 2_000_00, toAccountID: pkoPersonal.id, toAmountMinor: 7_800_00, payee: "Currency exchange"),
    expense(416, "2026-09-23", "18:22", "Auchan", cat: 202, pkoPersonal, 142_30),
  ]

  public static let attachedRecords: [AttachedRecord] = [
    AttachedRecord(id: id(501), txnID: id(406), kind: .expense, categoryID: id(213), amountMinor: 22_00, note: "Transfer fee"),
    AttachedRecord(id: id(502), txnID: id(411), kind: .income, categoryID: id(252), amountMinor: 2_00, note: "Cashback"),
  ]

  // MARK: Budget

  /// Limits in their own currencies (D43): Health in EUR, the rest in PLN.
  public static let budgetPlan = BudgetPlan(id: id(601), effectiveMonth: "2026-01", legacyCurrency: .PLN)
  public static let budgetAllocations: [BudgetAllocation] = [
    BudgetAllocation(id: id(611), planID: id(601), categoryID: id(205), limitMinor: 4_000_00, currency: .PLN),
    BudgetAllocation(id: id(612), planID: id(601), categoryID: id(202), limitMinor: 1_800_00, currency: .PLN),
    BudgetAllocation(id: id(613), planID: id(601), categoryID: id(203), limitMinor: 600_00, currency: .PLN),
    BudgetAllocation(id: id(614), planID: id(601), categoryID: id(206), limitMinor: 400_00, currency: .PLN),
    BudgetAllocation(id: id(615), planID: id(601), categoryID: id(209), limitMinor: 110_00, currency: .EUR),
  ]

  // MARK: Rates (UAH per unit, NBU)

  public static let fxRates: [FXRate] = {
    let perUAH: [(Currency, Decimal)] = [(.PLN, Decimal(string: "11.30")!), (.EUR, Decimal(string: "48.50")!), (.USD, Decimal(string: "41.60")!)]
    var rates: [FXRate] = []
    var n = 700
    for day in ["2026-09-22", "2026-10-01", "2026-10-21"] {
      for (currency, rate) in perUAH {
        n += 1
        rates.append(
          FXRate(id: id(n), day: day, base: currency, quote: .UAH, rateE8: RateScale.scaled(rate), provider: "NBU", fetchedAt: at(day)))
      }
    }
    return rates
  }()

  public static let settings = [
    AppSetting(.displayCurrency, value: Currency.UAH.rawValue),
    AppSetting(.refundsReduceSpending, value: "false"),
    AppSetting(.ratesAutoRefresh, value: "true"),
  ]

  // MARK: Seeding

  /// Inserts everything above into a migrated database.
  public static func seed(_ db: Database) throws {
    try db.seed {
      for account in accounts { account }
      for category in categories { category }
      for event in events { event }
      for txn in txns { txn }
      for record in attachedRecords { record }
      budgetPlan
      for allocation in budgetAllocations { allocation }
      for rate in fxRates { rate }
      for setting in settings { setting }
    }
  }

  /// An in-memory database with the preview data, for previews and tests.
  public static func database() throws -> any DatabaseWriter {
    let database = try AbacusDatabase.open(at: nil)
    try database.write { try seed($0) }
    return database
  }
}
