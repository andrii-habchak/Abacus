import AbacusDomain
import Foundation
import Observation

/// The dashboard (R-HOME-1…5): net worth with its monthly chart, the month's budget and the
/// expenses donut, in the display currency, for the selected month.
///
/// Reads everything once in `load()`; a display-currency or month change recomputes from what
/// was read (a month change also reads that month's budget plan). Call `load()` again when the
/// data changes and `refreshRates()` when the rates do.
@MainActor
@Observable
public final class DashboardModel {
  public enum Phase: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
  }

  public private(set) var phase: Phase = .idle
  /// R-HOME-4; the shell owns the choice and passes it in.
  public private(set) var displayCurrency: Currency
  /// The month of the budget and expenses widgets (R-HOME-5).
  public private(set) var month: Month
  public private(set) var today: Day
  public private(set) var netWorth: DashboardNetWorth?
  /// nil when no budget plan is in effect for `month` (or before loading).
  public private(set) var budget: DashboardBudget?
  public private(set) var expenses: DashboardExpenses?
  public private(set) var ratesAsOf: Day?
  public private(set) var ratesFetchFailed = false
  /// The donut slice picked last (cleared when the month changes).
  public private(set) var selectedSlice: CategoryKey?
  /// The earliest month the selector goes back to: the month of the first transaction.
  public private(set) var earliestMonth: Month

  @ObservationIgnored public let dependencies: DashboardDependencies
  @ObservationIgnored private var data: LoadedData?
  @ObservationIgnored private var rates: DashboardRates?
  @ObservationIgnored private var plans: [Month: PlanEntry] = [:]

  struct LoadedData {
    var accounts: [Account]
    var categories: [AbacusDomain.Category]
    var txns: [TxnWithLines]
    var refundsReduceSpending: Bool
    /// The built-in "Uncategorised" colour (D47).
    var uncategorisedColor: String = Uncategorised.defaultColorHex
  }

  struct PlanEntry {
    var plan: BudgetPlan?
    var allocations: [BudgetAllocation]
  }

  public init(dependencies: DashboardDependencies, displayCurrency: Currency = .UAH) {
    self.dependencies = dependencies
    self.displayCurrency = displayCurrency
    let today = dependencies.today()
    self.today = today
    self.month = today.yearMonth
    self.earliestMonth = today.yearMonth
  }

  public var format: DashboardFormat { dependencies.format }

  // MARK: Loading

  /// Reads accounts (archived too: their transactions still count in month totals), categories,
  /// every transaction up to today, the refund setting, the selected month's plan and the
  /// rates; then computes. Missing historical rates are requested once and the figures redone.
  public func load() async {
    if data == nil { phase = .loading }
    today = dependencies.today()
    if month > today.yearMonth { month = today.yearMonth }
    do {
      async let accounts = dependencies.accounts.accounts(includeArchived: true)
      async let categories = dependencies.categories.categories(kind: nil, includeArchived: true)
      async let txns = dependencies.txns.transactions(matching: TxnQuery(toDay: today, newestFirst: false))
      async let refunds = dependencies.settings.value(.refundsReduceSpending)
      var loaded = try await LoadedData(
        accounts: accounts, categories: categories, txns: txns, refundsReduceSpending: refunds == "true")
      loaded.uncategorisedColor = await dependencies.settings.uncategorisedColor()
      data = loaded
      plans = [:]
      _ = try await planEntry(for: month)
      earliestMonth = min(
        today.yearMonth, loaded.txns.map { Day($0.txn.occurredAt, calendar: format.calendar).yearMonth }.min() ?? today.yearMonth)
    } catch {
      phase = .failed("Couldn't load the dashboard: \(error.localizedDescription)")
      return
    }
    await readRates()
    recompute()
    phase = .loaded

    let missingDays = missingRates.days
    if !missingDays.isEmpty {
      await dependencies.requestRates(missingDays)
      await refreshRates()
    }
  }

  /// Re-reads the rates (after a refresh or a lazy fetch) and recomputes.
  public func refreshRates() async {
    await readRates()
    recompute()
  }

  private func readRates() async {
    let rates = await dependencies.rates()
    self.rates = rates
    ratesAsOf = rates.asOf
    ratesFetchFailed = rates.fetchFailed
  }

  private func planEntry(for month: Month) async throws -> PlanEntry {
    if let entry = plans[month] { return entry }
    let found = try await dependencies.budget.plan(for: month)
    let entry = PlanEntry(plan: found?.plan, allocations: found?.allocations ?? [])
    plans[month] = entry
    return entry
  }

  // MARK: Inputs

  public func setDisplayCurrency(_ currency: Currency) {
    guard currency != displayCurrency else { return }
    displayCurrency = currency
    recompute()
  }

  public var canShowNextMonth: Bool { month < today.yearMonth }
  public var canShowPreviousMonth: Bool { month > earliestMonth }

  public func showPreviousMonth() async {
    guard canShowPreviousMonth else { return }
    await show(month: month.adding(months: -1))
  }

  public func showNextMonth() async {
    guard canShowNextMonth else { return }
    await show(month: month.adding(months: 1))
  }

  /// Selects a month between `earliestMonth` and the current one (R-HOME-5).
  public func show(month target: Month) async {
    let target = min(max(target, earliestMonth), today.yearMonth)
    guard target != month else { return }
    month = target
    selectedSlice = nil
    if data != nil {
      do {
        _ = try await planEntry(for: target)
      } catch {
        phase = .failed("Couldn't load the budget: \(error.localizedDescription)")
        return
      }
    }
    recomputeMonth()
  }

  /// Picks a donut slice or legend row (R-HOME-3) and returns where to drill down: the
  /// category (nil for "Uncategorised": expenses without a category) and the month, or nil
  /// for a slice with nothing to filter by ("Refunds").
  @discardableResult
  public func select(_ slice: DashboardExpenses.Slice) -> (categoryID: AbacusDomain.Category.ID?, month: Month)? {
    selectedSlice = slice.id
    switch slice.id {
    case .category, .uncategorized: return (slice.categoryID, month)
    case .refunds: return nil
    }
  }

  // MARK: Texts

  /// "October 2026".
  public var monthTitle: String { format.month(month) }

  /// "10 days left" for the current month, "Closed month" for earlier ones (R-HOME-2).
  public var monthNote: String {
    guard month == today.yearMonth else { return "Closed month" }
    let left = Calc.daysLeft(in: month, today: today, calendar: format.calendar)
    switch left {
    case 0: return "Last day of the month"
    case 1: return "1 day left"
    default: return "\(left) days left"
    }
  }

  /// "NBU rates as of 21 Oct 2026" (R-FX-4).
  public var ratesText: String {
    ratesAsOf.map { "NBU rates as of \(format.day($0))" } ?? "No exchange rates yet"
  }

  /// The fetch-failure warning (R-FX-4); nil while rates are fresh.
  public var ratesWarning: String? {
    guard ratesFetchFailed else { return nil }
    let day = ratesAsOf.map { ", from \(format.day($0))" } ?? ""
    return "Couldn't reach the rate service. Amounts use the last known rates\(day)."
  }

  /// Every amount left out of the figures for want of a rate (D27).
  public var missingRates: DashboardMissingRates {
    var all = DashboardMissingRates()
    if let netWorth { all.merge(netWorth.missing) }
    if let budget { all.merge(budget.missing) }
    if let expenses { all.merge(expenses.missing) }
    return all
  }

  public var missingRatesText: String? { missingRates.text(format) }

  // MARK: Computing

  private func recompute() {
    guard let data, let rates else { return }
    netWorth = DashboardNetWorth.make(
      accounts: data.accounts, txns: data.txns, currency: displayCurrency, converter: rates.converter,
      today: today, format: format)
    recomputeMonth()
  }

  private func recomputeMonth() {
    guard let data, let rates else { return }
    let entry = plans[month]
    budget = DashboardBudget.make(
      month: month, plan: entry?.plan, allocations: entry?.allocations ?? [], accounts: data.accounts,
      categories: data.categories, txns: data.txns, displayCurrency: displayCurrency, converter: rates.converter,
      refundsReduceSpending: data.refundsReduceSpending, today: today, format: format)
    expenses = DashboardExpenses.make(
      month: month, accounts: data.accounts, categories: data.categories, txns: data.txns,
      currency: displayCurrency, converter: rates.converter, refundsReduceSpending: data.refundsReduceSpending,
      format: format, uncategorisedColor: data.uncategorisedColor)
  }
}
