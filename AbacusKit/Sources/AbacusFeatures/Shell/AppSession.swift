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
  /// Manage screens (WP B5).
  public let accounts: AccountsModel
  public let categories: CategoriesModel
  public let budget: BudgetEditorModel
  public let events: EventsModel
  public let rules: RulesModel
  /// Debts tab (C14, R-DEBT-5).
  public let debts: DebtsModel
  /// Import wizard (WP B6); nil in previews without a database.
  public let importWizard: ImportWizardModel?
  /// What the transaction editor (WP B4) reads and writes; its converter follows the rates.
  public private(set) var editorDependencies: TransactionEditorDependencies

  /// The result of "Load Sample Data", shown in an alert.
  public var sampleDataMessage: String?

  @ObservationIgnored private let database: (any DatabaseWriter)?
  @ObservationIgnored private let refresher: RateRefresher?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var started = false
  @ObservationIgnored private var ratesStartup: Task<Void, Never>?
  /// Builds a session like this one on another database (data folder moved, R-SET-1).
  @ObservationIgnored var rebuild: (@MainActor (any DatabaseWriter) -> AppSession)?
  /// Set by the app (`AppSessionHost`): shows `next` instead of this session.
  @ObservationIgnored public var onReplace: (@MainActor (AppSession) -> Void)?

  init(
    app: AppModel, dashboard: DashboardModel, transactions: TransactionsViewModel,
    editorDependencies: TransactionEditorDependencies, manage: ManageDependencies,
    debts: DebtsDependencies, database: (any DatabaseWriter)?, refresher: RateRefresher?
  ) {
    self.app = app
    self.dashboard = dashboard
    self.transactions = transactions
    accounts = AccountsModel(dependencies: manage)
    categories = CategoriesModel(dependencies: manage)
    budget = BudgetEditorModel(dependencies: manage)
    events = EventsModel(dependencies: manage)
    rules = RulesModel(dependencies: manage)
    self.debts = DebtsModel(dependencies: debts)
    // Debt records in another currency than the row's account convert at the day's rate (C17).
    importWizard = database.map { database in
      ImportWizardModel(
        dependencies: .live(database: database, converter: { await refresher?.snapshot.table }))
    }
    self.editorDependencies = editorDependencies
    self.database = database
    self.refresher = refresher
    app.data.onRestore = { [weak self] in await self?.dataChanged() }
    // "New transaction" on the Categories page starts with the selected category (R-MGMT-8).
    app.newTransactionCategory = { [weak self] in
      guard let self, self.app.section == .categories, let category = self.categories.selectedCategory,
        !category.isArchived
      else { return nil }
      return category.id
    }
    // … and on the Accounts page with the selected account (D55).
    app.newTransactionAccount = { [weak self] in
      guard let self, self.app.section == .accounts, let account = self.accounts.selectedAccount,
        !account.isArchived
      else { return nil }
      return account.id
    }
    // A category, account or event edited (colour, name, archive): the list and the dashboard
    // follow at once (R-MGMT-7), without waiting for this screen.
    let referenceChanged: @MainActor () async -> Void = { [weak self] in
      Task { await self?.referenceChanged() }
    }
    accounts.onDataChange = referenceChanged
    categories.onDataChange = referenceChanged
    events.onDataChange = referenceChanged
    // A rule applied to existing transactions or rolled back (C9): the list, the dashboard and
    // balances follow at once.
    rules.onTransactionsChange = { [weak self] in
      guard let self else { return }
      await self.transactions.reload()
      await self.dashboard.load()
      await self.reloadManageScreens()
    }
    // A transaction converted to a debt record (R-DEBT-11): balances, dashboard, debts.
    transactions.onDataChange = { [weak self] in
      guard let self else { return }
      await self.dashboard.load()
      await self.reloadManageScreens()
    }
    // A debt record saved or deleted: its leg changed balances, the list and the dashboard.
    self.debts.onDataChange = { [weak self] in
      guard let self else { return }
      await self.transactions.reload()
      await self.dashboard.load()
      await self.reloadManageScreens()
    }
    // A debt leg opened from the transaction list shows its debt (R-DEBT-3).
    app.openDebtLeg = { [weak self] id in
      guard let self, let recordID = self.transactions.rows.first(where: { $0.txn.id == id })?.txn.debtRecordID
      else { return false }
      self.app.section = .debts
      Task { await self.debts.show(recordID: recordID) }
      return true
    }
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
    formats: Formats = Formats(), legacyLastExport: LegacyLastExport = .none,
    locationDefaults: UserDefaults? = nil
  ) -> AppSession {
    let rateStore = SQLiteRateStore(database: database)
    let relay = SessionRelay()
    let defaultsBox = locationDefaults.map(DefaultsBox.init)
    var remember: (@Sendable (URL) -> Void)?
    if let defaultsBox {
      remember = { url in DatabaseLocation.remember(url, in: defaultsBox.defaults) }
    }
    let switchTo: @Sendable (any DatabaseWriter) async -> Bool = { [relay] moved in
      await relay.session?.switchDatabase(to: moved) ?? false
    }
    let location = LiveDataLocation(database: database, remember: remember, switchTo: switchTo)
    let refresher = RateRefresher(store: rateStore, source: source, calendar: calendar, now: now)
    let environment = AppEnvironment(
      settings: SQLiteSettingsRepository(database: database), rateStore: rateStore,
      rates: RefresherRatesService(refresher: refresher), backup: SQLiteBackup(database: database),
      dataLocation: location, legacyLastExport: legacyLastExport,
      today: { Day(now(), calendar: calendar) }, now: now, formats: formats)
    let transactions = TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable(),
      calendar: calendar, today: { Day(now(), calendar: calendar) },
      settings: SQLiteSettingsRepository(database: database),
      debts: SQLiteDebtRepository(database: database, calendar: calendar))
    var editor = TransactionEditorDependencies(
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), rules: SQLiteRuleRepository(database: database),
      settings: SQLiteSettingsRepository(database: database), converter: RateTable(), calendar: calendar,
      now: now)
    // An old day picked in the editor loads its rates (R-EDIT-4, R-FX-1).
    editor.requestRates = { days in
      await refresher.ensureRates(for: days)
      return await refresher.table
    }
    let session = AppSession(
      app: AppModel(environment: environment),
      dashboard: DashboardModel(dependencies: .live(database: database, refresher: refresher)),
      transactions: transactions, editorDependencies: editor,
      manage: .live(database: database, refresher: refresher),
      debts: .live(database: database, refresher: refresher), database: database, refresher: refresher)
    relay.session = session
    session.rebuild = { moved in
      live(
        database: moved, source: source, calendar: calendar, now: now, formats: formats,
        locationDefaults: defaultsBox?.defaults)
    }
    return session
  }

  /// The app database prepared by `AppBootstrap` (`defaultDatabase`), or the database file at
  /// `path` when given (demos and screenshots that must not touch the real data). A demo
  /// database never changes the remembered data folder nor takes over the old last-export date.
  public static func live(databasePath path: String? = nil) throws -> AppSession {
    @Dependency(\.defaultDatabase) var database
    guard let path else {
      return live(database: database, legacyLastExport: .userDefaults(), locationDefaults: .standard)
    }
    let url = URL(filePath: path)
    if url.standardizedFileURL.path == URL(filePath: database.path).standardizedFileURL.path {
      return live(database: database)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return live(database: try AbacusDatabase.open(at: url))
  }

  /// Synthetic data in memory; nothing is stored or fetched.
  public static func preview(offline: Bool = false) -> AppSession {
    AppSession(
      app: AppModel(environment: .preview(offline: offline)),
      dashboard: DashboardModel(dependencies: .preview(fetchFailed: offline)),
      transactions: .preview(displayCurrency: .UAH), editorDependencies: .preview(), manage: .preview(),
      debts: .preview(), database: nil, refresher: nil)
  }

  // MARK: Lifecycle

  /// On launch: settings, then rates — the cache at once, a fetch when auto-refresh is on, and
  /// the daily check while the app runs (R-FX-1). Safe to call more than once.
  public func start() async {
    guard !started else { return }
    started = true
    // First launch: an empty database gets the editable default categories (R-CAT-4).
    if let database { _ = try? await DefaultCategories.seedIfEmpty(database) }
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
    if events.phase == .loaded { await events.refreshRates() }
    if accounts.phase == .loaded { await accounts.refreshRates() }
    if budget.phase == .loaded { await budget.refreshRates() }
    if debts.phase == .loaded { await debts.refreshRates() }
    await app.rates.load()
  }

  /// The data folder moved (R-SET-1): a session on the moved database replaces this one, keeps
  /// the selected section and is started before the window shows it. False when the app did
  /// not install `onReplace` (nothing could show the new session).
  func switchDatabase(to database: any DatabaseWriter) async -> Bool {
    guard let onReplace, let rebuild else { return false }
    let next = rebuild(database)
    next.app.section = app.section
    stop()
    await next.start()
    let folder = URL(filePath: database.path).deletingLastPathComponent()
    next.app.data.announce(DataSettingsModel.movedMessage(folder: folder))
    onReplace(next)
    return true
  }

  /// After a restore or loading sample data: every screen re-reads the database.
  public func dataChanged() async {
    await refresher?.loadCache()
    await app.load()
    transactions.displayCurrency = app.displayCurrency
    transactions.refundsReduceSpending = app.refundsReduceSpending
    await dashboard.load()
    await transactions.load()
    await reloadManageScreens(all: true)
  }

  /// Accounts, categories or events changed on a manage screen.
  public func referenceChanged() async {
    await transactions.referenceChanged()
    if dashboard.phase == .loaded { await dashboard.load() }
  }

  /// Re-reads the manage screens after data changed elsewhere (balances, usage, event totals).
  /// Screens not opened yet load when they appear, unless `all`.
  public func reloadManageScreens(all: Bool = false) async {
    if all || accounts.phase == .loaded { await accounts.load() }
    if all || categories.phase == .loaded { await categories.load() }
    if all { await budget.load() } else if budget.phase == .loaded { await budget.reappeared() }
    if all || events.phase == .loaded { await events.load() }
    if all || rules.phase == .loaded { await rules.load() }
    if all || debts.phase == .loaded { await debts.load() }
  }

  /// Switching to a section re-reads it if it was shown before, so edits made on other screens
  /// (an account renamed, a category moved) appear without a relaunch.
  public func sectionAppeared(_ section: AppSection) async {
    switch section {
    case .dashboard: if dashboard.phase == .loaded { await dashboard.load() }
    case .transactions: await transactions.load()
    case .accounts: if accounts.phase == .loaded { await accounts.load() }
    case .categories: if categories.phase == .loaded { await categories.load() }
    case .budget: if budget.phase == .loaded { await budget.reappeared() }
    case .events: if events.phase == .loaded { await events.load() }
    case .rules: if rules.phase == .loaded { await rules.load() }
    case .rates: await app.rates.load()
    case .debts: await debts.load()
    case .importFiles: break
    }
  }

  /// An event's "Show N transactions": the list filtered to that event (R-EVT-3).
  public func showTransactions(ofEvent id: Event.ID) {
    guard let event = events.events.first(where: { $0.id == id }) else { return }
    app.showTransactions(.event(event))
  }

  /// An import's "Show transactions" (done step, history): the list filtered to the
  /// transactions that import created (R-IMP-6).
  public func showTransactions(ofImport id: ImportBatch.ID) {
    guard let wizard = importWizard else { return }
    let batch = wizard.history.first { $0.id == id } ?? wizard.summary.map(\.batch).flatMap { $0.id == id ? $0 : nil }
    guard let batch else { return }
    app.showTransactions(.importBatch(batch))
  }

  /// The editor closed: after a save or delete the list and the dashboard re-read the data.
  public func editorFinished(_ result: TransactionEditorResult) async {
    guard result != .cancelled else { return }
    await transactions.reload()
    await dashboard.load()
    await reloadManageScreens()
  }

  // MARK: Sample data

  /// The large synthetic set (`LargeSampleData`, S1 performance checks), only into a database
  /// without accounts. DEBUG launch option `-AbacusLoadLargeSampleData YES`.
  public func loadLargeSampleData() async {
    guard let database else { return }
    do {
      if try await LargeSampleData.loadIfEmpty(into: database) {
        await dataChanged()
      }
    } catch {
      sampleDataMessage = "Couldn't load the large sample data: \(error.localizedDescription)"
    }
  }

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
/// Categories already in the database (the default set, R-CAT-4) are reused by name.
public enum SampleData {
  /// Returns false, changing nothing, when the database already has an account.
  public static func loadIfEmpty(into database: any DatabaseWriter) async throws -> Bool {
    try await database.write { db in
      guard try Account.fetchCount(db) == 0 else { return false }
      try seed(db)
      return true
    }
  }
}

/// Hands the data folder move to the session once it exists (it is built after its services).
@MainActor
final class SessionRelay {
  weak var session: AppSession?
}

extension SQLiteBackup: BackupService {}
