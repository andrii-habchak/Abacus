import AbacusDomain
import Foundation
import Observation

/// State shared by the whole main window and the Settings window: the selected section, the
/// display currency (R-HOME-4) and the other app settings (R-SET-1, R-SET-3), rate status for
/// the toolbar (R-FX-4), and the hooks other screens plug into ("New transaction", drill-down to
/// the transaction list).
@MainActor
@Observable
public final class AppModel {
  /// The sidebar selection.
  public var section: AppSection? = .dashboard

  /// Display currency of every widget and total (R-HOME-4). Remembered via `SettingsRepository`.
  public private(set) var displayCurrency: Currency = .UAH
  /// "Refunds reduce category spending" — off by default (R-SET-3, R-TX-4).
  public private(set) var refundsReduceSpending = false
  /// "Update rates automatically" — on by default (R-SET-1, R-FX-1).
  public private(set) var ratesAutoRefresh = true

  /// Rate status for the toolbar's "NBU rates · <day>" (R-FX-4).
  public private(set) var ratesStatus = RatesStatus()

  /// The transaction editor sheet (WP B4) while non-nil: "New transaction" / ⌘N, or a row
  /// opened in the list.
  public var editor: TransactionEditorMode?
  /// Transaction-list filters asked for by another screen (dashboard drill-down, an event's
  /// "Show N transactions"). The shell hands them to the list and sets this back to nil.
  public var pendingTransactionFilters: TransactionFilters?

  /// The last settings write that failed.
  public private(set) var errorMessage: String?
  public private(set) var isLoaded = false

  @ObservationIgnored public let environment: AppEnvironment
  /// Told after "Refunds reduce category spending" changed and was saved (screens recompute).
  @ObservationIgnored public var onRefundsChange: (@MainActor (Bool) async -> Void)?
  /// The Exchange rates screen.
  public let rates: RatesModel
  /// The Settings window's Data tab.
  public let data: DataSettingsModel

  public init(environment: AppEnvironment) {
    self.environment = environment
    rates = RatesModel(
      store: environment.rateStore, service: environment.rates, today: environment.today,
      now: environment.now, formats: environment.formats)
    data = DataSettingsModel(environment: environment)
    rates.onStatusChange = { [weak self] status in self?.ratesStatus = status }
    data.onRestore = { [weak self] in await self?.load() }
  }

  public var formats: Formats { environment.formats }

  // MARK: Loading

  /// Reads the settings and the rates on launch (and after a restore).
  public func load() async {
    let settings = environment.settings
    do {
      let currency = try await settings.value(.displayCurrency)
      displayCurrency = currency.flatMap(Currency.init(rawValue:)) ?? .UAH
      refundsReduceSpending = try await settings.value(.refundsReduceSpending) == "true"
      ratesAutoRefresh = try await settings.value(.ratesAutoRefresh) != "false"
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't read the settings: \(error.localizedDescription)"
    }
    rates.showIn = displayCurrency
    await rates.load()
    await data.load()
    isLoaded = true
  }

  // MARK: Settings

  /// The toolbar's segmented control and Settings › General (R-HOME-4). Applies at once and
  /// persists in the background; await the task to know it was written.
  @discardableResult
  public func setDisplayCurrency(_ currency: Currency) -> Task<Void, Never> {
    displayCurrency = currency
    return persist(.displayCurrency, currency.rawValue)
  }

  /// Settings › General › Refunds (R-SET-3).
  @discardableResult
  public func setRefundsReduceSpending(_ on: Bool) -> Task<Void, Never> {
    refundsReduceSpending = on
    let write = persist(.refundsReduceSpending, on ? "true" : "false")
    return Task { [weak self] in
      await write.value
      await self?.onRefundsChange?(on)
    }
  }

  /// Settings › Rates › "Update rates automatically" (R-SET-1, R-FX-1).
  @discardableResult
  public func setRatesAutoRefresh(_ on: Bool) -> Task<Void, Never> {
    ratesAutoRefresh = on
    ratesStatus.autoRefresh = on
    let service = environment.rates
    let write = persist(.ratesAutoRefresh, on ? "true" : "false")
    return Task {
      await write.value
      await service.setAutoRefresh(on)
    }
  }

  private func persist(_ key: SettingKey, _ value: String) -> Task<Void, Never> {
    let settings = environment.settings
    return Task { [weak self] in
      do {
        try await settings.set(key, value)
      } catch {
        self?.errorMessage = "Couldn't save the setting: \(error.localizedDescription)"
      }
    }
  }

  /// "Off (default): …" / "On: …" under the Refunds checkbox.
  public var refundsHint: String {
    refundsReduceSpending
      ? "On: a refund is subtracted from its category’s spending and budget."
      : "Off (default): a refund counts as income (“Refunds”); category spending is unchanged. Balances are the same either way."
  }

  /// Under "Update rates automatically".
  public var autoRatesHint: String {
    ratesAutoRefresh ? "On launch and once a day while Abacus is open." : "Only when you click “Refresh rates”."
  }

  /// "1 manual rate" / "3 manual rates" (Settings › Rates).
  public var manualRateCountText: String {
    let count = rates.overrideRows.count
    return count == 1 ? "1 manual rate" : "\(count) manual rates"
  }

  // MARK: Toolbar

  /// "NBU rates · 21 Oct 2026" (R-FX-4); "No rates yet" before the first fetch.
  public var ratesAsOfLabel: String {
    guard let day = ratesStatus.latestDay else { return "No rates yet" }
    return "NBU rates · \(formats.day(day))"
  }

  // MARK: Hooks

  /// Toolbar "New transaction" and ⌘N.
  public func requestNewTransaction() {
    editor = .new
  }

  /// A transaction opened from a list (double-click / Return).
  public func editTransaction(_ id: Txn.ID) {
    editor = .edit(id)
  }

  /// Opens the transaction list with filters (dashboard drill-down, "Show N transactions").
  public func showTransactions(_ filters: TransactionFilters) {
    pendingTransactionFilters = filters
    section = .transactions
  }

  /// ⌘1…⌘9: the sections in sidebar order.
  public static let sectionsInOrder: [AppSection] = AppSection.overview + AppSection.manage
}
