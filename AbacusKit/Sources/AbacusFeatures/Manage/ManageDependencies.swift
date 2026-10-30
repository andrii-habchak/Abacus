import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData

/// What the management screens (Accounts, Categories, Budget, Events, Rules) read and write:
/// the repository protocols, the current rates, the display currency and "today".
///
/// Wiring (orchestrator): `live(database:refresher:displayCurrency:)` builds it on the A5 store and
/// the A2 `RateRefresher`; previews and tests use `preview(…)` over `PreviewData`.
public struct ManageDependencies: Sendable {
  public var accounts: any AccountRepository
  public var categories: any CategoryRepository
  public var txns: any TxnRepository
  public var budget: any BudgetRepository
  public var events: any EventRepository
  public var rules: any RuleRepository
  public var settings: any SettingsRepository
  /// The rates in memory now (event totals convert each amount at its day's rate, R-FX-3).
  public var converter: @Sendable () async -> any CurrencyConverter
  public var today: @Sendable () -> Day
  public var format: ManageFormat
  /// People with debts for the rule editor's debt action (R-DEBT-12); nil = none offered.
  public var debts: (any DebtRepository)?

  public init(
    accounts: any AccountRepository, categories: any CategoryRepository, txns: any TxnRepository,
    budget: any BudgetRepository, events: any EventRepository, rules: any RuleRepository,
    settings: any SettingsRepository, converter: @escaping @Sendable () async -> any CurrencyConverter,
    today: @escaping @Sendable () -> Day = { Day(Date()) }, format: ManageFormat = ManageFormat(),
    debts: (any DebtRepository)? = nil
  ) {
    self.debts = debts
    self.accounts = accounts
    self.categories = categories
    self.txns = txns
    self.budget = budget
    self.events = events
    self.rules = rules
    self.settings = settings
    self.converter = converter
    self.today = today
    self.format = format
  }

  /// Every transaction (balances, usage counts, event totals).
  func allTransactions() async throws -> [TxnWithLines] {
    try await txns.transactions(matching: TxnQuery(newestFirst: false))
  }

  func refundsReduceSpending() async -> Bool {
    (try? await settings.value(.refundsReduceSpending)) == "true"
  }
}

extension ManageDependencies {
  /// The real store and rate refresher.
  public static func live(
    database: any DatabaseWriter, refresher: RateRefresher, format: ManageFormat = ManageFormat()
  ) -> ManageDependencies {
    let calendar = format.calendar
    return ManageDependencies(
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      txns: SQLiteTxnRepository(database: database, calendar: calendar),
      budget: SQLiteBudgetRepository(database: database),
      events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database, calendar: calendar),
      settings: SQLiteSettingsRepository(database: database),
      converter: { await refresher.snapshot.table },
      today: { Day(Date(), calendar: calendar) }, format: format,
      debts: SQLiteDebtRepository(database: database, calendar: calendar))
  }

  /// In-memory fakes over `store` (default: `ManagePreviewStore.sample()`, i.e. `PreviewData`
  /// plus a few rules), rates from `PreviewData`, today = `PreviewData.today`.
  public static func preview(
    store: ManagePreviewStore = .sample(),
    rates: RateTable = RateTable(rates: PreviewData.fxRates, today: PreviewData.today),
    today: Day = PreviewData.today, format: ManageFormat = ManageFormat()
  ) -> ManageDependencies {
    ManageDependencies(
      accounts: store.accountRepository, categories: store.categoryRepository, txns: store.txnRepository,
      budget: store.budgetRepository, events: store.eventRepository, rules: store.ruleRepository,
      settings: store.settingsRepository, converter: { rates }, today: { today }, format: format)
  }
}
