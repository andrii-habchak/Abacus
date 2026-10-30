import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C30, R-TX-4: refund links in the Transactions list (menu rules, row texts, picker, totals) and
/// in the editor's "Refund of" field, on a synthetic database.
@MainActor
@Suite("Refund links · list and editor (C30)")
struct RefundLinksFeatureTests {
  nonisolated static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
  }()

  nonisolated static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

  nonisolated static func at(_ day: String, _ hour: Int = 12) -> Date {
    let d = Day(day)!
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour))!
  }

  static let bank = Account(
    id: id(1), name: "Bank", currency: .PLN, kind: .bank, openingBalanceMinor: 5_000_00, openingDate: at("2026-01-01", 0))
  static let card = Account(
    id: id(2), name: "Card", currency: .EUR, kind: .card, openingBalanceMinor: 0, openingDate: at("2026-01-01", 0), position: 1)
  static let travel = AbacusDomain.Category(id: id(10), name: "Travel", kind: .expense)
  static let fees = AbacusDomain.Category(id: id(11), name: "Fees", kind: .expense, position: 1)
  static let salary = AbacusDomain.Category(id: id(20), name: "Salary", kind: .income)

  let database: any DatabaseWriter

  init() throws {
    database = try AbacusDatabase.open(at: nil)
    try database.write { db in
      try db.seed {
        Self.bank
        Self.card
        Self.travel
        Self.fees
        Self.salary
      }
      // 450 spent on 2 March; 450 and 100 arrive on 10 and 12 March as income.
      try Txn.insert {
        Txn(
          id: Self.id(100), type: .expense, occurredAt: Self.at("2026-03-02"), accountID: Self.bank.id, amountMinor: 450_00,
          categoryID: Self.travel.id, payee: "Booking.com", createdAt: Self.at("2026-03-02"))
        Txn(
          id: Self.id(101), type: .income, occurredAt: Self.at("2026-03-10"), accountID: Self.bank.id, amountMinor: 450_00,
          categoryID: Self.salary.id, payee: "Booking.com", createdAt: Self.at("2026-03-10"))
        Txn(
          id: Self.id(102), type: .income, occurredAt: Self.at("2026-03-12"), accountID: Self.bank.id, amountMinor: 100_00,
          categoryID: Self.salary.id, payee: "Other", createdAt: Self.at("2026-03-12"))
        Txn(
          id: Self.id(103), type: .expense, occurredAt: Self.at("2026-03-05"), accountID: Self.bank.id, amountMinor: 20_00,
          categoryID: Self.fees.id, payee: "Fee", createdAt: Self.at("2026-03-05"))
      }.execute(db)
    }
  }

  func refunds() -> SQLiteRefundRepository {
    SQLiteRefundRepository(database: database, calendar: Self.calendar, converter: { RateTable.transactionsPreview })
  }

  func model() async -> TransactionsViewModel {
    var filters = TransactionFilters.default
    filters.dateRange = TransactionFilters.allDates
    let model = TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      displayCurrency: .PLN, filters: filters, calendar: Self.calendar, today: { Day("2026-03-31")! },
      refunds: refunds())
    await model.load()
    return model
  }

  /// "zł 450.00" as the list formats it.
  func zl(_ minor: Int64) -> String { TransactionMoneyFormat().string(minor: minor, code: "PLN") }

  func row(_ model: TransactionsViewModel, _ n: Int) -> TransactionListContent.Row? {
    model.content.days.flatMap(\.rows).first { $0.id == Self.id(n) }
  }

  // MARK: Menu rules

  @Test("the menu offers Link a refund on an expense, This is a refund of on income, Unlink on a linked refund")
  func menuRules() async throws {
    let model = await model()
    #expect(model.canLinkRefund(Self.id(100)) && !model.canChooseOriginal(Self.id(100)))
    #expect(model.canChooseOriginal(Self.id(101)) && !model.canLinkRefund(Self.id(101)))
    #expect(!model.canUnlinkRefund(Self.id(101)))
    try await refunds().linkRefund(Self.id(101), to: Self.id(100))
    await model.reload()
    #expect(model.canUnlinkRefund(Self.id(101)))
    #expect(!model.canChooseOriginal(Self.id(101)))
    // The original is still an expense that can take another refund.
    #expect(model.canLinkRefund(Self.id(100)))
  }

  @Test("without a refund repository nothing is offered")
  func noRepository() async throws {
    let model = TransactionsViewModel(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database), converter: RateTable.transactionsPreview,
      calendar: Self.calendar, today: { Day("2026-03-31")! })
    model.filters.dateRange = TransactionFilters.allDates
    await model.load()
    #expect(!model.canLinkRefund(Self.id(100)) && !model.canChooseOriginal(Self.id(101)))
  }

  // MARK: This is a refund of…

  @Test("This is a refund of…: ranked expenses, choosing turns the income into a refund of the original's category")
  func chooseOriginal() async throws {
    let model = await model()
    await model.beginChooseOriginal(Self.id(101))
    let picker = try #require(model.refundPicker)
    #expect(picker.options.first?.id == Self.id(100))
    #expect(picker.options.first?.detail == "Same amount")
    // A 20.00 expense cannot take a 450.00 refund.
    #expect(!picker.options.map(\.id).contains(Self.id(103)))
    await model.chooseRefundOption(Self.id(100))
    #expect(model.refundPicker == nil)
    let stored = try #require(try await SQLiteTxnRepository(database: database).transaction(Self.id(101))).txn
    #expect(stored.type == .expense && stored.isRefund)
    #expect(stored.categoryID == Self.travel.id && stored.refundOfID == Self.id(100))

    // List texts: the expense says it is refunded, the refund names its original; both jump.
    #expect(row(model, 100)?.refundNote == "Refunded " + zl(450_00))
    #expect(row(model, 100)?.refundJumpID == Self.id(101))
    #expect(row(model, 101)?.refundNote == "Refund of Booking.com · 2 Mar")
    #expect(row(model, 101)?.refundJumpID == Self.id(100))
    #expect(row(model, 101)?.isLinkedRefund == true)
    #expect(row(model, 102)?.refundNote == nil)
    // Footer: the 450 spent is cancelled and the refund is not income (R-SET-3 is off).
    #expect(model.content.totals.expense == .zero(.PLN) + Money(minorUnits: 20_00, currency: .PLN))
    #expect(model.content.totals.income == Money(minorUnits: 100_00, currency: .PLN))
  }

  @Test("a refund larger than the expense stays in the sheet with the remaining amount")
  func exceeds() async throws {
    let model = await model()
    try await SQLiteTxnRepository(database: database).save(
      Txn(
        id: Self.id(104), type: .income, occurredAt: Self.at("2026-03-14"), accountID: Self.bank.id, amountMinor: 20_00,
        categoryID: Self.salary.id, payee: "Fee back"), lines: [])
    // 103 (20.00) first takes 20.00; a second 100.00 refund cannot be linked to it.
    try await refunds().linkRefund(Self.id(104), to: Self.id(103))
    await model.reload()
    await model.beginChooseOriginal(Self.id(102))
    let picker = try #require(model.refundPicker)
    // The 20.00 expense is fully refunded and not offered.
    #expect(!picker.options.map(\.id).contains(Self.id(103)))
    // Linking by id anyway (a stale list) reports what remains.
    await model.chooseRefundOption(Self.id(103))
    #expect(model.refundPicker?.errorMessage?.contains("can still be refunded") == true)
  }

  // MARK: Link a refund…

  @Test("Link a refund…: incoming transactions on the same account, equal amount first; Partly refunded text")
  func linkRefund() async throws {
    let model = await model()
    await model.beginLinkRefund(Self.id(100))
    let picker = try #require(model.refundPicker)
    #expect(picker.options.map(\.id) == [Self.id(101), Self.id(102)])
    #expect(picker.options.first?.detail == "Same amount")
    await model.chooseRefundOption(Self.id(102))
    #expect(row(model, 100)?.refundNote == "Partly refunded " + zl(100_00) + " of " + zl(450_00))
    #expect(row(model, 102)?.refundNote == "Refund of Booking.com · 2 Mar")
    // 350.00 remain: the 450.00 income is not offered any more.
    await model.beginLinkRefund(Self.id(100))
    #expect(model.refundPicker?.options.isEmpty == true)
    model.cancelRefundPicker()
    // A refund that completes it reads Refunded.
    try await SQLiteTxnRepository(database: database).save(
      Txn(
        id: Self.id(105), type: .income, occurredAt: Self.at("2026-03-15"), accountID: Self.bank.id, amountMinor: 350_00,
        categoryID: Self.salary.id, payee: "Booking.com"), lines: [])
    await model.reload()
    await model.beginLinkRefund(Self.id(100))
    #expect(model.refundPicker?.options.map(\.id) == [Self.id(105)])
    await model.chooseRefundOption(Self.id(105))
    #expect(row(model, 100)?.refundNote == "Refunded " + zl(450_00))
  }

  @Test("Unlink refund: the refund keeps its category and follows R-SET-3 again")
  func unlink() async throws {
    let model = await model()
    try await refunds().linkRefund(Self.id(101), to: Self.id(100))
    await model.reload()
    await model.unlinkRefund(Self.id(101))
    #expect(row(model, 101)?.refundNote == nil)
    #expect(row(model, 100)?.refundNote == nil)
    #expect(row(model, 101)?.badges.contains { $0.kind == .refund } == true)
    // Unlinked and R-SET-3 off: the refund counts as income again, the expense is back.
    #expect(model.content.totals.expense == Money(minorUnits: 470_00, currency: .PLN))
    #expect(model.content.totals.income == Money(minorUnits: 550_00, currency: .PLN))
  }

  // MARK: Editor

  func editorDependencies() -> TransactionEditorDependencies {
    var dependencies = TransactionEditorDependencies(
      transactions: SQLiteTxnRepository(database: database, calendar: Self.calendar, converter: { RateTable.transactionsPreview }),
      accounts: SQLiteAccountRepository(database: database, calendar: Self.calendar),
      categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
      rules: SQLiteRuleRepository(database: database), settings: SQLiteSettingsRepository(database: database),
      converter: RateTable.transactionsPreview, calendar: Self.calendar, now: { Self.at("2026-03-20") })
    dependencies.refunds = refunds()
    return dependencies
  }

  @Test("editor: the Refund of field picks an expense, takes its category and saves the link")
  func editorField() async throws {
    let model = TransactionEditorModel(mode: .new, dependencies: editorDependencies())
    await model.load()
    #expect(!model.offersRefundOf)
    model.type = .expense
    model.accountID = Self.bank.id
    model.currencyCode = "PLN"
    model.amountText = "450.00"
    model.payee = "Booking.com"
    model.isRefund = true
    #expect(model.offersRefundOf && model.refundOfText == "None")
    await model.beginChooseRefundOriginal()
    let picker = try #require(model.refundPicker)
    let option = try #require(picker.options.first)
    #expect(option.id == Self.id(100) && option.isSameAmount)
    model.chooseRefundOriginal(option)
    #expect(model.refundPicker == nil)
    #expect(model.refundOfID == Self.id(100) && model.refundOfText.hasPrefix("Booking.com"))
    #expect(model.categoryID == Self.travel.id)
    #expect(model.issues.isEmpty)
    let result = try #require(await model.save())
    guard case .saved(let id) = result else {
      Issue.record("not saved")
      return
    }
    let stored = try #require(try await SQLiteTxnRepository(database: database).transaction(id)).txn
    #expect(stored.refundOfID == Self.id(100) && stored.categoryID == Self.travel.id && stored.isRefund)

    // Editing it again shows the original and keeps the link; Remove unlinks it on save.
    let edit = TransactionEditorModel(mode: .edit(id), dependencies: editorDependencies())
    await edit.load()
    #expect(edit.refundOfText.hasPrefix("Booking.com"))
    edit.clearRefundOriginal()
    #expect(await edit.save() != nil)
    #expect(try await SQLiteTxnRepository(database: database).transaction(id)?.txn.refundOfID == nil)
  }

  @Test("editor: a refund above the expense is refused with the remaining amount")
  func editorCap() async throws {
    let model = TransactionEditorModel(mode: .new, dependencies: editorDependencies())
    await model.load()
    model.type = .expense
    model.accountID = Self.bank.id
    model.currencyCode = "PLN"
    model.amountText = "500.00"
    model.isRefund = true
    await model.beginChooseRefundOriginal()
    // 500.00 is more than the 450.00 expense: not offered by the search (same currency).
    #expect(model.refundPicker?.options.contains { $0.id == Self.id(100) } == false)
    model.cancelRefundPicker()
    // Forced by a stale choice, the save is refused.
    model.chooseRefundOriginal(
      RefundPickerModel.Option(
        id: Self.id(100), title: "Booking.com", subtitle: "", amountText: "", detail: nil, isSameAmount: false,
        categoryID: Self.travel.id, occurredAt: Self.at("2026-03-02")))
    #expect(await model.save() == nil)
    #expect(model.errorMessage?.contains("can still be refunded") == true)
    #expect(try await SQLiteTxnRepository(database: database).transactions(matching: TxnQuery()).count == 4)
  }

  @Test("editor: duplicating a linked refund does not copy the link")
  func editorDuplicate() async throws {
    try await refunds().linkRefund(Self.id(101), to: Self.id(100))
    let model = TransactionEditorModel(mode: .edit(Self.id(101)), dependencies: editorDependencies())
    await model.load()
    #expect(model.refundOfID == Self.id(100))
    model.duplicate()
    #expect(model.refundOfID == nil)
  }
}
