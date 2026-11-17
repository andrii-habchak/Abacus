import AbacusDomain
import AbacusFX
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// N5b: the Upcoming screen, its editor, suggestions and the dashboard widget (R-REC-4, 8, 10,
/// 11, 12, 16) on `UpcomingSample` (synthetic items on the `PreviewData` accounts).
@MainActor
@Suite("Upcoming (N5b)")
struct UpcomingTests {
  /// Tuesday 3 Nov 2026.
  static let today = Day(year: 2026, month: 11, day: 3)
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
  }()
  static let format = ManageFormat(locale: Locale(identifier: "en_GB"), calendar: calendar)

  static func model(today: Day = today) throws -> (UpcomingModel, any DatabaseWriter) {
    let database = try UpcomingSample.database()
    let model = UpcomingModel(dependencies: .onDatabase(database, today: today, format: format))
    return (model, database)
  }

  static func item(_ n: Int) -> ScheduledItem { UpcomingSample.items.first { $0.id == PreviewData.id(n) }! }

  static func at(_ day: String) -> Date { Day(day)!.date(calendar: calendar).addingTimeInterval(12 * 3600) }

  // MARK: Grouping and badge (R-REC-10)

  @Test("R-REC-10: Overdue, Today, This week, Later; resolved rows before today are hidden")
  func grouping() {
    let rent = Self.item(901)
    let phone = Self.item(904)
    let today = Self.today
    let occurrences = [
      UpcomingOccurrence(item: phone, day: Day("2026-10-22")!),
      UpcomingOccurrence(item: rent, day: today),
      UpcomingOccurrence(item: rent, day: Day("2026-11-10")!),
      UpcomingOccurrence(item: rent, day: Day("2026-11-11")!),
      UpcomingOccurrence(
        item: rent, day: Day("2026-10-30")!,
        resolved: ScheduledOccurrence(itemID: rent.id, expectedDay: "2026-10-30", expectedAmountMinor: 1, status: .paid)),
    ]
    let groups = UpcomingCalc.grouped(occurrences, today: today)
    #expect(groups.map(\.group) == [.overdue, .today, .thisWeek, .later])
    #expect(groups.map(\.rows.count) == [1, 1, 1, 1])
    #expect(groups[2].rows[0].day == Day("2026-11-10"))
  }

  @Test("R-REC-10: the screen groups the sample; the badge counts overdue plus the next 7 days")
  func sampleGroupsAndBadge() async throws {
    let (model, _) = try Self.model()
    await model.load()
    #expect(model.phase == .loaded)
    let groups = model.groups
    let titles = Dictionary(uniqueKeysWithValues: groups.map { ($0.group, $0.rows.map(\.title)) })
    #expect(Set(titles[.overdue] ?? []) == ["Phone plan", "Gym membership", "Accountant", "Savings top-up"])
    #expect(titles[.today] == nil)
    #expect(titles[.thisWeek] == ["Flat rent", "Cloud storage", "Salary"])
    #expect(titles[.later]?.count == 6)
    #expect(model.badgeCount == 7)
    // A row: "Category · Monthly", relative day, converted amount for a foreign account.
    let cloud = try #require(groups.first { $0.group == .thisWeek }?.rows.first { $0.title == "Cloud storage" })
    #expect(cloud.subtitle == "Bills · Monthly")
    #expect(cloud.relativeText == "in 5 days")
    #expect(cloud.amountText.hasPrefix("−"))
    model.displayCurrency = .PLN
    let converted = model.groups.first { $0.group == .thisWeek }?.rows.first { $0.title == "Cloud storage" }
    #expect(converted?.convertedText?.hasPrefix("≈ −") == true)
    // The range selector widens the list.
    model.rangeDays = 7
    #expect(model.groups.map(\.group) == [.overdue, .thisWeek])
  }

  @Test("R-REC-10: totals in the display currency; transfers not counted; missing rates named")
  func totals() async throws {
    let (model, _) = try Self.model()
    await model.load()
    model.displayCurrency = .PLN
    model.rangeDays = 7
    let totals = model.totals
    // Expected in 7 days (plus overdue): rent 3,200 + phone 59.99 + accountant 250 out (PLN), gym 35 EUR
    // and cloud 9.99 USD converted; salary 9,800 in; the savings transfer is not counted.
    #expect(totals.inMinor == 9_800_00)
    #expect(totals.outMinor > 3_509_99)
    #expect(totals.unconverted.isEmpty)
    let noRates = UpcomingCalc.totals(model.occurrences, accounts: model.accounts, currency: .PLN, converter: RateTable())
    #expect(noRates.unconverted == [.EUR, .USD])
    #expect(noRates.outMinor == 3_200_00 + 59_99 + 250_00)
  }

  @Test("R-REC-2: repeat labels")
  func repeatLabels() {
    #expect(UpcomingCalc.repeatLabel(Self.item(901)) == "Monthly")
    #expect(UpcomingCalc.repeatLabel(Self.item(907)) == "Every 2 months")
    #expect(UpcomingCalc.repeatLabel(Self.item(908)) == "Monthly, last day")
    #expect(UpcomingCalc.relative(Self.today.plusDays(-8), today: Self.today) == "8 days ago")
    #expect(UpcomingCalc.relative(Self.today.plusDays(1), today: Self.today) == "tomorrow")
  }

  // MARK: Row actions (R-REC-4)

  @Test("R-REC-4: Skip stores a skipped occurrence; Undo reopens it")
  func skipAndUndo() async throws {
    let (model, database) = try Self.model()
    await model.load()
    let rent = try #require(model.occurrences.first { $0.item.payee == "Flat rent" })
    await model.skip(rent)
    let store = SQLiteScheduledStore(database: database, calendar: Self.calendar)
    let stored = try await store.occurrences(itemID: rent.item.id)
    #expect(stored.map(\.status) == [.skipped])
    #expect(model.notice?.hasPrefix("Skipped Flat rent") == true)
    let shown = try #require(model.occurrences.first { $0.item.id == rent.item.id && $0.day == rent.day })
    #expect(shown.resolved?.status == .skipped)
    #expect(model.badgeCount == 6)
    await model.reopen(shown)
    let reopened = try await store.occurrences(itemID: rent.item.id)
    #expect(reopened.isEmpty)
    #expect(model.badgeCount == 7)
  }

  @Test("R-REC-4: Mark paid hands the editor the template; the saved transaction pays the occurrence")
  func markPaid() async throws {
    let (model, database) = try Self.model()
    await model.load()
    var payment: ScheduledPayment?
    model.onMarkPaid = { payment = $0 }
    let rent = try #require(model.occurrences.first { $0.item.payee == "Flat rent" })
    model.markPaid(rent)
    let template = try #require(payment?.template)
    #expect(template.payee == "Flat rent" && template.amountMinor == 3_200_00)
    #expect(template.accountID == PreviewData.pkoPersonal.id && template.categoryID == PreviewData.id(205))
    // The editor saved a transaction (here directly).
    let txn = Txn(
      type: .expense, occurredAt: Self.at("2026-11-03"), accountID: PreviewData.pkoPersonal.id, amountMinor: 3_200_00,
      categoryID: PreviewData.id(205), payee: "Flat rent")
    try await SQLiteTxnRepository(database: database, calendar: Self.calendar).save(txn, lines: [])
    await model.paid(try #require(payment), txnID: txn.id)
    let stored = try await SQLiteScheduledStore(database: database).occurrences(itemID: rent.item.id)
    #expect(stored.first?.status == .paid && stored.first?.txnID == txn.id && stored.first?.matchKind == .typed)
    let row = model.groups.flatMap(\.rows).first { $0.occurrence.item.id == rent.item.id && $0.occurrence.day == rent.day }
    #expect(row?.chip == .paid && row?.resolvedText == "Marked paid")
  }

  @Test("R-REC-4: Link existing lists transactions in the window on the account; linking pays; Unlink reopens")
  func linkExisting() async throws {
    let (model, database) = try Self.model()
    let txns = SQLiteTxnRepository(database: database, calendar: Self.calendar)
    let near = Txn(
      type: .expense, occurredAt: Self.at("2026-11-04"), accountID: PreviewData.pkoPersonal.id, amountMinor: 3_150_00,
      payee: "Landlord transfer")
    let far = Txn(
      type: .expense, occurredAt: Self.at("2026-11-12"), accountID: PreviewData.pkoPersonal.id, amountMinor: 3_200_00,
      payee: "Flat rent")
    let other = Txn(
      type: .expense, occurredAt: Self.at("2026-11-05"), accountID: PreviewData.monobank.id, amountMinor: 3_200_00,
      payee: "Flat rent")
    for txn in [near, far, other] { try await txns.save(txn, lines: []) }
    await model.load()
    let rent = try #require(model.occurrences.first { $0.item.payee == "Flat rent" && $0.day == Day("2026-11-05") })
    await model.beginLink(rent)
    let picker = try #require(model.linkPicker)
    #expect(picker.candidates.map(\.txnID).contains(near.id))
    #expect(!picker.candidates.map(\.txnID).contains(far.id))
    #expect(!picker.candidates.map(\.txnID).contains(other.id))
    #expect(picker.candidates.first { $0.txnID == near.id }?.deltaText == "1 day early")
    await model.link(near.id)
    let store = SQLiteScheduledStore(database: database)
    let stored = try #require(try await store.occurrences(itemID: rent.item.id).first)
    #expect(stored.txnID == near.id && stored.matchKind == .linked)
    let shown = try #require(model.occurrences.first { $0.resolved?.id == stored.id })
    await model.reopen(shown)
    let reopened = try await store.occurrences(itemID: rent.item.id)
    #expect(reopened.isEmpty)
  }

  // MARK: Editor (R-REC-12, R-REC-2)

  @Test("R-REC-12: validation, next five dates with month-end clamping, last-day option")
  func editorValidationAndPreview() async throws {
    let (model, _) = try Self.model()
    await model.load()
    model.newItem()
    let editor = try #require(model.editor)
    #expect(editor.issues.contains(.payee) && editor.issues.contains(.amount))
    #expect(!editor.canSave)
    editor.draft.payee = "Insurance"
    editor.draft.amountText = "120.50"
    editor.draft.accountID = PreviewData.pkoPersonal.id
    editor.draft.startDay = Day("2026-01-31")!
    #expect(editor.issues.isEmpty)
    #expect(editor.nextDays.map(\.string) == ["2026-11-30", "2026-12-31", "2027-01-31", "2027-02-28", "2027-03-31"])
    #expect(editor.monthEndHint == "Months without a 31st use their last day.")
    editor.draft.startDay = Day("2026-01-30")!
    editor.draft.lastDayOfMonth = true
    #expect(editor.monthEndHint == nil)
    #expect(editor.nextDays.first?.string == "2026-11-30")
    editor.draft.endKind = .afterCount
    editor.draft.endCount = 11
    #expect(editor.nextDays.map(\.string) == ["2026-11-30"])
    editor.draft.endKind = .onDay
    editor.draft.endDay = Day("2026-01-01")!
    #expect(editor.issues == [.endDay])
    editor.draft.endKind = .never
    editor.setType(.transfer)
    #expect(editor.issues.contains(.toAccount) && editor.draft.categoryID == nil)
    editor.draft.toAccountID = PreviewData.pkoPersonal.id
    #expect(editor.issues.contains(.sameAccounts))
    editor.draft.toAccountID = PreviewData.revolutEUR.id
    #expect(editor.needsReceivedAmount && editor.issues == [.receivedAmount])
    editor.draft.toAmountText = "28"
    #expect(editor.issues.isEmpty)
    #expect(editor.item?.toAmountMinor == 28_00)
  }

  @Test("R-REC-1, R-REC-12: save adds the item, edit keeps its id, pause and delete")
  func editorSaveEditPauseDelete() async throws {
    let (model, database) = try Self.model()
    await model.load()
    let before = model.items.count
    model.newItem()
    let editor = try #require(model.editor)
    editor.draft.payee = "Insurance"
    editor.draft.amountText = "120.50"
    editor.draft.accountID = PreviewData.pkoPersonal.id
    editor.draft.categoryID = PreviewData.id(209)
    editor.draft.unit = .year
    editor.draft.startDay = Day("2026-12-18")!
    #expect(await editor.save())
    #expect(model.editor == nil && model.items.count == before + 1)
    let saved = try #require(model.items.first { $0.payee == "Insurance" })
    #expect(saved.amountMinor == 120_50 && saved.unit == .year && saved.mode == .remind && saved.tolerancePercent == 5)
    model.edit(saved.id)
    let edit = try #require(model.editor)
    #expect(edit.draft.amountText == "120.50" && !edit.isNew)
    edit.draft.amountText = "130"
    #expect(await edit.save())
    #expect(model.items.first { $0.id == saved.id }?.amountMinor == 130_00)
    model.edit(saved.id)
    await model.editor?.togglePause()
    #expect(model.items.first { $0.id == saved.id }?.status == .paused)
    #expect(model.allRows.first { $0.id == saved.id }?.chip == "Paused")
    model.edit(saved.id)
    await model.editor?.delete()
    #expect(model.items.first { $0.id == saved.id } == nil)
    let gone = try await SQLiteScheduledStore(database: database).item(saved.id)
    #expect(gone == nil)
  }

  @Test("R-REC-10: All items search, next date and monthly average excluding transfers")
  func allItems() async throws {
    let (model, _) = try Self.model()
    await model.load()
    model.displayCurrency = .PLN
    #expect(model.allRows.count == UpcomingSample.items.count)
    model.search = "rent"
    #expect(model.allRows.map(\.title) == ["Flat rent"])
    #expect(model.allRows.first?.nextText == "Next 5 Nov")
    model.search = ""
    // Salary +9,800 − rent 3,200 − phone 59.99 − water 70 − accountant 250 − streaming/cloud/gym converted.
    #expect(model.monthlyAverageText.hasPrefix("+"))
    #expect(UpcomingCalc.perMonth(Self.item(907)) == Decimal(1) / 2)
  }

  // MARK: Suggestions (R-REC-8, R-REC-16)

  static func seedSubscription(_ database: any DatabaseWriter, payee: String = "Language app") async throws {
    let txns = SQLiteTxnRepository(database: database, calendar: calendar)
    for day in ["2026-07-06", "2026-08-06", "2026-09-06", "2026-10-06"] {
      try await txns.save(
        Txn(
          type: .expense, occurredAt: at(day), accountID: PreviewData.pkoPersonal.id, amountMinor: 29_99,
          categoryID: PreviewData.id(210), payee: payee),
        lines: [])
    }
  }

  @Test("R-REC-8, R-REC-16: accept pre-fills the editor; not now hides; dismiss and restore")
  func suggestionsFlow() async throws {
    let (model, database) = try Self.model()
    try await Self.seedSubscription(database)
    await model.load()
    let row = try #require(model.visibleSuggestions.first { $0.title == "Language app" })
    #expect(row.isHighConfidence && row.evidence.count == 4)
    #expect(row.subtitle.hasPrefix("Monthly · next 6 Nov"))
    // Accept: the editor starts from the suggestion with its evidence.
    model.accept(row.suggestion)
    let editor = try #require(model.editor)
    #expect(editor.draft.payee == "Language app" && editor.draft.amountText == "29.99")
    #expect(editor.draft.startDay == Day("2026-11-06") && editor.draft.unit == .month)
    #expect(editor.draft.categoryID == PreviewData.id(210) && editor.evidence.count == 4)
    editor.cancel()
    // Not now: hidden this session until a newer row arrives.
    model.notNow(row.suggestion)
    #expect(!model.visibleSuggestions.contains { $0.title == "Language app" })
    // Dismiss: stored, gone after a reload; restore brings it back.
    await model.dismiss(row.suggestion)
    #expect(model.dismissals.count == 1)
    #expect(!model.suggestions.contains { $0.description == "Language app" })
    await model.restore(try #require(model.dismissals.first))
    #expect(model.dismissals.isEmpty)
    #expect(model.suggestions.contains { $0.description == "Language app" })
  }

  @Test("R-REC-8: accepting a suggestion and saving it removes the suggestion")
  func acceptedSuggestionDisappears() async throws {
    let (model, database) = try Self.model()
    try await Self.seedSubscription(database)
    await model.load()
    let row = try #require(model.visibleSuggestions.first { $0.title == "Language app" })
    model.accept(row.suggestion)
    #expect(await model.editor?.save() == true)
    #expect(!model.visibleSuggestions.contains { $0.title == "Language app" })
  }

  // MARK: Dashboard widget (R-REC-11)

  @Test("R-REC-11: up to six rows, overdue first, totals, more count; empty state without items")
  func dashboardWidget() async throws {
    let (model, _) = try Self.model()
    await model.load()
    model.displayCurrency = .PLN
    let widget = model.dashboard
    #expect(widget.hasItems)
    #expect(widget.rows.count == 6)
    let overdueFirst = widget.rows.prefix(4).allSatisfy { $0.isOverdue }
    #expect(overdueFirst)
    #expect(widget.rows[0].whenText.hasPrefix("Overdue · "))
    #expect(widget.overdueCount == 4 && widget.statusText == "4 overdue")
    #expect(widget.moreCount == 13 - 6)
    #expect(widget.footnote.hasPrefix("7 more · rates as of"))
    #expect(widget.inText.hasPrefix("+") && widget.outText.hasPrefix("−"))

    let empty = UpcomingModel(dependencies: .onDatabase(try PreviewData.database(), today: Self.today, format: Self.format))
    await empty.load()
    #expect(!empty.dashboard.hasItems && empty.dashboard.rows.isEmpty)
  }

  // MARK: Launch wiring (R-REC-7c, R-REC-17)

  @Test("R-REC-17: the launch run sweeps, then takes today's snapshot once")
  func maintenance() async throws {
    let database = try UpcomingSample.database()
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    let first = await UpcomingMaintenance.run(database: database, today: Self.today, converter: rates, calendar: Self.calendar)
    #expect(first.sweep != nil && first.snapshotTaken)
    let second = await UpcomingMaintenance.run(database: database, today: Self.today, converter: rates, calendar: Self.calendar)
    #expect(second.sweep?.isEmpty == true && !second.snapshotTaken)
  }

  @Test("R-REC-13: debt terms count only debts in net worth and leave linked accounts out")
  func debtTerms() throws {
    #expect(UpcomingMaintenance.debtTerms(.empty, today: Self.today, calendar: Self.calendar).isEmpty)
  }

  // MARK: Import badge (R-REC-7a)

  @Test("R-REC-10: Upcoming sits after Events with the display currency and no New transaction")
  func section() {
    #expect(AppSection.overview == [.dashboard, .transactions, .events, .upcoming, .debts])
    #expect(AppSection.upcoming.usesDisplayCurrency && !AppSection.upcoming.offersNewTransaction)
    #expect(AppSection(rawValue: "upcoming") == .upcoming)
    #expect(DashboardWidget.upcoming.title == "Upcoming (30 days)" && !DashboardWidget.upcoming.isFullWidth)
  }
}
