import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@MainActor
@Suite("Shell and settings (B1)")
struct AppModelTests {
  @Test("R-HOME-4 display currency defaults to UAH")
  func displayCurrencyDefault() async {
    let app = AppModel(environment: B1Fixture.setup().environment)
    await app.load()
    #expect(app.displayCurrency == .UAH)

    let broken = AppModel(environment: B1Fixture.setup(settings: [.displayCurrency: "XYZ"]).environment)
    await broken.load()
    #expect(broken.displayCurrency == .UAH)
  }

  @Test("R-HOME-4 display currency is remembered across launches")
  func displayCurrencyRemembered() async {
    let setup = B1Fixture.setup()
    let app = AppModel(environment: setup.environment)
    await app.load()
    await app.setDisplayCurrency(.EUR).value
    #expect(app.displayCurrency == .EUR)
    #expect(await setup.settings.values[.displayCurrency] == "EUR")

    let relaunched = AppModel(environment: setup.environment)
    await relaunched.load()
    #expect(relaunched.displayCurrency == .EUR)
    #expect(relaunched.rates.showIn == .EUR)
  }

  @Test("R-SET-3 refunds reduce spending: off by default, persisted, hint follows the toggle")
  func refundsSetting() async {
    let setup = B1Fixture.setup()
    let app = AppModel(environment: setup.environment)
    await app.load()
    #expect(app.refundsReduceSpending == false)
    #expect(app.refundsHint.hasPrefix("Off (default): a refund counts as income"))
    await app.setRefundsReduceSpending(true).value
    #expect(await setup.settings.values[.refundsReduceSpending] == "true")
    #expect(app.refundsHint == "On: a refund is subtracted from its category’s spending and budget.")

    let relaunched = AppModel(environment: setup.environment)
    await relaunched.load()
    #expect(relaunched.refundsReduceSpending)
  }

  @Test("R-SET-1 rates update automatically by default; turning it off is persisted and passed on")
  func autoRefreshSetting() async {
    let setup = B1Fixture.setup()
    let app = AppModel(environment: setup.environment)
    await app.load()
    #expect(app.ratesAutoRefresh)
    #expect(app.autoRatesHint == "On launch and once a day while Abacus is open.")
    await app.setRatesAutoRefresh(false).value
    #expect(await setup.settings.values[.ratesAutoRefresh] == "false")
    #expect(await setup.service.status().autoRefresh == false)
    #expect(app.autoRatesHint == "Only when you click “Refresh rates”.")
  }

  @Test("R-SET-1 the Rates tab counts manual rates")
  func manualRateCount() async {
    let one = AppModel(environment: B1Fixture.setup(overrides: [B1Fixture.override(.EUR, .UAH, "48", from: "2026-10-01")]).environment)
    await one.load()
    #expect(one.manualRateCountText == "1 manual rate")
    let none = AppModel(environment: B1Fixture.setup().environment)
    await none.load()
    #expect(none.manualRateCountText == "0 manual rates")
  }

  @Test("R-FX-4 the toolbar shows which day's rates converted figures use")
  func ratesAsOf() async {
    let app = AppModel(environment: B1Fixture.setup().environment)
    #expect(app.ratesAsOfLabel == "No rates yet")
    await app.load()
    #expect(app.ratesAsOfLabel == "NBU rates · 20 Oct 2026")
  }

  @Test("New transaction and drill-down hooks route to the editor and the list")
  func hooks() {
    let app = AppModel(environment: B1Fixture.setup().environment)
    #expect(app.editor == nil)
    app.requestNewTransaction()
    #expect(app.editor == .new)
    app.editTransaction(PreviewData.id(404))
    #expect(app.editor == .edit(PreviewData.id(404)))

    let filters = TransactionFilters.drillDown(category: PreviewData.id(202), month: Month(year: 2026, month: 10))
    app.showTransactions(filters)
    #expect(app.section == .transactions)
    #expect(app.pendingTransactionFilters == filters)
  }

  @Test("R-HOME-2 the budget card's edit button opens Budget")
  func openBudget() {
    let app = AppModel(environment: B1Fixture.setup().environment)
    #expect(app.section == .dashboard)
    app.openBudget()
    #expect(app.section == .budget)
    #expect(app.pendingTransactionFilters == nil)
  }

  @Test("R-HOME-4 the display-currency switch shows on Dashboard, Transactions, Accounts, Events, Budget")
  func displayCurrencySections() {
    let shown = AppSection.allCases.filter(\.usesDisplayCurrency)
    #expect(Set(shown) == [.dashboard, .transactions, .accounts, .events, .budget])
  }

  @Test("TA v1.6: no New transaction button on Budget and Rules; switch order EUR, USD, PLN, UAH")
  func newTransactionSectionsAndCurrencyOrder() {
    let hidden = AppSection.allCases.filter { !$0.offersNewTransaction }
    #expect(Set(hidden) == [.budget, .rules])
    #expect(Currency.displayOrder == [.EUR, .USD, .PLN, .UAH])
    #expect(Set(Currency.displayOrder) == Set(Currency.allCases))
  }

  @Test("Sidebar order: Overview then Manage, nine sections for ⌘1…⌘9")
  func sectionOrder() {
    #expect(AppModel.sectionsInOrder.map(\.title) == [
      "Dashboard", "Transactions", "Events", "Accounts", "Categories", "Budget", "Import", "Exchange rates", "Rules",
    ])
  }
}

@MainActor
@Suite("Settings › Data (B1)")
struct DataSettingsModelTests {
  @Test("R-SET-2 export writes the backup and records the export date")
  func export() async {
    let setup = B1Fixture.setup(now: B1Fixture.at(15))
    let data = DataSettingsModel(environment: setup.environment)
    await data.load()
    #expect(data.backupNote.hasSuffix("Not exported yet."))
    #expect(data.suggestedBackupName == "abacus-backup-2026-10-21.abacus")
    let url = URL(filePath: "/tmp/abacus-backup-2026-10-21.abacus")
    await data.export(to: url)
    #expect(await setup.backup.exports == [url])
    #expect(data.lastExport == B1Fixture.today)
    #expect(await setup.settings.values[.lastBackupExport] == "2026-10-21")
    #expect(data.backupNote.hasSuffix("Last export: 21 Oct 2026."))
    #expect(data.messageIsError == false)
  }

  @Test("R-SET-2 restore asks first, replaces all data on confirm, then reloads the app")
  func restore() async {
    let setup = B1Fixture.setup()
    let app = AppModel(environment: setup.environment)
    await app.load()
    let url = URL(filePath: "/tmp/abacus-backup-2026-10-14.abacus")
    app.data.askRestore(from: url)
    #expect(app.data.restoreTitle == "Replace all data with “abacus-backup-2026-10-14.abacus”?")
    #expect(await setup.backup.restores.isEmpty)

    // The backup holds another display currency: after the restore the app shows it.
    try? await setup.settings.set(.displayCurrency, "PLN")
    await app.data.confirmRestore()
    #expect(await setup.backup.restores == [url])
    #expect(app.data.pendingRestore == nil)
    #expect(app.displayCurrency == .PLN)
  }

  @Test("R-SET-2 cancelling the confirmation changes nothing")
  func cancelRestore() async {
    let setup = B1Fixture.setup()
    let data = DataSettingsModel(environment: setup.environment)
    data.askRestore(from: URL(filePath: "/tmp/x.abacus"))
    data.cancelRestore()
    await data.confirmRestore()
    #expect(await setup.backup.restores.isEmpty)
  }

  @Test("R-SET-2 a failing backup reports an error and keeps the data")
  func failure() async {
    let setup = B1Fixture.setup(backupFailure: .failed("Not an Abacus backup"))
    let data = DataSettingsModel(environment: setup.environment)
    data.askRestore(from: URL(filePath: "/tmp/x.abacus"))
    await data.confirmRestore()
    #expect(data.messageIsError)
    #expect(data.message == "Couldn't restore the backup: Not an Abacus backup. Nothing was changed.")
    await data.export(to: URL(filePath: "/tmp/y.abacus"))
    #expect(data.lastExport == nil)
  }

  @Test("R-SET-1 the data folder is shown with ~ and can be changed")
  func dataFolder() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let setup = B1Fixture.setup()
    let location = PreviewDataLocationService(url: home.appending(path: "Library/Application Support/Abacus/abacus.sqlite"))
    var env = setup.environment
    env.dataLocation = location
    let data = DataSettingsModel(environment: env)
    await data.load()
    #expect(data.databasePath == "~/Library/Application Support/Abacus/abacus.sqlite")
    await data.moveDatabase(to: URL(filePath: "/Volumes/Backup/Finance", directoryHint: .isDirectory))
    #expect(await location.moves.count == 1)
    #expect(data.databasePath == "/Volumes/Backup/Finance/abacus.sqlite")
  }
}
