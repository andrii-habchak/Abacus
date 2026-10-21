import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import Observation
import SQLiteData

/// Everything the main window runs on: the shared `AppModel` (settings, rates screen, Settings
/// window) and one model per built screen, kept alive across section switches, plus the
/// `RateRefresher` feeding them rates (R-FX-1). `live(database:)` is the app on its database;
/// `preview()` runs on synthetic data for previews and screenshots.
@MainActor
@Observable
public final class AppSession {
  public let app: AppModel
  public let dashboard: DashboardModel
  public let transactions: TransactionsViewModel
  /// What the transaction editor (WP B4) reads and writes; its converter follows the rates.
  public private(set) var editorDependencies: TransactionEditorDependencies

  /// The result of "Load Sample Data", shown in an alert.
  public var sampleDataMessage: String?

  @ObservationIgnored private let database: (any DatabaseWriter)?
  @ObservationIgnored private let refresher: RateRefresher?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var started = false
  @ObservationIgnored private var ratesStartup: Task<Void, Never>?

  init(
    app: AppModel, dashboard: DashboardModel, transactions: TransactionsViewModel,
    editorDependencies: TransactionEditorDependencies, database: (any DatabaseWriter)?,
    refresher: RateRefresher?
  ) {
    self.app = app
    self.dashboard = dashboard
    self.transactions = transactions
    self.editorDependencies = editorDependencies
    self.database = database
    self.refresher = refresher
    app.data.onRestore = { [weak self] in await self?.dataChanged() }
    app.onRefundsChange = { [weak self] on in
      guard let self else { return }
      self.transactions.refundsReduceSpending = on
      await self.dashboard.load()
    }
  }

  // MARK: Building

  /// The app on its database: SQLite repositories (A5), `RateRefresher` over NBU rates (A2).
  public static func live(
    database: any DatabaseWriter, source: any OfficialRateSource = FallbackRateSource.standard(),
    calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
    formats: Formats = Formats()
  ) -> AppSession {
    let rateStore = SQLiteRateStore(database: database)
    let refresher = RateRefresher(store: rateStore, source: source, calendar: calendar, now: now)
    let environment = AppEnvironment(
      settings: SQLiteSettingsRepository(database: database), rateStore: rateStore,
      rates: RefresherRatesService(refresher: refresher), backup: SQLiteBackup(database: database),
      dataLocation: CurrentDataLocation(database: database), lastExport: .userDefaults(),
      today: { Day(now(), calendar: calendar) }, now: now, formats: formats)
    let transactions = TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable(),
      calendar: calendar, today: { Day(now(), calendar: calendar) })
    let editor = TransactionEditorDependencies(
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), rules: SQLiteRuleRepository(database: database),
      settings: SQLiteSettingsRepository(database: database), converter: RateTable(), calendar: calendar,
      now: now)
    return AppSession(
      app: AppModel(environment: environment),
      dashboard: DashboardModel(dependencies: .live(database: database, refresher: refresher)),
      transactions: transactions, editorDependencies: editor, database: database, refresher: refresher)
  }

  /// The app database prepared by `AppBootstrap` (`defaultDatabase`), or the database file at
  /// `path` when given (demos and screenshots that must not touch the real data).
  public static func live(databasePath path: String? = nil) throws -> AppSession {
    if let path {
      let url = URL(filePath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      return live(database: try AbacusDatabase.open(at: url))
    }
    @Dependency(\.defaultDatabase) var database
    return live(database: database)
  }

  /// Synthetic data in memory; nothing is stored or fetched.
  public static func preview(offline: Bool = false) -> AppSession {
    AppSession(
      app: AppModel(environment: .preview(offline: offline)),
      dashboard: DashboardModel(dependencies: .preview(fetchFailed: offline)),
      transactions: .preview(displayCurrency: .UAH), editorDependencies: .preview(), database: nil,
      refresher: nil)
  }

  // MARK: Lifecycle

  /// On launch: settings, then rates — the cache at once, a fetch when auto-refresh is on, and
  /// the daily check while the app runs (R-FX-1). Safe to call more than once.
  public func start() async {
    guard !started else { return }
    started = true
    await app.load()
    transactions.displayCurrency = app.displayCurrency
    transactions.refundsReduceSpending = app.refundsReduceSpending
    guard let refresher else { return }
    await refresher.setAutoRefresh(app.ratesAutoRefresh)
    let updates = await refresher.updates()
    tasks.append(
      Task { [weak self] in
        for await snapshot in updates {
          await self?.ratesChanged(snapshot)
        }
      })
    // The cache loads at once; the fetch runs in the background so a slow network never holds
    // up the window.
    await refresher.loadCache()
    let startup = Task {
      await refresher.start()
    }
    ratesStartup = startup
    tasks.append(startup)
    tasks.append(
      Task {
        await startup.value
        await refresher.runDailySchedule()
      })
  }

  /// Waits for the launch fetch started by `start()` (tests).
  public func waitForLaunchFetch() async {
    await ratesStartup?.value
  }

  /// Stops observing rates and the daily check (tests, teardown).
  public func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
  }

  /// New rates (fetch, lazy history, manual rate): every screen converts with the new table.
  private func ratesChanged(_ snapshot: RateRefresher.Snapshot) async {
    transactions.converter = snapshot.table
    editorDependencies.converter = snapshot.table
    if dashboard.phase == .loaded { await dashboard.refreshRates() }
    await app.rates.load()
  }

  /// After a restore or loading sample data: every screen re-reads the database.
  public func dataChanged() async {
    await refresher?.loadCache()
    await app.load()
    transactions.displayCurrency = app.displayCurrency
    transactions.refundsReduceSpending = app.refundsReduceSpending
    await dashboard.load()
    await transactions.load()
  }

  /// The editor closed: after a save or delete the list and the dashboard re-read the data.
  public func editorFinished(_ result: TransactionEditorResult) async {
    guard result != .cancelled else { return }
    await transactions.reload()
    await dashboard.load()
  }

  // MARK: Sample data

  /// "Load Sample Data": the synthetic preview data set, only into a database without accounts.
  public func loadSampleData() async {
    guard let database else {
      sampleDataMessage = "This window already shows sample data."
      return
    }
    do {
      if try await SampleData.loadIfEmpty(into: database) {
        await dataChanged()
        sampleDataMessage = "Sample data loaded: \(PreviewData.accounts.count) accounts and \(PreviewData.txns.count) transactions."
      } else {
        sampleDataMessage = "Abacus already has accounts. Sample data is only loaded into an empty database."
      }
    } catch {
      sampleDataMessage = "Couldn't load sample data: \(error.localizedDescription)"
    }
  }
}

/// Seeds the synthetic `PreviewData` set (accounts, categories, events, transactions, budget)
/// for demos. Settings and rates are left alone: real rates come from the rate service.
public enum SampleData {
  /// Returns false, changing nothing, when the database already has an account.
  public static func loadIfEmpty(into database: any DatabaseWriter) async throws -> Bool {
    try await database.write { db in
      guard try Account.fetchCount(db) == 0 else { return false }
      try db.seed {
        for account in PreviewData.accounts { account }
        for category in PreviewData.categories { category }
        for event in PreviewData.events { event }
        for txn in PreviewData.txns { txn }
        for record in PreviewData.attachedRecords { record }
        PreviewData.budgetPlan
        for allocation in PreviewData.budgetAllocations { allocation }
      }
      return true
    }
  }
}

/// The database file in use. Moving it is not supported yet (see docs/status/B1.md).
public struct CurrentDataLocation: DataLocationService {
  let url: URL

  public init(database: any DatabaseWriter) {
    url = URL(filePath: database.path)
  }

  public func databaseURL() async -> URL { url }

  public func moveDatabase(to folder: URL) async throws {
    throw DataServiceError.failed("Moving the database to another folder isn't available yet")
  }
}

extension SQLiteBackup: BackupService {}
