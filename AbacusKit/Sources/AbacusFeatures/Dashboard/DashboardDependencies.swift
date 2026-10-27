import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData

/// What the dashboard reads: the repository protocols, the current rates and "today".
///
/// Wiring (orchestrator): `live(database:refresher:)` builds it on the A5 store and the A2
/// `RateRefresher`; previews and tests use `preview(…)` over `PreviewData`.
public struct DashboardDependencies: Sendable {
  public var accounts: any AccountRepository
  public var categories: any CategoryRepository
  public var txns: any TxnRepository
  public var budget: any BudgetRepository
  public var settings: any SettingsRepository
  /// The rates in memory now (the refresher's table) and whether the last fetch failed.
  public var rates: @Sendable () async -> DashboardRates
  /// Asks for missing historical rates (R-FX-1 lazy fetch); called once per load with the days
  /// the figures needed but had no rate for.
  public var requestRates: @Sendable (Set<Day>) async -> Void
  public var today: @Sendable () -> Day
  public var format: DashboardFormat
  /// Debts (R-DEBT-6/7, C14): the net-worth term, flagged records without a leg in the
  /// reports, and the Debts widget. nil = no debts (previews).
  public var debts: (any DebtRepository)?

  public init(
    accounts: any AccountRepository, categories: any CategoryRepository, txns: any TxnRepository,
    budget: any BudgetRepository, settings: any SettingsRepository,
    rates: @escaping @Sendable () async -> DashboardRates,
    requestRates: @escaping @Sendable (Set<Day>) async -> Void = { _ in },
    today: @escaping @Sendable () -> Day = { Day(Date()) }, format: DashboardFormat = DashboardFormat(),
    debts: (any DebtRepository)? = nil
  ) {
    self.debts = debts
    self.accounts = accounts
    self.categories = categories
    self.txns = txns
    self.budget = budget
    self.settings = settings
    self.rates = rates
    self.requestRates = requestRates
    self.today = today
    self.format = format
  }
}

extension DashboardDependencies {
  /// The real store and rate refresher.
  public static func live(
    database: any DatabaseWriter, refresher: RateRefresher, format: DashboardFormat = DashboardFormat()
  ) -> DashboardDependencies {
    let calendar = format.calendar
    return DashboardDependencies(
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      txns: SQLiteTxnRepository(database: database, calendar: calendar),
      budget: SQLiteBudgetRepository(database: database),
      settings: SQLiteSettingsRepository(database: database),
      rates: {
        let snapshot = await refresher.snapshot
        return DashboardRates(converter: snapshot.table, fetchFailed: snapshot.status.failure != nil)
      },
      requestRates: { days in await refresher.ensureRates(for: days) },
      today: { Day(Date(), calendar: calendar) }, format: format,
      debts: SQLiteDebtRepository(database: database, calendar: calendar))
  }

  /// In-memory fakes over `store` (default: `PreviewData`), rates from `rates`, today =
  /// `PreviewData.today`.
  public static func preview(
    store: DashboardPreviewStore = .previewData(),
    rates: RateTable = RateTable(rates: PreviewData.fxRates, today: PreviewData.today),
    fetchFailed: Bool = false, today: Day = PreviewData.today, format: DashboardFormat = DashboardFormat()
  ) -> DashboardDependencies {
    DashboardDependencies(
      accounts: store.accountRepository, categories: store.categoryRepository, txns: store.txnRepository,
      budget: store.budgetRepository, settings: store.settingsRepository,
      rates: { DashboardRates(converter: rates, fetchFailed: fetchFailed) },
      today: { today }, format: format)
  }

  /// A full synthetic year (`DashboardSample`): a twelve-month net-worth history and an
  /// over-budget August, for previews and screenshots.
  public static func sample(fetchFailed: Bool = false, format: DashboardFormat = DashboardFormat())
    -> DashboardDependencies
  {
    preview(
      store: DashboardSample.store(), rates: DashboardSample.rateTable(), fetchFailed: fetchFailed, format: format)
  }
}

/// Builds the Transactions query a donut drill-down opens: one category (its children
/// included, R-LIST-2) over one month (R-HOME-3). A nil category is the "Uncategorised"
/// slice: expenses (or income) without a category. The income donut (R-HOME-6) also filters
/// to income transactions.
public enum DashboardDrillDown {
  /// Where a picked donut slice leads: Transactions of `kind`, `categoryID` (nil:
  /// "Uncategorised") and `month`.
  public struct Target: Hashable, Sendable {
    public var kind: CategoryKind
    public var categoryID: AbacusDomain.Category.ID?
    public var month: Month

    public init(kind: CategoryKind = .expense, categoryID: AbacusDomain.Category.ID?, month: Month) {
      self.kind = kind
      self.categoryID = categoryID
      self.month = month
    }
  }

  /// The transaction type a drill-down of `kind` filters to; nil for an expense category (as
  /// before R-HOME-6: the category alone, refunds and records included).
  public static func types(kind: CategoryKind, uncategorised: Bool) -> Set<TxnType>? {
    switch kind {
    case .income: [.income]
    case .expense: uncategorised ? [.expense] : nil
    }
  }

  public static func query(
    categoryID: AbacusDomain.Category.ID?, month: Month, kind: CategoryKind = .expense,
    calendar: Calendar = .autoupdatingCurrent
  ) -> TxnQuery {
    let types = types(kind: kind, uncategorised: categoryID == nil) ?? []
    guard let categoryID else {
      return TxnQuery(
        fromDay: month.firstDay, toDay: month.lastDay(calendar: calendar), types: types, includeUncategorised: true)
    }
    return TxnQuery(
      fromDay: month.firstDay, toDay: month.lastDay(calendar: calendar), categoryIDs: [categoryID], types: types)
  }

  public static func query(_ target: Target, calendar: Calendar = .autoupdatingCurrent) -> TxnQuery {
    query(categoryID: target.categoryID, month: target.month, kind: target.kind, calendar: calendar)
  }
}
