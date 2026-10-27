import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Synchronization
import Testing

@MainActor
@Suite("Manage · Budget")
struct ManageBudgetTests {
  let store = ManagePreviewStore.sample()
  let october = Month(year: 2026, month: 10)
  let november = Month(year: 2026, month: 11)

  func model() async -> BudgetEditorModel {
    let model = BudgetEditorModel(dependencies: ManageFixture.dependencies(store))
    await model.load()
    return model
  }

  func uah(_ minor: Int64) -> String { ManageFixture.format.money(Money(minorUnits: minor, currency: .UAH)) }
  func pln(_ minor: Int64) -> String { ManageFixture.format.money(Money(minorUnits: minor, currency: .PLN)) }
  let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)

  @Test("R-MGMT-3, R-BUD-1, D46: the editor loads the total and each limit in its own currency; sums in the display currency")
  func loadsPlan() async throws {
    let model = await model()
    #expect(model.appliesFrom == october)
    #expect(model.displayCurrency == .UAH)
    #expect(model.totalLimit == "8000.00")
    #expect(model.totalCurrency == .PLN)
    #expect(model.total == Money(minorUnits: 8_000_00, currency: .PLN))
    #expect(model.rows.map(\.name) == ["Groceries", "Eating out", "Rent", "Transport", "Health"])
    #expect(model.rows.map(\.currency) == [.PLN, .PLN, .PLN, .PLN, .EUR])
    #expect(model.rows.first { $0.name == "Transport" }?.covers == "incl. Taxi, Fuel")
    #expect(model.rows.first { $0.name == "Rent" }?.covers == "")
    // zł6,800 at 11.30 + €110 at 48.50 (the latest preview rates).
    #expect(model.limitsSumMinor == Int64(76_840_00 + 5_335_00))
    // The total: zł8,000 at 11.30.
    #expect(model.totalMinor == 90_400_00)
    #expect(model.totalText == uah(90_400_00))
    #expect(model.totalNote == "Total limit \(pln(8_000_00)) at the latest rate")
    #expect(model.rows.first { $0.name == "Rent" }?.share == 0.5)
    // Unallocated = zł8,000 − zł6,800 − €110 in złoty at the latest rate.
    let health = try #require(rates.convertAtLatest(Money(minorUnits: 110_00, currency: .EUR), to: .PLN))
    #expect(model.unallocated == Money(minorUnits: 1_200_00 - health.minorUnits, currency: .PLN))
    #expect(model.unallocatedShown == rates.convertAtLatest(model.unallocated!, to: .UAH))
    #expect(model.unallocatedNote == "Other categories and uncategorised spending")
    #expect(model.currenciesWithoutRate.isEmpty)
    #expect(!model.canSave)
  }

  @Test("R-BUD-1, D46: the display currency switch converts the sums; inputs keep their currencies")
  func displayCurrencySwitch() async {
    let model = await model()
    model.setDisplayCurrency(.PLN)
    #expect(model.totalMinor == 8_000_00)
    #expect(model.totalNote == "The total limit")
    #expect(model.unallocatedShown == model.unallocated)
    #expect(model.rows.first { $0.name == "Rent" }?.share == 0.5)
    #expect(model.rows.map(\.currency) == [.PLN, .PLN, .PLN, .PLN, .EUR])
    #expect(model.limitText(PreviewData.id(205)) == "4000.00")
    #expect(!model.isDirty)
    // A reload keeps the switched currency.
    await model.load()
    #expect(model.displayCurrency == .PLN)
  }

  @Test("R-BUD-1, D46: no total (empty or 0) = the sum of the limits; limits above the total show a negative unallocated")
  func totalField() async {
    let model = await model()
    model.totalLimit = ""
    #expect(model.total == nil)
    #expect(!model.hasTotal)
    #expect(model.unallocated == nil)
    #expect(model.totalMinor == Int64(82_175_00))
    #expect(model.totalNote == "No total set: the sum of the limits at the latest rate")
    model.totalLimit = "0"
    #expect(model.total == nil)
    #expect(model.validationMessage == nil)
    model.totalLimit = "1000"
    model.totalCurrency = .EUR
    #expect(model.total == Money(minorUnits: 1_000_00, currency: .EUR))
    #expect(model.unallocated.map { $0.minorUnits < 0 } == true)
    #expect(model.unallocatedNote.hasPrefix("The limits exceed the total by "))
    model.totalLimit = "lots"
    #expect(model.validationMessage == "The total limit is not a valid amount.")
    #expect(!model.canSave)
  }

  @Test("R-MGMT-3, D46: saving writes the total and its currency; 0 when no total is set")
  func savesTotal() async throws {
    let model = await model()
    model.totalLimit = "2500"
    model.totalCurrency = .EUR
    #expect(model.canSave)
    await model.save()
    let saved = try #require(try await store.budgetRepository.plan(for: october))
    #expect(saved.plan.total == Money(minorUnits: 2_500_00, currency: .EUR))
    await model.load()
    #expect(model.totalLimit == "2500.00")
    #expect(model.totalCurrency == .EUR)
    model.totalLimit = ""
    await model.save()
    let cleared = try #require(try await store.budgetRepository.plan(for: october))
    #expect(cleared.plan.totalMinor == 0)
    #expect(cleared.plan.total == nil)
  }

  @Test("R-MGMT-10: Revert restores what was loaded; showing the screen again keeps unsaved edits")
  func revertAndReappear() async {
    let model = await model()
    model.setCurrency(.EUR, for: PreviewData.id(205))
    model.setLimit("4100", for: PreviewData.id(205))
    model.totalLimit = "9000"
    #expect(model.isDirty)
    await model.reappeared()
    #expect(model.isDirty)
    #expect(model.currency(PreviewData.id(205)) == .EUR)
    #expect(model.limitText(PreviewData.id(205)) == "4100")
    await model.revert()
    #expect(!model.isDirty)
    #expect(model.currency(PreviewData.id(205)) == .PLN)
    #expect(model.limitText(PreviewData.id(205)) == "4000.00")
    #expect(model.totalLimit == "8000.00")
  }

  @Test("R-MGMT-3, D43: a limit's currency can be changed and becomes the default for the next limit")
  func currencyPerLimit() async {
    let model = await model()
    #expect(model.newLimitCurrency == .EUR)  // the last limit loaded (Health)
    model.setCurrency(.USD, for: PreviewData.id(205))
    #expect(model.currency(PreviewData.id(205)) == .USD)
    #expect(model.newLimitCurrency == .USD)
    #expect(model.canSave)
    model.categoryToAdd = PreviewData.id(212)
    model.addLimit()
    #expect(model.rows.last?.name == "Clothing")
    #expect(model.rows.last?.currency == .USD)
  }

  @Test("R-MGMT-3, D43: an empty budget's first limit is in the display currency")
  func firstLimitInDisplayCurrency() async {
    let empty = ManagePreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, settings: PreviewData.settings)
    let model = BudgetEditorModel(dependencies: ManageFixture.dependencies(empty))
    await model.load()
    #expect(model.rows.isEmpty)
    #expect(model.totalText == uah(0))
    #expect(model.newLimitCurrency == .UAH)
    model.addLimit()
    #expect(model.rows.first?.currency == .UAH)
    #expect(model.totalCurrency == .UAH)
    #expect(model.totalNote == "No total set: the sum of the limits")
  }

  @Test("D27, D43: a limit without a rate to the display currency is left out of the total and named")
  func limitWithoutRate() async {
    let noRates = ManageDependencies.preview(
      store: store, rates: RateTable(rates: [], today: PreviewData.today), format: ManageFixture.format)
    let model = BudgetEditorModel(dependencies: noRates)
    await model.load()
    #expect(model.totalMinor == nil)  // the total (zł) has no rate either
    #expect(model.totalText == "—")
    #expect(model.limitsSumMinor == 0)
    #expect(model.currenciesWithoutRate == [.PLN, .EUR])
    #expect(model.totalNote == "No PLN, EUR→UAH rate: those amounts are not counted")
    #expect(model.rows.allSatisfy { $0.share == 0 })
  }

  @Test("R-FX-1, D43: rates arriving after the screen loaded fill in the total; edits are kept")
  func ratesArriveLater() async {
    let current = Mutex(RateTable(rates: [], today: PreviewData.today))
    var dependencies = ManageFixture.dependencies(store)
    dependencies.converter = { current.withLock { $0 } }
    let model = BudgetEditorModel(dependencies: dependencies)
    await model.load()
    #expect(model.limitsSumMinor == 0)
    model.setLimit("4100", for: PreviewData.id(205))
    current.withLock { $0 = RateTable(rates: PreviewData.fxRates, today: PreviewData.today) }
    await model.refreshRates()
    #expect(model.limitsSumMinor == Int64(82_175_00 + 1_130_00))
    #expect(model.totalMinor == 90_400_00)
    #expect(model.limitText(PreviewData.id(205)) == "4100")
  }

  @Test("R-BUD-1, R-MGMT-8: category limits can be added and removed; the picker is A–Z without used or archived categories")
  func addRemove() async throws {
    let model = await model()
    let options = model.addOptions.map(\.name)
    #expect(!options.contains("Rent"))
    #expect(options.contains("Food"))
    let titles = model.addOptions.map(model.addOptionTitle)
    #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    #expect(titles.contains { $0.contains(" › ") })
    model.categoryToAdd = PreviewData.id(212)
    model.addLimit()
    #expect(model.rows.last?.name == "Clothing")
    #expect(model.limitText(PreviewData.id(212)) == "0.00")
    #expect(!model.addOptions.contains { $0.name == "Clothing" })
    model.removeLimit(PreviewData.id(209))
    #expect(!model.rows.contains { $0.name == "Health" })
    #expect(model.limitsSumMinor == Int64(82_175_00 - 5_335_00))  // €110 at 48.50
    #expect(model.totalMinor == 90_400_00)  // the total stays
  }

  @Test("R-BUD-3: saving applies from the chosen month on; earlier months keep their budget")
  func savesFromMonth() async throws {
    let model = await model()
    await model.setAppliesFrom(november)
    model.setLimit("150", for: PreviewData.id(209))
    model.setCurrency(.USD, for: PreviewData.id(206))
    #expect(model.canSave)
    await model.save()
    #expect(model.savedMessage == "Saved. It applies from November 2026.")
    #expect(!model.isDirty)
    let budget = store.budgetRepository
    let oct = try #require(try await budget.plan(for: october))
    #expect(oct.allocations.first { $0.categoryID == PreviewData.id(209) }?.limit == Money(minorUnits: 110_00, currency: .EUR))
    #expect(oct.allocations.first { $0.categoryID == PreviewData.id(206) }?.currency == .PLN)
    let nov = try #require(try await budget.plan(for: november))
    #expect(nov.allocations.count == 5)
    #expect(nov.allocations.first { $0.categoryID == PreviewData.id(209) }?.limit == Money(minorUnits: 150_00, currency: .EUR))
    #expect(nov.allocations.first { $0.categoryID == PreviewData.id(206) }?.limit == Money(minorUnits: 400_00, currency: .USD))
    let dec = try #require(try await budget.plan(for: november.adding(months: 1)))
    #expect(dec.plan.id == nov.plan.id)
  }

  @Test("R-BUD-3, D29: saving again for the same month replaces that month's plan; a later plan is kept and noted")
  func replacesSameMonth() async throws {
    let model = await model()
    let rent = PreviewData.id(205)
    func rentLimit(_ month: Month) async throws -> Int64? {
      try await store.budgetRepository.plan(for: month)?.allocations.first { $0.categoryID == rent }?.limitMinor
    }
    await model.setAppliesFrom(november.adding(months: 2))
    model.setLimit("3000", for: rent)
    await model.save()
    await model.setAppliesFrom(november)
    #expect(model.laterPlanMonth == november.adding(months: 2))
    #expect(model.appliesNote.hasSuffix("From January 2027 the budget saved for that month applies."))
    model.setLimit("3100", for: rent)
    await model.save()
    model.setLimit("3200", for: rent)
    await model.save()
    #expect(store.budgetRepository.plans().map(\.effectiveMonth) == ["2026-01", "2026-11", "2027-01"])
    #expect(try await rentLimit(november) == 3_200_00)
    #expect(try await rentLimit(november.adding(months: 2)) == 3_000_00)
  }

  @Test("R-BUD-3: Applies from offers this month and later only")
  func monthOptions() async {
    let model = await model()
    #expect(model.monthOptions.first == october)
    #expect(model.monthOptions.count == 12)
    #expect(model.monthTitle(november) == "November 2026")
  }

  @Test("R-MGMT-3: an invalid limit cannot be saved")
  func validation() async {
    let model = await model()
    model.setLimit("lots", for: PreviewData.id(205))
    #expect(model.validationMessage == "A category limit is not a valid amount.")
    #expect(model.totalText == "—")
    #expect(!model.canSave)
    model.setLimit("-5", for: PreviewData.id(205))
    #expect(model.validationMessage == "A category limit is not a valid amount.")
    model.setLimit("4000", for: PreviewData.id(205))
    #expect(model.validationMessage == nil)
  }
}

@MainActor
@Suite("Manage · Events")
struct ManageEventsTests {
  let store = ManagePreviewStore.sample()
  let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)

  func model(_ currency: Currency = .UAH) async -> EventsModel {
    let model = EventsModel(dependencies: ManageFixture.dependencies(store), displayCurrency: currency)
    await model.load()
    return model
  }

  func expectedTotals(_ event: Event, currency: Currency) async throws -> EventTotals {
    Calc.eventTotals(
      event: event, accounts: PreviewData.accounts, categories: PreviewData.categories,
      txns: try await store.txnRepository.transactions(matching: TxnQuery()), currency: currency,
      converter: rates, refundsReduceSpending: false)
  }

  @Test("R-MGMT-4, R-EVT-1: events list dates, spent and budget; a budget event is shown in its currency")
  func list() async throws {
    let model = await model()
    #expect(model.rows.map(\.name) == ["Lyon trip", "Car", "Relocation"])
    let lyon = model.rows[0]
    #expect(lyon.dates == "01.10 – 19.10.2026")
    #expect(lyon.budgetText == "of €300.00 budget")
    let expected = try await expectedTotals(ManageSample.lyonTrip, currency: .EUR)
    #expect(lyon.spentText == ManageFixture.format.money(expected.spent))
    #expect(lyon.status == .ok)
    let car = model.rows[1]
    #expect(car.dates == "No dates (ongoing)")
    #expect(car.budgetText == "no budget")
    #expect(car.spentText.hasPrefix("₴"))
  }

  @Test("R-EVT-3, R-EVT-4: the inspector shows spent by top-level category and opens the event's transactions")
  func spending() async throws {
    let model = await model(.PLN)
    model.select(ManageSample.car.id)
    #expect(model.spentText == ManageFixture.format.money(Money(minorUnits: 1_030_00, currency: .PLN)))
    #expect(model.categoryBars.map(\.name) == ["Transport"])
    #expect(model.categoryBars.first?.fraction == 1)
    #expect(model.showTransactionsTitle == "Show 2 transactions")
    #expect(model.transactionsQuery == TxnQuery(eventIDs: [ManageSample.car.id]))
    #expect(model.missingRatesNote == nil)
    model.select(ManageSample.lyonTrip.id)
    #expect(model.spentText.hasSuffix(" of €300.00"))
  }

  @Test("R-EVT-3: switching the display currency recomputes events without a budget")
  func displayCurrency() async throws {
    let model = await model(.UAH)
    let before = model.rows.first { $0.id == ManageSample.car.id }?.spentText
    model.setDisplayCurrency(.PLN)
    let after = model.rows.first { $0.id == ManageSample.car.id }?.spentText
    #expect(before != after)
    #expect(model.rows.first?.budgetText == "of €300.00 budget")
  }

  @Test("R-MGMT-4, R-EVT-1: events are created and edited with optional dates and budget")
  func createEdit() async throws {
    let model = await model()
    model.newEvent()
    #expect(model.inspectorTitle == "New event")
    model.draft?.name = "Ski week"
    model.draft?.hasStart = true
    model.draft?.start = Day("2027-01-10")!.date()
    model.draft?.hasEnd = true
    model.draft?.end = Day("2027-01-03")!.date()
    #expect(model.validationMessage == "The event ends before it starts.")
    model.draft?.end = Day("2027-01-17")!.date()
    model.draft?.budget = "2,000"
    model.draft?.budgetCurrency = .EUR
    #expect(model.canSave)
    await model.save()
    let saved = try #require(try await store.eventRepository.events(includeArchived: false).first { $0.name == "Ski week" })
    #expect(saved.startDay == "2027-01-10")
    #expect(saved.endDay == "2027-01-17")
    #expect(saved.budgetMinor == 2_000_00)
    #expect(saved.budgetCurrency == .EUR)
    #expect(model.selection == saved.id)
    #expect(model.rows.first?.name == "Ski week")

    model.draft?.budget = ""
    model.draft?.hasEnd = false
    await model.save()
    let edited = try #require(model.event(saved.id))
    #expect(edited.budgetMinor == nil)
    #expect(edited.budgetCurrency == nil)
    #expect(edited.endDay == nil)
    #expect(model.rows.first?.dates == "From 10.01.2027")
  }

  @Test("R-MGMT-4: events are archived, shown with “Show archived”, and unarchived")
  func archive() async throws {
    let model = await model()
    model.select(PreviewData.relocation.id)
    await model.archiveOrUnarchive()
    #expect(model.event(PreviewData.relocation.id)?.isArchived == true)
    #expect(model.rows.first { $0.id == PreviewData.relocation.id }?.isArchived == true)
    model.setShowArchived(false)
    #expect(!model.rows.contains { $0.id == PreviewData.relocation.id })
    model.setShowArchived(true)
    model.select(PreviewData.relocation.id)
    #expect(model.archiveTitle == "Unarchive")
    await model.archiveOrUnarchive()
    #expect(model.event(PreviewData.relocation.id)?.isArchived == false)
  }

  @Test("R-MGMT-4, R-EVT-2: deleting an event keeps its transactions without the tag")
  func delete() async throws {
    let model = await model()
    model.select(ManageSample.car.id)
    model.requestDelete()
    #expect(model.dialog?.message == "Its 2 transactions stay; they are no longer tagged with this event.")
    await model.confirmDialog()
    #expect(model.event(ManageSample.car.id) == nil)
    let txns = try await store.txnRepository.transactions(matching: TxnQuery())
    #expect(txns.contains { $0.txn.id == PreviewData.id(911) && $0.txn.eventID == nil })
  }
}

@MainActor
@Suite("Manage · Rules")
struct ManageRulesTests {
  let store = ManagePreviewStore.sample()

  func model(probe: String = "") async -> RulesModel {
    let model = RulesModel(dependencies: ManageFixture.dependencies(store), probe: probe)
    await model.load()
    return model
  }

  @Test("R-IMP-8: the tester finds the first enabled rule the description contains, ignoring case")
  func tester() async {
    let model = await model(probe: "BIEDRONKA 1234 WARSZAWA")
    #expect(model.match?.pattern == "biedronka")
    #expect(model.probeResult == "Matches “biedronka” → Food › Groceries")
    #expect(model.rows.filter(\.isMatch).map(\.pattern) == ["biedronka"])
    model.probe = "Spotify"
    #expect(model.match == nil)
    #expect(model.probeResult == "No rule matches; the category stays empty for you to pick.")
    model.probe = ""
    #expect(model.probeResult == "")
  }

  @Test("R-IMP-8: the first match wins and disabled rules are skipped")
  func firstMatchWins() async throws {
    let model = await model(probe: "LIDL ORANGE")
    #expect(model.match?.pattern == "lidl")
    await model.setEnabled(PreviewData.id(952), false)
    #expect(model.rules.first { $0.id == PreviewData.id(952) }?.isEnabled == false)
    #expect(model.match?.pattern == "orange")
    #expect(try await store.ruleRepository.rules().first { $0.pattern == "lidl" }?.isEnabled == false)
  }

  @Test("R-IMP-8: a per-account rule applies only to its account")
  func perAccount() async {
    let model = await model(probe: "ORLEN STACJA 12")
    #expect(model.match?.pattern == "orlen")
    model.probeAccountID = PreviewData.pkoPersonal.id
    #expect(model.match == nil)
    model.probeAccountID = PreviewData.pkoCreditCard.id
    #expect(model.match?.pattern == "orlen")
  }

  @Test("R-MGMT-6, D44: rows show each rule in words, origin and hit count in evaluation order")
  func rows() async {
    let model = await model()
    #expect(model.rows.map(\.pattern) == [
      "biedronka", "lidl", "bolt.eu", "orlen", "orange", "farmacja", "zalando", "pizzeria napoli", "friend",
    ])
    let orlen = model.rows[3]
    #expect(orlen.summary == "Description contains “orlen” on PKO Credit Card → Transport › Fuel")
    #expect(orlen.origin == "Manual")
    #expect(orlen.hits == 9)
    #expect(model.rows[0].summary == "Description contains “biedronka” → Food › Groceries")
    #expect(model.rows[0].origin == "Learned from an import")
    #expect(model.rows[5].action == "Health")
    #expect(model.rows[6].summary == "Description contains “zalando” and amount bigger than 100.00 → Clothing")
    #expect(model.rows[7].condition == "Description is exactly “pizzeria napoli” on Monobank Black")
    #expect(model.rows[8].summary == "Description contains “friend” → Transfer to/from Loan from friend")
  }

  @Test("R-IMP-8, D44: the tester uses the amount and shows transfer actions")
  func testerAmountAndTransfer() async {
    let model = await model(probe: "ZALANDO SE")
    #expect(model.match == nil)
    model.probeAmountText = "120"
    #expect(model.match?.pattern == "zalando")
    model.probeAmountText = "80"
    #expect(model.match == nil)
    model.probe = "Pizzeria  Napoli"
    model.probeAmountText = ""
    #expect(model.match?.pattern == "pizzeria napoli")
    model.probe = "Pizzeria Napoli Lyon"
    #expect(model.match == nil)
    model.probe = "Payback to a friend"
    #expect(model.probeResult == "Matches “friend” → Transfer to/from Loan from friend")
    model.probeAccountID = PreviewData.loanFromFriend.id
    #expect(model.match == nil)
  }

  @Test("R-MGMT-6, D44: the editor adds AND conditions, validates and saves a transfer rule")
  func editorConditionsAndTransfer() async throws {
    let model = await model()
    model.newRule()
    model.editor?.pattern = "Rent"
    model.editor?.matchKind = .exactly
    model.editor?.hasAmountCondition = true
    #expect(model.editorValidation == "Enter the amount.")
    model.editor?.amountText = "1 000,50"
    model.editor?.amountComparison = .smallerThan
    model.editor?.hasAccountCondition = true
    #expect(model.editorValidation == "Choose the account.")
    model.editor?.accountID = PreviewData.pkoPersonal.id
    #expect(model.editor?.canAddCondition == false)
    model.editor?.action = .transfer
    #expect(model.editorValidation == "Choose the account to transfer to or from.")
    model.editor?.transferAccountID = PreviewData.pkoPersonal.id
    #expect(model.editorValidation == "The transfer account must differ from the account in the condition.")
    model.editor?.transferAccountID = PreviewData.cashPLN.id
    #expect(model.editorValidation == nil)
    await model.saveEditor()
    let saved = try #require(model.rules.last)
    #expect(saved.matchKind == .exactly)
    #expect(saved.amountComparison == .smallerThan)
    #expect(saved.amountMinor == 1_000_50)
    #expect(saved.accountID == PreviewData.pkoPersonal.id)
    #expect(saved.action == .transfer)
    #expect(saved.categoryID == nil)
    #expect(saved.transferAccountID == PreviewData.cashPLN.id)
    #expect(model.rows.last?.summary == "Description is exactly “Rent” and amount smaller than 1000.50 on PKO Personal → Transfer to/from Cash PLN")

    // Editing it back to a category rule drops the transfer account; removing a condition drops it.
    model.edit(saved.id)
    #expect(model.editor?.amountText == "1000.50")
    model.editor?.hasAmountCondition = false
    model.editor?.action = .category
    model.editor?.categoryID = PreviewData.id(205)
    await model.saveEditor()
    let edited = try #require(model.rules.first { $0.id == saved.id })
    #expect(edited.amountComparison == nil && edited.amountMinor == nil)
    #expect(edited.transferAccountID == nil)
    #expect(edited.categoryID == PreviewData.id(205))
  }

  @Test("R-MGMT-6: Save & apply shows how many transactions change, applies after confirmation and can be undone")
  func applyToExisting() async throws {
    let model = await model()
    model.newRule()
    model.editor?.pattern = "auchan"
    model.editor?.action = .transfer
    model.editor?.transferAccountID = PreviewData.cashPLN.id
    model.editor?.updateExisting = true
    await model.loadEditorTransactions()
    #expect(model.editorChangesText == "1 transaction will change")
    await model.saveEditor()
    let confirmation = try #require(model.confirmation)
    #expect(confirmation.title == "Update 1 transaction?")
    #expect(model.editor != nil)
    // Nothing is written before the confirmation.
    #expect(try await store.txnRepository.transaction(PreviewData.id(416))?.txn.type == .expense)

    await model.confirmApply()
    #expect(model.editor == nil)
    let auchan = try #require(try await store.txnRepository.transaction(PreviewData.id(416))?.txn)
    #expect(auchan.type == .transfer)
    #expect(auchan.accountID == PreviewData.pkoPersonal.id)
    #expect(auchan.toAccountID == PreviewData.cashPLN.id)
    #expect(auchan.toAmountMinor == 142_30)
    #expect(auchan.categoryID == nil)
    #expect(model.rules.last?.pattern == "auchan")
    #expect(model.lastApply?.message == "1 transaction updated by the rule.")

    await model.undoLastApply()
    let restored = try #require(try await store.txnRepository.transaction(PreviewData.id(416))?.txn)
    #expect(restored.type == .expense)
    #expect(restored.categoryID == PreviewData.id(202))
    #expect(!model.rules.contains { $0.pattern == "auchan" })
    #expect(model.lastApply == nil)
  }

  @Test("R-MGMT-6: a category rule applied to existing transactions leaves transfers alone")
  func applyCategoryKeepsTransfers() async throws {
    let model = await model()
    model.newRule()
    model.editor?.pattern = "a"
    model.editor?.categoryID = PreviewData.id(213)
    model.editor?.updateExisting = true
    await model.loadEditorTransactions()
    let changes = try #require(model.editorChanges)
    #expect(!changes.isEmpty)
    #expect(changes.allSatisfy { $0.type == .expense && $0.categoryID == PreviewData.id(213) })
    // "ATM withdrawal", "Currency exchange" and "To EUR card" are transfers: untouched.
    #expect(!changes.contains { [PreviewData.id(403), PreviewData.id(406), PreviewData.id(415)].contains($0.id) })
    model.cancelEditor()
    #expect(model.editor == nil && model.confirmation == nil)
  }

  @Test("R-MGMT-6: dragging a rule changes the order and so which rule wins")
  func reorder() async throws {
    let model = await model(probe: "LIDL ORANGE")
    await model.move(fromOffsets: [4], toOffset: 0)
    #expect(model.rows.first?.pattern == "orange")
    #expect(model.match?.pattern == "orange")
    #expect(try await store.ruleRepository.rules().map(\.pattern).first == "orange")
  }

  @Test("R-MGMT-6, R-IMP-8: rules are created (manual, last), edited and deleted")
  func crud() async throws {
    let model = await model(probe: "Spotify AB")
    model.newRule()
    #expect(model.editor?.pattern == "spotify ab")
    #expect(model.editorValidation == "Choose a category.")
    model.editor?.pattern = " "
    #expect(model.editorValidation == "Enter the description text.")
    model.editor?.pattern = "spotify"
    model.editor?.categoryID = PreviewData.id(211)
    await model.saveEditor()
    #expect(model.editor == nil)
    let created = try #require(model.rules.last)
    #expect(created.pattern == "spotify")
    #expect(created.origin == .manual)
    #expect(model.probeResult == "Matches “spotify” → Bills › Mobile")

    model.edit(created.id)
    model.editor?.hasAccountCondition = true
    model.editor?.accountID = PreviewData.revolutEUR.id
    await model.saveEditor()
    #expect(model.rules.first { $0.id == created.id }?.accountID == PreviewData.revolutEUR.id)
    #expect(model.rows.last?.condition == "Description contains “spotify” on Revolut EUR")

    model.requestDelete(created.id)
    #expect(model.dialog?.title == "Delete the rule “spotify”?")
    await model.confirmDialog()
    #expect(!model.rules.contains { $0.id == created.id })
    #expect(try await store.ruleRepository.rules().count == ManageSample.rules.count)
  }
}
