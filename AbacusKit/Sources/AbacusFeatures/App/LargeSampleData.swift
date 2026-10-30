import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// A synthetic data set the size of a real user's (S1, D54): by default 5,000 transactions over
/// about 30 months, 50 accounts in 8 groups (some archived), 40 categories (parents and
/// children), 8 events, a budget, 40 rules, 10 debts with records, and daily rates for the span.
/// Deterministic (a seeded generator), made-up names only (R-NF-6). Used by the DEBUG launch
/// option `-AbacusLoadLargeSampleData YES` and by the performance tests.
public enum LargeSampleData {
  public struct Size: Sendable {
    public var transactions = 5_000
    public var accounts = 50
    public var groups = 8
    public var debts = 10
    public var days = 900

    /// 5,000 transactions, or `-AbacusLargeSampleTransactions <n>` (scratch databases, C28 timings).
    public static var launch: Size {
      let count = UserDefaults.standard.integer(forKey: "AbacusLargeSampleTransactions")
      return Size(transactions: count > 0 ? count : 5_000)
    }

    public init(transactions: Int = 5_000, accounts: Int = 50, groups: Int = 8, debts: Int = 10, days: Int = 900) {
      self.transactions = transactions
      self.accounts = accounts
      self.groups = groups
      self.debts = debts
      self.days = days
    }
  }

  /// Seeds the set into an empty database; false (nothing changed) when it already has accounts.
  public static func loadIfEmpty(
    into database: any DatabaseWriter, size: Size = .launch, today: Day = Day(Date()), calendar: Calendar = .current
  ) async throws -> Bool {
    try await database.write { db in
      guard try Account.fetchCount(db) == 0 else { return false }
      try seed(db, size: size, today: today, calendar: calendar)
      return true
    }
  }

  /// An in-memory database holding the set (tests).
  public static func database(size: Size = Size(), today: Day = Day(Date()), calendar: Calendar = .current) throws
    -> any DatabaseWriter
  {
    let database = try AbacusDatabase.open(at: nil)
    try database.write { db in try seed(db, size: size, today: today, calendar: calendar) }
    return database
  }

  /// SplitMix64: the same data on every run.
  struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  static let uahPer: [Currency: Decimal] = [.UAH: 1, .PLN: 11.3, .EUR: 48.5, .USD: 41.6]

  static func seed(_ db: Database, size: Size, today: Day, calendar: Calendar) throws {
    var random = Generator(state: 0x5EED_AB4C_0005_0001)
    let first = today.adding(days: -size.days, calendar: calendar)
    func date(_ day: Day, minute: Int) -> Date {
      calendar.date(
        from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 8 + minute / 60 % 12, minute: minute % 60))!
    }
    let created = Date(timeIntervalSince1970: 1_700_000_000)

    // Groups and accounts: shared top-level position space, as migration v11 numbers them.
    let groupNames = ["Everyday", "Savings", "Cards", "Travel", "Family", "Business", "Cash", "Old banks"]
    let groups = (0..<size.groups).map { index in
      AccountGroup(name: groupNames[index % groupNames.count] + (index >= groupNames.count ? " \(index)" : ""), position: index * 10)
    }
    let currencies: [Currency] = [.UAH, .PLN, .EUR, .USD, .PLN, .UAH]
    let kinds: [AccountKind] = [.card, .bank, .savings, .cash, .card, .bank, .creditCard, .investment]
    let accounts = (0..<size.accounts).map { index -> Account in
      let kind = kinds[index % kinds.count]
      let grouped = index % 7 != 6
      return Account(
        name: "Account \(index + 1)", currency: currencies[index % currencies.count], kind: kind,
        openingBalanceMinor: kind.isLiability ? -Int64.random(in: 0...200_000, using: &random) : Int64.random(in: 0...5_000_000, using: &random),
        openingDate: date(first, minute: 0), groupID: grouped && !groups.isEmpty ? groups[index % groups.count].id : nil,
        position: grouped ? index : index * 10 + 5, isArchived: index % 9 == 8)
    }
    let active = accounts.filter { !$0.isArchived }

    // Categories: 8 expense parents with 3 children each, 2 income parents with 3 children.
    var categories: [AbacusDomain.Category] = []
    var expenseLeaves: [AbacusDomain.Category] = []
    var incomeLeaves: [AbacusDomain.Category] = []
    let expenseNames = ["Food", "Home", "Transport", "Health", "Fun", "Shopping", "Bills", "Kids"]
    for (index, name) in expenseNames.enumerated() {
      let parent = AbacusDomain.Category(name: name, kind: .expense, position: index, createdAt: created)
      categories.append(parent)
      expenseLeaves.append(parent)
      for child in 1...3 {
        let category = AbacusDomain.Category(
          name: "\(name) \(child)", kind: .expense, parentID: parent.id, position: child, createdAt: created)
        categories.append(category)
        expenseLeaves.append(category)
      }
    }
    for (index, name) in ["Salary", "Other income"].enumerated() {
      let parent = AbacusDomain.Category(name: name, kind: .income, position: 100 + index, createdAt: created)
      categories.append(parent)
      incomeLeaves.append(parent)
      for child in 1...3 {
        let category = AbacusDomain.Category(
          name: "\(name) \(child)", kind: .income, parentID: parent.id, position: child, createdAt: created)
        categories.append(category)
        incomeLeaves.append(category)
      }
    }

    let events = (0..<8).map { index -> Event in
      let start = first.adding(days: index * 100, calendar: calendar)
      return Event(
        name: "Trip \(index + 1)", startDay: start.string, endDay: start.adding(days: 10, calendar: calendar).string,
        budgetMinor: index % 2 == 0 ? 2_000_00 : nil, budgetCurrency: index % 2 == 0 ? .EUR : nil, isArchived: index < 3)
    }

    // Transactions.
    var txns: [Txn] = []
    var lines: [AttachedRecord] = []
    func amount(_ currency: Currency, _ uah: ClosedRange<Int64>) -> Int64 {
      let value = Int64.random(in: uah, using: &random)
      let rate = NSDecimalNumber(decimal: uahPer[currency] ?? 1).doubleValue
      return max(1_00, Int64(Double(value) / rate))
    }
    for index in 0..<size.transactions {
      let day = first.adding(days: Int(Int64(index) * Int64(size.days) / Int64(max(1, size.transactions))), calendar: calendar)
      let at = date(day, minute: index % 600)
      let account = active[Int.random(in: 0..<active.count, using: &random)]
      let roll = Int.random(in: 0..<100, using: &random)
      let event = roll % 33 == 0 ? events[Int.random(in: 0..<events.count, using: &random)].id : nil
      if roll < 10, active.count > 1 {
        var target = active[Int.random(in: 0..<active.count, using: &random)]
        if target.id == account.id { target = active[(active.firstIndex(of: account)! + 1) % active.count] }
        let minor = amount(account.currency, 50_000...2_000_000)
        let rate = (uahPer[account.currency] ?? 1) / (uahPer[target.currency] ?? 1)
        let toMinor = NSDecimalNumber(decimal: Decimal(minor) * rate).int64Value
        txns.append(
          Txn(
            type: .transfer, occurredAt: at, accountID: account.id, amountMinor: minor, toAccountID: target.id,
            toAmountMinor: max(1, toMinor), payee: "Transfer \(index % 40)", source: .saldo, createdAt: created))
      } else if roll < 18 {
        let category = incomeLeaves[Int.random(in: 0..<incomeLeaves.count, using: &random)]
        txns.append(
          Txn(
            type: .income, occurredAt: at, accountID: account.id, amountMinor: amount(account.currency, 100_000...6_000_000),
            categoryID: category.id, payee: "Employer \(index % 5)", source: .saldo, createdAt: created))
      } else {
        let category = roll < 21 ? nil : expenseLeaves[Int.random(in: 0..<expenseLeaves.count, using: &random)]
        let txn = Txn(
          type: .expense, occurredAt: at, accountID: account.id, amountMinor: amount(account.currency, 2_000...400_000),
          categoryID: category?.id, isRefund: roll == 99, payee: "Shop \(index % 300)", note: roll % 7 == 0 ? "Note \(index)" : "",
          eventID: event, source: roll % 2 == 0 ? .saldo : .pko, createdAt: created)
        txns.append(txn)
        if roll % 20 == 1, let fee = expenseLeaves.first {
          lines.append(AttachedRecord(txnID: txn.id, kind: .expense, categoryID: fee.id, amountMinor: 5_00, note: "Fee"))
        }
      }
    }

    // Budget: one plan with a limit per expense parent.
    let plan = BudgetPlan(
      effectiveMonth: Month(year: first.year, month: first.month).string, totalMinor: 40_000_00, currency: .PLN)
    let allocations = categories.filter { $0.kind == .expense && $0.parentID == nil }.enumerated().map { index, category in
      BudgetAllocation(planID: plan.id, categoryID: category.id, limitMinor: Int64(500_00 + index * 250_00), currency: index % 3 == 0 ? .UAH : .PLN)
    }
    let rules = (0..<40).map { index in
      CategoryRule(
        pattern: "Shop \(index * 7)", categoryID: expenseLeaves[index % expenseLeaves.count].id, origin: index % 2 == 0 ? .manual : .imported,
        position: index)
    }

    // Daily rates for the whole span (the app fetches nothing for these days).
    var rates: [FXRate] = []
    var day = first.adding(days: -5, calendar: calendar)
    while day <= today {
      for currency in [Currency.PLN, .EUR, .USD] {
        let wobble = Decimal(Int(day.day) % 7) / 100
        rates.append(
          FXRate(day: day.string, base: currency, quote: .UAH, rateE8: RateScale.scaled((uahPer[currency] ?? 1) + wobble), provider: "NBU"))
      }
      day = day.adding(days: 1, calendar: calendar)
    }

    try db.seed {
      for group in groups { group }
      for account in accounts { account }
      for category in categories { category }
      for event in events { event }
      for txn in txns { txn }
      for line in lines { line }
      plan
      for allocation in allocations { allocation }
      for rule in rules { rule }
      for rate in rates { rate }
    }

    // Debts: one per person with a virtual account in one currency (and a second one for every
    // other person), payments as transfers to / from it, and a forgiven part as manual record.
    let debtCurrencies: [Currency] = [.EUR, .PLN, .UAH, .USD]
    let recordKinds: [DebtRecordKind] = [.lent, .theyRepaid, .paidOnTheirBehalf, .borrowed, .iRepaid]
    for index in 0..<size.debts {
      let debt = Debt(
        personName: "Person \(index + 1)",
        dueDay: index % 3 == 0 ? today.adding(days: 30 + index, calendar: calendar).string : nil,
        countsInNetWorth: index % 4 != 3, createdAt: created)
      try db.seed { debt }
      var currencies = [debtCurrencies[index % debtCurrencies.count]]
      if index % 2 == 0 { currencies.append(debtCurrencies[(index + 1) % debtCurrencies.count]) }
      for (offset, currency) in currencies.enumerated() {
        let virtual = try SQLiteDebtRepository.createVirtualAccount(
          for: debt.id, currency: currency, name: nil, importBatchID: nil, db)
        guard let own = active.first(where: { $0.currency == currency && !$0.kind.isLiability }) else { continue }
        for step in 0..<6 {
          let kind = recordKinds[(index + step + offset) % recordKinds.count]
          let day = today.adding(days: -(200 - step * 30 - index), calendar: calendar)
          let noon = calendar.date(byAdding: .hour, value: 12, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar)
          let amount = Int64(50_00 + step * 25_00 + index * 10_00)
          let txn = Txn(
            type: .transfer, occurredAt: noon, accountID: kind.isInflow ? virtual.id : own.id, amountMinor: amount,
            toAccountID: kind.isInflow ? own.id : virtual.id, payee: "Person \(index + 1)",
            createdAt: created.addingTimeInterval(Double(step)))
          try db.seed { txn }
        }
      }
      let forgive = DebtRecord(
        debtID: debt.id, kind: .forgaveThem, day: today.adding(days: -20 - index, calendar: calendar).string,
        amountMinor: 20_00, currency: currencies[0], reportKind: .expense, createdAt: created)
      try SQLiteDebtRepository.save(forgive, db)
    }
    try ColorFill.fillAll(db)
  }
}
