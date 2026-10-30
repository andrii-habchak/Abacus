import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import Observation
import SQLiteData

/// What the Debts tab reads and writes.
public struct DebtsDependencies: Sendable {
  public var debts: any DebtRepository
  public var accounts: any AccountRepository
  public var converter: @Sendable () async -> any CurrencyConverter
  public var today: @Sendable () -> Day
  public var format: ManageFormat

  public init(
    debts: any DebtRepository, accounts: any AccountRepository,
    converter: @escaping @Sendable () async -> any CurrencyConverter, today: @escaping @Sendable () -> Day = { Day(Date()) },
    format: ManageFormat = ManageFormat()
  ) {
    self.debts = debts
    self.accounts = accounts
    self.converter = converter
    self.today = today
    self.format = format
  }

  public static func live(
    database: any DatabaseWriter, refresher: RateRefresher, format: ManageFormat = ManageFormat()
  ) -> DebtsDependencies {
    let calendar = format.calendar
    return DebtsDependencies(
      debts: SQLiteDebtRepository(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      converter: { await refresher.snapshot.table }, today: { Day(Date(), calendar: calendar) }, format: format)
  }

  /// `PreviewData` plus `DebtSample` in memory.
  public static func preview(format: ManageFormat = ManageFormat()) -> DebtsDependencies {
    let database = (try? DebtSample.database(calendar: format.calendar)) ?? (try! AbacusDatabase.open(at: nil))
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    return DebtsDependencies(
      debts: SQLiteDebtRepository(database: database, calendar: format.calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: format.calendar),
      converter: { rates }, today: { PreviewData.today }, format: format)
  }
}

/// The Debts tab (R-DEBT-5): people with per-currency balances and direction, search,
/// Active/Settled filter; a person's detail with each debt's records, totals and due date; forms
/// for a debt and a record (R-DEBT-1, R-DEBT-3, R-DEBT-4), Save bottom-right (R-MGMT-10).
@MainActor
@Observable
public final class DebtsModel {
  public enum Phase: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
  }

  public enum Filter: String, CaseIterable, Identifiable, Sendable {
    case active, settled
    public var id: Self { self }
    public var title: String { self == .active ? "Active" : "Settled" }
  }

  public private(set) var phase: Phase = .idle
  public private(set) var book: DebtBook = .empty
  /// Every account (names of legs on archived accounts too).
  public private(set) var accounts: [Account] = []
  public private(set) var accountGroups: [AccountGroup] = []
  public var search = ""
  public var filter: Filter = .active
  /// The selected person (`Debt.personKey`).
  public var selectedPerson: String?
  /// For the header totals (R-HOME-4 switch); the shell passes it in.
  public var displayCurrency: Currency = .UAH
  public private(set) var errorMessage: String?

  public var debtDraft: DebtDraft?
  public var recordDraft: RecordDraft?

  @ObservationIgnored public let dependencies: DebtsDependencies
  /// Observed: the converted totals follow a rate refresh (R-DEBT-15).
  public private(set) var converter: any CurrencyConverter = NoRates()
  /// After a save or delete: the transaction list, dashboard and balances follow.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?

  public init(dependencies: DebtsDependencies) {
    self.dependencies = dependencies
  }

  public var format: ManageFormat { dependencies.format }

  // MARK: Loading

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      book = try await dependencies.debts.book()
      accounts = try await dependencies.accounts.accounts(includeArchived: true)
      accountGroups = (try? await dependencies.accounts.groups()) ?? []
      converter = await dependencies.converter()
      phase = .loaded
      if selectedPerson == nil || !people.contains(where: { $0.id == selectedPerson }) {
        selectedPerson = people.first?.id
      }
    } catch {
      phase = .failed("Couldn't load debts: \(error.localizedDescription)")
    }
  }

  public func refreshRates() async {
    converter = await dependencies.converter()
  }

  // MARK: People

  public struct BalanceText: Hashable, Sendable, Identifiable {
    public let money: Money
    /// "€260.00".
    public let amountText: String
    /// "owes you" / "you owe" / "settled up".
    public let directionText: String
    public var id: Currency { money.currency }
    public var owesMe: Bool { money.minorUnits > 0 }
    public var isZero: Bool { money.minorUnits == 0 }
  }

  public struct PersonRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let balances: [BalanceText]
    /// "Due 1 Dec 2026" / "2 debts settled".
    public let detail: String?
    public let isSettled: Bool
    /// The open balances summed in the display currency at the latest rate ("≈ +₴3,400"),
    /// as on the dashboard widget: only when a balance is in another currency (R-DEBT-15).
    public var convertedText: String? = nil
  }

  func balanceText(_ money: Money) -> BalanceText {
    let direction = money.minorUnits > 0 ? "owes you" : money.minorUnits < 0 ? "you owe" : "settled up"
    return BalanceText(
      money: money, amountText: format.money(money.minorUnits < 0 ? money.negated : money), directionText: direction)
  }

  private var balances: [Debt.ID: [Money]] { Calc.debtBalances(book, calendar: format.calendar) }

  /// People of the filter (Active: an open debt; Settled: a settled one), matching the search, by
  /// name. One debt per person (R-DEBT-16); its balances are listed per currency (never netted).
  public var people: [PersonRow] {
    let balances = self.balances
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let totals = Dictionary(summary.people.map { ($0.personKey, $0) }, uniquingKeysWith: { first, _ in first })
    return book.debts.compactMap { debt -> PersonRow? in
      guard debt.isSettled == (filter == .settled) else { return nil }
      let name = debt.personName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !query.isEmpty, name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
      let shown = (balances[debt.id] ?? []).filter { $0.minorUnits != 0 }
      let due = debt.dueDay.flatMap(Day.init)
      return PersonRow(
        id: debt.personKey, name: name,
        balances: (shown.isEmpty ? [Money.zero(displayCurrency)] : shown).map(balanceText),
        detail: due.map { "Due \(format.day($0))" }, isSettled: debt.isSettled,
        convertedText: debt.isSettled ? nil : totals[debt.personKey].flatMap(convertedText))
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Header totals in the display currency (latest rate): "Owed to you", "You owe".
  public var summary: DebtSummary {
    Calc.debtSummary(book, currency: displayCurrency, converter: converter, calendar: format.calendar)
  }

  /// "≈ +₴3,400" for a person whose open balances are not all in the display currency (the
  /// widget's rule, `DashboardDebts`); "≈ no rate" when a rate is missing.
  func convertedText(_ person: DebtPersonSummary) -> String? {
    guard person.balances.count > 1 || person.balances.first?.currency != displayCurrency else { return nil }
    guard let converted = person.converted else { return "≈ no rate" }
    return "≈ " + DashboardFormat(locale: format.locale, calendar: format.calendar).signed(converted)
  }

  /// A person's total in the display currency (R-DEBT-15).
  public struct PersonTotal: Hashable, Sendable {
    /// The total; nil when a rate to the display currency is missing.
    public let balance: BalanceText?
    /// "Total in UAH" / "Total in UAH at today's rates".
    public let caption: String
    /// Some balance was converted: the figure is shown with "≈".
    public let isApproximate: Bool
  }

  /// The selected person's open balances summed in the display currency at the latest rate
  /// (the widget's figure); zero when nothing is open. Per-currency balances stay as they are.
  public var selectedTotal: PersonTotal? {
    guard let selectedPerson else { return nil }
    guard book.debts.contains(where: { $0.personKey == selectedPerson }) else { return nil }
    let person = summary.people.first { $0.personKey == selectedPerson }
    let approximate = person?.balances.contains { $0.currency != displayCurrency } ?? false
    let caption = "Total in \(displayCurrency.rawValue)" + (approximate ? " at today's rates" : "")
    let money: Money? = person.map(\.converted) ?? .zero(displayCurrency)
    return PersonTotal(balance: money.map(balanceText), caption: caption, isApproximate: approximate)
  }

  /// One linked account of the selected person (R-DEBT-17), in the account's currency.
  public struct AccountFlowRow: Hashable, Sendable, Identifiable {
    public let id: Account.ID
    /// "Revolut Anna".
    public let name: String
    public let currency: Currency
    /// "−€380.00" (money out of the account), nil when none.
    public let outText: String?
    /// "+€120.00" (money into the account), nil when none.
    public let inText: String?
    /// "3 transactions · virtual".
    public let recordsText: String
  }

  /// Per linked account: what flowed out of and into it, accounts A–Z.
  public var selectedAccountFlows: [AccountFlowRow] {
    guard let selectedPerson else { return [] }
    let ids = Set(book.debts.filter { $0.personKey == selectedPerson }.map(\.id))
    let accountsByID = Dictionary(book.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Calc.debtAccountFlows(book, debtIDs: ids).compactMap { flow -> (Account, AccountFlowRow)? in
      guard let account = accountsByID[flow.accountID] else { return nil }
      let currency = account.currency
      let count = flow.transactions == 1 ? "1 transaction" : "\(flow.transactions) transactions"
      let row = AccountFlowRow(
        id: account.id, name: account.name, currency: currency,
        outText: flow.outMinor > 0 ? "−" + format.money(Money(minorUnits: flow.outMinor, currency: currency)) : nil,
        inText: flow.inMinor > 0 ? "+" + format.money(Money(minorUnits: flow.inMinor, currency: currency)) : nil,
        recordsText: "\(count) · \(flow.role.rawValue)")
      return (account, row)
    }
    .sorted { AccountOrder.byName($0.0, $1.0) }
    .map(\.1)
  }

  // MARK: Detail

  public struct RecordRow: Hashable, Sendable, Identifiable {
    public let id: DebtRecord.ID
    public let dayText: String
    public let kindTitle: String
    /// Signed by the effect on the balance: "+€300.00" (they owe more) / "−€120.00".
    public let amountText: String
    public let increasesBalance: Bool
    /// Always "Manual record" (payments are transactions on the linked accounts, R-DEBT-18).
    public let accountText: String
    public let note: String
    /// "Counted as expense"; nil when not counted.
    public let reportText: String?
  }

  /// A debt's balance in one currency with its manual records of that currency.
  public struct DebtDetail: Hashable, Sendable, Identifiable {
    public let debt: Debt
    public let currency: Currency
    public let balance: BalanceText
    public let dueText: String?
    /// "I lent €300.00 · They repaid €120.00".
    public let totalsText: String?
    public let records: [RecordRow]
    /// A zero balance in every currency can be marked settled (R-DEBT-5).
    public let canSettle: Bool
    public var id: String { "\(debt.id.uuidString)|\(currency.rawValue)" }
  }

  /// The selected person's debt, one detail per currency it has a balance or a record in (open
  /// debt first). An empty debt shows one zero detail in the display currency.
  public var selectedDetails: [DebtDetail] {
    guard let selectedPerson else { return [] }
    let balances = self.balances
    return book.debts.filter { $0.personKey == selectedPerson }
      .sorted { ($0.isSettled ? 1 : 0) < ($1.isSettled ? 1 : 0) }
      .flatMap { debt -> [DebtDetail] in
        let perCurrency = balances[debt.id] ?? []
        let canSettle = perCurrency.allSatisfy { $0.minorUnits == 0 }
        let shown = perCurrency.isEmpty ? [Money.zero(displayCurrency)] : perCurrency
        return shown.map { balance in
          let currency = balance.currency
          let records = book.records(of: debt.id).filter { $0.currency == currency }.sorted {
            ($0.day, $0.createdAt) > ($1.day, $1.createdAt)
          }
          var totals: [DebtRecordKind: Int64] = [:]
          for record in records { totals[record.kind, default: 0] += record.amountMinor }
          let totalsText = DebtRecordKind.allCases.compactMap { kind in
            totals[kind].map { "\(kind.title) \(format.money(Money(minorUnits: $0, currency: currency)))" }
          }.joined(separator: " · ")
          let rows = records.map { record -> RecordRow in
            let money = Money(minorUnits: record.amountMinor, currency: currency)
            let report = record.reportKind.map { "Counted as \($0 == .expense ? "expense" : "income")" }
            return RecordRow(
              id: record.id, dayText: Day(record.day).map(format.day) ?? record.day, kindTitle: record.kind.title,
              amountText: (record.balanceEffect >= 0 ? "+" : "−") + format.money(money),
              increasesBalance: record.balanceEffect >= 0, accountText: "Manual record", note: record.note,
              reportText: report)
          }
          return DebtDetail(
            debt: debt, currency: currency, balance: balanceText(balance),
            dueText: debt.dueDay.flatMap(Day.init).map { "Due \(format.day($0))" },
            totalsText: totalsText.isEmpty ? nil : totalsText, records: rows, canSettle: canSettle)
        }
      }
  }

  public var selectedPersonName: String? {
    book.debts.first { $0.personKey == selectedPerson }?.personName
  }

  /// Opens the debt of a manual record.
  public func show(recordID: DebtRecord.ID) async {
    if phase != .loaded || !book.records.contains(where: { $0.id == recordID }) { await load() }
    guard let record = book.records.first(where: { $0.id == recordID }),
      let debt = book.debts.first(where: { $0.id == record.debtID })
    else { return }
    filter = debt.isSettled ? .settled : .active
    search = ""
    selectedPerson = debt.personKey
  }

  // MARK: Debt form

  public struct DebtDraft: Equatable, Sendable {
    public var id: Debt.ID?
    public var personName: String
    public var hasDueDay: Bool
    public var dueDate: Date
    public var note: String
    public var countsInNetWorth: Bool
    public var isSettled: Bool
  }

  public func newDebt() {
    debtDraft = DebtDraft(
      id: nil, personName: "", hasDueDay: false,
      dueDate: dependencies.today().date(calendar: format.calendar), note: "", countsInNetWorth: false, isSettled: false)
  }

  public func editDebt(_ id: Debt.ID) {
    guard let debt = book.debts.first(where: { $0.id == id }) else { return }
    let due = debt.dueDay.flatMap(Day.init)
    debtDraft = DebtDraft(
      id: debt.id, personName: debt.personName, hasDueDay: due != nil,
      dueDate: (due ?? dependencies.today()).date(calendar: format.calendar), note: debt.note,
      countsInNetWorth: debt.countsInNetWorth, isSettled: debt.isSettled)
  }

  public var debtDraftIssue: String? {
    guard let draft = debtDraft else { return nil }
    let name = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Enter the person's name." }
    let key = Debt.personKey(name)
    if book.debts.contains(where: { $0.id != draft.id && $0.personKey == key }) {
      return "\(name) is already a debt."
    }
    return nil
  }

  public func saveDebtDraft() async {
    guard let draft = debtDraft, debtDraftIssue == nil else { return }
    let existing = draft.id.flatMap { id in book.debts.first { $0.id == id } }
    var debt = existing ?? Debt(personName: draft.personName)
    debt.personName = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    debt.dueDay = draft.hasDueDay ? Day(draft.dueDate, calendar: format.calendar).string : nil
    debt.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    debt.countsInNetWorth = draft.countsInNetWorth
    debt.isSettled = draft.isSettled
    await perform {
      try await self.dependencies.debts.save(debt)
      self.debtDraft = nil
      self.selectedPerson = debt.personKey
      self.filter = debt.isSettled ? .settled : .active
    }
  }

  public func deleteDebt(_ id: Debt.ID) async {
    await perform {
      try await self.dependencies.debts.delete(id)
      self.debtDraft = nil
    }
  }

  /// R-DEBT-5: settled (zero balances only) moves the debt to Settled; unsettle moves it back.
  public func setSettled(_ id: Debt.ID, _ settled: Bool) async {
    guard var debt = book.debts.first(where: { $0.id == id }) else { return }
    if settled, (balances[id] ?? []).contains(where: { $0.minorUnits != 0 }) { return }
    debt.isSettled = settled
    await perform { try await self.dependencies.debts.save(debt) }
    if people.isEmpty || !people.contains(where: { $0.id == debt.personKey }) {
      filter = settled ? .settled : .active
      selectedPerson = debt.personKey
    }
  }

  // MARK: Record form (manual records: forgive, adjustments; C20 reshapes)

  public struct RecordDraft: Equatable, Sendable {
    public var recordID: DebtRecord.ID?
    public var debtID: Debt.ID
    public var kind: DebtRecordKind
    public var currency: Currency
    public var date: Date
    public var amount: String
    public var note: String
    public var countsInReports: Bool
    /// The stored flag/category of an edited record (kept when the flag stays on).
    var originalReportKind: CategoryKind?
    var originalCategoryID: AbacusDomain.Category.ID?
  }

  public func newRecord(debtID: Debt.ID, kind: DebtRecordKind = .forgaveThem, currency: Currency? = nil) {
    guard book.debts.contains(where: { $0.id == debtID }) else { return }
    let used = (balances[debtID] ?? []).first?.currency
    recordDraft = RecordDraft(
      recordID: nil, debtID: debtID, kind: kind, currency: currency ?? used ?? displayCurrency,
      date: dependencies.today().date(calendar: format.calendar), amount: "", note: "",
      countsInReports: kind.reportsByDefault)
  }

  public func editRecord(_ id: DebtRecord.ID) {
    guard let record = book.records.first(where: { $0.id == id }) else { return }
    recordDraft = RecordDraft(
      recordID: record.id, debtID: record.debtID, kind: record.kind, currency: record.currency,
      date: (Day(record.day) ?? dependencies.today()).date(calendar: format.calendar),
      amount: format.amountInput(record.amountMinor), note: record.note,
      countsInReports: record.reportKind != nil, originalReportKind: record.reportKind,
      originalCategoryID: record.categoryID)
  }

  /// Changes the kind; a new record takes the kind's default flag (R-DEBT-4).
  public func setRecordKind(_ kind: DebtRecordKind) {
    guard var draft = recordDraft else { return }
    draft.kind = kind
    if draft.recordID == nil { draft.countsInReports = kind.reportsByDefault }
    recordDraft = draft
  }

  func debt(of draft: RecordDraft) -> Debt? { book.debts.first { $0.id == draft.debtID } }

  /// "Count as expense" / "Count as income", or nil when the kind has no flag (R-DEBT-4). An
  /// edited record that already counts keeps its toggle.
  public var recordReportKind: CategoryKind? {
    guard let draft = recordDraft else { return nil }
    return draft.kind.offeredReportKind ?? (draft.recordID != nil ? draft.originalReportKind : nil)
  }

  public var recordDraftIssue: String? {
    guard let draft = recordDraft else { return nil }
    guard let amount = format.parseAmount(draft.amount), amount > 0 else { return "Enter an amount above zero." }
    return nil
  }

  public func saveRecordDraft() async {
    guard let draft = recordDraft, recordDraftIssue == nil, let debt = debt(of: draft),
      let amount = format.parseAmount(draft.amount)
    else { return }
    let reportKind = draft.countsInReports ? recordReportKind : nil
    let existing = draft.recordID.flatMap { id in book.records.first { $0.id == id } }
    var record = existing ?? DebtRecord(debtID: debt.id, kind: draft.kind, day: "", amountMinor: amount, currency: draft.currency)
    record.kind = draft.kind
    record.currency = draft.currency
    record.day = Day(draft.date, calendar: format.calendar).string
    record.amountMinor = amount
    record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    record.reportKind = reportKind
    record.categoryID = reportKind != nil && reportKind == draft.originalReportKind ? draft.originalCategoryID : nil
    await perform {
      try await self.dependencies.debts.save(record)
      self.recordDraft = nil
    }
  }

  public func deleteRecord(_ id: DebtRecord.ID) async {
    await perform {
      try await self.dependencies.debts.deleteRecord(id)
      self.recordDraft = nil
    }
  }

  // MARK: Saving

  /// One save or delete at a time: a second Return (or Save then Delete) while the first is
  /// still writing is ignored instead of saving the record twice (S1).
  public private(set) var isSaving = false

  private func perform(_ work: @MainActor () async throws -> Void) async {
    guard !isSaving else { return }
    isSaving = true
    do {
      try await work()
      errorMessage = nil
      await load()
      isSaving = false
      await onDataChange?()
    } catch DebtRepositoryError.personExists {
      isSaving = false
      errorMessage = "That person already has a debt."
    } catch {
      isSaving = false
      errorMessage = "Couldn't save: \(error.localizedDescription)"
    }
  }
}

/// A converter without rates (before the first load).
struct NoRates: CurrencyConverter {
  func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { from == to ? 1 : nil }
  func latestRate(from: Currency, to: Currency) -> Decimal? { from == to ? 1 : nil }
  var latestDay: Day? { nil }
}
