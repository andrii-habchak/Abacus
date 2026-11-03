import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Loads the converter the aggregates use (rates are read per call so a long-running server sees
/// rates the app fetched meanwhile).
public typealias RateSource = @Sendable (any DatabaseWriter) async throws -> any CurrencyConverter

/// The read side of the MCP server, reusing the app's calculators and repositories so figures
/// match the app's screens. Shells (the MCP tools, a later CLI) stay thin: they parse arguments,
/// call one method here and encode the result. Nothing here writes.
public struct AbacusQueries: Sendable {
  public static let searchCap = 200

  public let database: any DatabaseWriter
  public let calendar: Calendar
  let rateSource: RateSource
  let todayProvider: @Sendable () -> Day

  /// `database` should be a read-only connection (`ReadOnlyDatabase.open`).
  public init(
    database: any DatabaseWriter, calendar: Calendar = .current,
    rates: @escaping RateSource = { _ in NoRates() },
    today: @escaping @Sendable () -> Day = { Day(Date()) }
  ) {
    self.database = database
    self.calendar = calendar
    self.rateSource = rates
    self.todayProvider = today
  }

  var today: Day { todayProvider() }
  var accountsRepository: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
  var categoriesRepository: SQLiteCategoryRepository { SQLiteCategoryRepository(database: database) }
  var txnRepository: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: calendar) }
  var settings: SQLiteSettingsRepository { SQLiteSettingsRepository(database: database) }

  func converter() async throws -> any CurrencyConverter { try await rateSource(database) }

  /// The display currency setting, or UAH.
  public func displayCurrency() async throws -> Currency { try await settings.displayCurrency() }

  func resolve(currency name: String?) async throws -> Currency {
    guard let name else { return try await displayCurrency() }
    guard let currency = Currency(rawValue: name.uppercased()) else {
      throw ToolError("Unknown currency “\(name)”; use one of \(Currency.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return currency
  }

  func unconverted(_ value: Unconverted) -> UnconvertedDTO {
    UnconvertedDTO(
      count: value.count,
      missingRates: value.missingRates.map { "\($0.from.rawValue)→\($0.to.rawValue)\($0.day.map { " on \($0)" } ?? "")" }.sorted())
  }

  // MARK: Accounts

  public func accounts(includeArchived: Bool = false) async throws -> [AccountDTO] {
    let accounts = try await accountsRepository.accounts(includeArchived: includeArchived)
    let groups = Dictionary(uniqueKeysWithValues: try await accountsRepository.groups().map { ($0.id, $0.name) })
    let series = try await SQLiteReportQueries(database: database, calendar: calendar)
      .balances(on: [today], includeArchived: includeArchived)
    return accounts.map { account in
      AccountDTO(
        id: account.id.uuidString, name: account.name, kind: account.kind.rawValue, currency: account.currency.rawValue,
        isLiability: account.kind.isLiability, isArchived: account.isArchived,
        group: account.groupID.flatMap { groups[$0] },
        balance: MoneyDTO(minor: series.balances[account.id]?.first ?? 0, currency: account.currency))
    }
  }

  // MARK: Net worth

  public func netWorth(currency: String? = nil) async throws -> NetWorthDTO {
    let currency = try await resolve(currency: currency)
    let converter = try await converter()
    async let accounts = accountsRepository.accounts(includeArchived: true)
    async let txns = txnRepository.transactions(matching: TxnQuery(toDay: today, newestFirst: false))
    let book = try await SQLiteDebtRepository(database: database, calendar: calendar).book()
    let value = Calc.netWorth(
      accounts: try await accounts, txns: try await txns, currency: currency, converter: converter, through: today,
      debts: book, calendar: calendar)
    let names = Dictionary(uniqueKeysWithValues: try await accountsRepository.accounts(includeArchived: true).map { ($0.id, $0) })
    return NetWorthDTO(
      currency: currency.rawValue, asOf: today.string, ratesAsOf: converter.latestDay?.string,
      assets: MoneyDTO(value.assets), liabilities: MoneyDTO(value.liabilities), total: MoneyDTO(value.total),
      accounts: value.accounts.compactMap { line in
        guard let account = names[line.accountID] else { return nil }
        return NetWorthDTO.Line(
          account: account.name, kind: account.kind.rawValue, balance: MoneyDTO(line.balance),
          converted: line.converted.map(MoneyDTO.init))
      },
      debtsCountedInNetWorth: value.debts.map { line in
        NetWorthDTO.DebtLine(
          person: book.debt(line.debtID)?.personName ?? "", balance: MoneyDTO(line.balance),
          converted: line.converted.map(MoneyDTO.init))
      },
      unconverted: unconverted(value.unconverted))
  }

  // MARK: Reports

  struct Ledger {
    var accounts: [Account]
    var categories: [AbacusDomain.Category]
    var txns: [TxnWithLines]
    var refundsReduceSpending: Bool
  }

  /// Everything the report calculators need for `from…to`, with the debt records the app also
  /// reports (R-DEBT-4).
  func ledger(from: Day, to: Day) async throws -> Ledger {
    async let accounts = accountsRepository.accounts(includeArchived: true)
    async let categories = categoriesRepository.categories(kind: nil, includeArchived: true)
    async let txns = txnRepository.transactions(matching: TxnQuery(fromDay: from, toDay: to, newestFirst: false))
    let reduce = try await settings.refundsReduceSpending()
    var result = Ledger(
      accounts: try await accounts, categories: try await categories, txns: try await txns,
      refundsReduceSpending: reduce)
    let ledger = try await SQLiteDebtRepository(database: database, calendar: calendar).book().reportLedger(calendar: calendar)
    result.accounts += ledger.accounts
    result.txns += ledger.txns.filter { (from...to).contains(Day($0.txn.occurredAt, calendar: calendar)) }
    return result
  }

  func range(month: String?, from: String?, to: String?) throws -> (Day, Day) {
    if let month {
      guard let parsed = Month(month) else { throw ToolError("“month” must look like 2026-03") }
      return (parsed.firstDay, parsed.lastDay(calendar: calendar))
    }
    guard let from, let to else { throw ToolError("Give either “month” or both “from” and “to” (YYYY-MM-DD)") }
    guard let start = Day(from), let end = Day(to) else { throw ToolError("Days must look like 2026-03-31") }
    guard start <= end else { throw ToolError("“from” is after “to”") }
    return (start, end)
  }

  /// Expenses or income by category for a month or a day range (R-HOME-3), with subcategories.
  public func spendingByCategory(
    kind: CategoryKind = .expense, month: String?, from: String?, to: String?, currency: String?
  ) async throws -> SpendingDTO {
    let (start, end) = try range(month: month, from: from, to: to)
    let currency = try await resolve(currency: currency)
    let ledger = try await ledger(from: start, to: end)
    let breakdown = Calc.categoryTotals(
      kind: kind, days: start...end, accounts: ledger.accounts, categories: ledger.categories, txns: ledger.txns,
      currency: currency, converter: try await converter(), refundsReduceSpending: ledger.refundsReduceSpending,
      calendar: calendar)
    let names = Dictionary(uniqueKeysWithValues: ledger.categories.map { ($0.id, $0.name) })
    func share(_ item: CategoryTotal) -> CategoryShareDTO {
      CategoryShareDTO(
        category: Self.name(of: item.key, names),
        total: MoneyDTO(item.total),
        sharePercent: item.share.map { Self.percent($0) },
        subcategories: item.children.map(share))
    }
    return SpendingDTO(
      kind: kind.rawValue, from: start.string, to: end.string, currency: currency.rawValue,
      total: MoneyDTO(breakdown.total), categories: breakdown.items.map(share),
      unconverted: unconverted(breakdown.unconverted))
  }

  static func name(of key: CategoryKey, _ names: [AbacusDomain.Category.ID: String]) -> String {
    switch key {
    case .category(let id): names[id] ?? "Unknown category"
    case .uncategorized: Uncategorised.title
    case .refunds: "Refunds"
    }
  }

  static func percent(_ fraction: Decimal) -> String {
    var value = fraction * 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 1, .bankers)
    return "\(rounded)"
  }

  /// Income, expenses and net over a day range, in total and per month (R-HOME-6).
  public func cashFlow(from: String, to: String, currency: String?) async throws -> CashFlowDTO {
    let (start, end) = try range(month: nil, from: from, to: to)
    let months = (end.yearMonth.year - start.yearMonth.year) * 12 + end.yearMonth.month - start.yearMonth.month + 1
    guard months <= 120 else { throw ToolError("Range too long: at most 120 months") }
    let currency = try await resolve(currency: currency)
    let ledger = try await ledger(from: start, to: end)
    let converter = try await converter()
    let totals = Calc.listTotals(
      txns: ledger.txns, accounts: ledger.accounts, categories: ledger.categories, currency: currency,
      converter: converter, refundsReduceSpending: ledger.refundsReduceSpending, calendar: calendar)
    let series = Calc.incomeExpenseSeries(
      endingAt: end.yearMonth, count: months, accounts: ledger.accounts, categories: ledger.categories,
      txns: ledger.txns, currency: currency, converter: converter,
      refundsReduceSpending: ledger.refundsReduceSpending, calendar: calendar)
    return CashFlowDTO(
      from: start.string, to: end.string, currency: currency.rawValue, income: MoneyDTO(totals.income),
      expense: MoneyDTO(totals.expense), net: MoneyDTO(totals.net),
      months: series.months.map {
        CashFlowDTO.Month(
          month: $0.month.string, income: MoneyDTO($0.income), expense: MoneyDTO($0.expense), net: MoneyDTO($0.net))
      },
      unconverted: unconverted(totals.unconverted))
  }

  // MARK: Budget

  /// R-BUD-1…3: the plan in effect for `month` (default: this month) against spending.
  public func budgetStatus(month: String?, currency: String?) async throws -> BudgetDTO? {
    let parsed: Month
    if let month {
      guard let value = Month(month) else { throw ToolError("“month” must look like 2026-03") }
      parsed = value
    } else {
      parsed = today.yearMonth
    }
    let currency = try await resolve(currency: currency)
    let budgets = SQLiteBudgetRepository(database: database)
    guard let entry = try await budgets.plan(for: parsed) else { return nil }
    let ledger = try await ledger(from: parsed.firstDay, to: parsed.lastDay(calendar: calendar))
    guard
      let status = Calc.budgetStatus(
        month: parsed, plans: [entry.plan], allocations: entry.allocations, accounts: ledger.accounts,
        categories: ledger.categories, txns: ledger.txns, converter: try await converter(),
        refundsReduceSpending: ledger.refundsReduceSpending, currency: currency, today: today, calendar: calendar)
    else { return nil }
    let names = Dictionary(uniqueKeysWithValues: ledger.categories.map { ($0.id, $0.name) })
    let first = unconverted(status.unconverted)
    let second = unconverted(status.totalUnconverted)
    let gaps = UnconvertedDTO(
      count: first.count + second.count, missingRates: Array(Set(first.missingRates + second.missingRates)).sorted())
    return BudgetDTO(
      month: parsed.string, currency: currency.rawValue, limit: MoneyDTO(status.limit), spent: MoneyDTO(status.spent),
      remaining: MoneyDTO(status.remaining), status: status.status.rawValue, daysLeft: status.daysLeft,
      overLimitCount: status.overCount,
      lines: status.lines.map {
        BudgetDTO.Line(
          category: names[$0.categoryID] ?? "Unknown category", limit: MoneyDTO($0.limit), spent: MoneyDTO($0.spent),
          remaining: MoneyDTO($0.remaining), status: $0.status.rawValue)
      },
      unconverted: gaps)
  }

  // MARK: Debts

  public func debts(currency: String?) async throws -> DebtDTO {
    let currency = try await resolve(currency: currency)
    let book = try await SQLiteDebtRepository(database: database, calendar: calendar).book()
    let summary = Calc.debtSummary(book, currency: currency, converter: try await converter(), calendar: calendar)
    return DebtDTO(
      currency: currency.rawValue, owedToOwner: MoneyDTO(summary.owedToMe), ownedByOwner: MoneyDTO(summary.iOwe),
      people: summary.people.map { person in
        let debt = book.debt(person.debtID)
        return DebtDTO.Person(
          person: person.personName, balances: person.balances.map(MoneyDTO.init),
          converted: person.converted.map(MoneyDTO.init), dueDay: debt?.dueDay, isSettled: debt?.isSettled ?? false,
          countsInNetWorth: debt?.countsInNetWorth ?? false)
      },
      unconverted: unconverted(summary.unconverted))
  }

  // MARK: Rates

  /// The latest known rate of each other currency into `currency`.
  public func rates(currency: String?) async throws -> RatesDTO {
    let target = try await resolve(currency: currency)
    let converter = try await converter()
    let rates: [RatesDTO.Rate] = Currency.displayOrder.filter { $0 != target }.compactMap { from in
      converter.latestRate(from: from, to: target).map {
        RatesDTO.Rate(from: from.rawValue, to: target.rawValue, rate: Self.rate($0))
      }
    }
    return RatesDTO(asOf: converter.latestDay?.string, rates: rates)
  }

  static func rate(_ rate: Decimal) -> String {
    var value = rate
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 6, .bankers)
    return "\(rounded)"
  }
}
