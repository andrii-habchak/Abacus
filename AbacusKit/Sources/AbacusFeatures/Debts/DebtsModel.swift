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
  @ObservationIgnored public private(set) var converter: any CurrencyConverter = NoRates()
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
  }

  func balanceText(_ money: Money) -> BalanceText {
    let direction = money.minorUnits > 0 ? "owes you" : money.minorUnits < 0 ? "you owe" : "settled up"
    return BalanceText(
      money: money, amountText: format.money(money.minorUnits < 0 ? money.negated : money), directionText: direction)
  }

  private var balances: [Debt.ID: Money] { Calc.debtBalances(book) }

  /// People of the filter (Active: a person with any open debt; Settled: all debts settled),
  /// matching the search, by name.
  public var people: [PersonRow] {
    let balances = self.balances
    let groups = Dictionary(grouping: book.debts, by: \.personKey)
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    return groups.compactMap { key, debts -> PersonRow? in
      let settled = debts.allSatisfy(\.isSettled)
      guard settled == (filter == .settled) else { return nil }
      let name = debts[0].personName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !query.isEmpty, name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
      let shown = debts.filter { $0.isSettled == settled }
        .sorted { (order[$0.currency] ?? 0) < (order[$1.currency] ?? 0) }
      let due = shown.compactMap { $0.dueDay.flatMap(Day.init) }.min()
      return PersonRow(
        id: key, name: name, balances: shown.map { balanceText(balances[$0.id] ?? .zero($0.currency)) },
        detail: due.map { "Due \(format.day($0))" }, isSettled: settled)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Header totals in the display currency (latest rate): "Owed to you", "You owe".
  public var summary: DebtSummary {
    Calc.debtSummary(book, currency: displayCurrency, converter: converter)
  }

  // MARK: Detail

  public struct RecordRow: Hashable, Sendable, Identifiable {
    public let id: DebtRecord.ID
    public let dayText: String
    public let kindTitle: String
    /// Signed by the effect on the balance: "+€300.00" (they owe more) / "−€120.00".
    public let amountText: String
    public let increasesBalance: Bool
    /// "Revolut EUR · −€300.00" / "No account".
    public let accountText: String
    public let note: String
    /// "Counted as expense"; nil when not counted.
    public let reportText: String?
  }

  public struct DebtDetail: Hashable, Sendable, Identifiable {
    public let debt: Debt
    public let balance: BalanceText
    public let dueText: String?
    /// "I lent €300.00 · They repaid €120.00".
    public let totalsText: String?
    public let records: [RecordRow]
    /// A zero balance can be marked settled (R-DEBT-5).
    public let canSettle: Bool
    public var id: Debt.ID { debt.id }
  }

  /// The selected person's debts: open ones first, then by currency.
  public var selectedDetails: [DebtDetail] {
    guard let selectedPerson else { return [] }
    let balances = self.balances
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return book.debts.filter { $0.personKey == selectedPerson }
      .sorted { ($0.isSettled ? 1 : 0, order[$0.currency] ?? 0) < ($1.isSettled ? 1 : 0, order[$1.currency] ?? 0) }
      .map { debt in
        let entries = book.entries(of: debt.id).sorted {
          ($0.record.day, $0.record.createdAt) > ($1.record.day, $1.record.createdAt)
        }
        var totals: [DebtRecordKind: Int64] = [:]
        for entry in entries { totals[entry.record.kind, default: 0] += entry.record.amountMinor }
        let totalsText = DebtRecordKind.allCases.compactMap { kind in
          totals[kind].map { "\(kind.title) \(format.money(Money(minorUnits: $0, currency: debt.currency)))" }
        }.joined(separator: " · ")
        let rows = entries.map { entry -> RecordRow in
          let record = entry.record
          let money = Money(minorUnits: record.amountMinor, currency: debt.currency)
          var accountText = "No account"
          if let leg = entry.leg, let account = accountsByID[leg.accountID] {
            let legMoney = Money(minorUnits: leg.amountMinor, currency: account.currency)
            let sign = record.kind.isInflow ? "+" : "−"
            accountText = "\(account.name) · \(sign)\(format.money(legMoney))"
          }
          let report = record.reportKind.map { "Counted as \($0 == .expense ? "expense" : "income")" }
          let note = record.note.isEmpty ? (entry.leg?.payee ?? "") : record.note
          return RecordRow(
            id: record.id, dayText: Day(record.day).map(format.day) ?? record.day, kindTitle: record.kind.title,
            amountText: (record.balanceEffect >= 0 ? "+" : "−") + format.money(money),
            increasesBalance: record.balanceEffect >= 0, accountText: accountText, note: note, reportText: report)
        }
        let balance = balances[debt.id] ?? .zero(debt.currency)
        return DebtDetail(
          debt: debt, balance: balanceText(balance), dueText: debt.dueDay.flatMap(Day.init).map { "Due \(format.day($0))" },
          totalsText: totalsText.isEmpty ? nil : totalsText, records: rows, canSettle: balance.minorUnits == 0)
      }
  }

  public var selectedPersonName: String? {
    book.debts.first { $0.personKey == selectedPerson }?.personName
  }

  /// Opens the debt of a record (a leg picked in the transaction list).
  public func show(recordID: DebtRecord.ID) async {
    if phase != .loaded || !book.entries.contains(where: { $0.record.id == recordID }) { await load() }
    guard let entry = book.entries.first(where: { $0.record.id == recordID }),
      let debt = book.debts.first(where: { $0.id == entry.record.debtID })
    else { return }
    filter = debt.isSettled && book.debts.filter({ $0.personKey == debt.personKey }).allSatisfy(\.isSettled) ? .settled : .active
    search = ""
    selectedPerson = debt.personKey
  }

  // MARK: Debt form

  public struct DebtDraft: Equatable, Sendable {
    public var id: Debt.ID?
    public var personName: String
    public var currency: Currency
    public var hasDueDay: Bool
    public var dueDate: Date
    public var note: String
    public var countsInNetWorth: Bool
    public var isSettled: Bool
  }

  public func newDebt() {
    let person = selectedPersonName ?? ""
    let used = Set(book.debts.filter { $0.personKey == selectedPerson }.map(\.currency))
    let currency = Currency.displayOrder.reversed().first { !used.contains($0) } ?? displayCurrency
    debtDraft = DebtDraft(
      id: nil, personName: filter == .active ? person : "", currency: currency, hasDueDay: false,
      dueDate: dependencies.today().date(calendar: format.calendar), note: "", countsInNetWorth: true, isSettled: false)
  }

  public func editDebt(_ id: Debt.ID) {
    guard let debt = book.debts.first(where: { $0.id == id }) else { return }
    let due = debt.dueDay.flatMap(Day.init)
    debtDraft = DebtDraft(
      id: debt.id, personName: debt.personName, currency: debt.currency, hasDueDay: due != nil,
      dueDate: (due ?? dependencies.today()).date(calendar: format.calendar), note: debt.note,
      countsInNetWorth: debt.countsInNetWorth, isSettled: debt.isSettled)
  }

  /// The currency can't change once the debt has records (R-DEBT-1).
  public var debtCurrencyLocked: Bool {
    guard let id = debtDraft?.id else { return false }
    return !book.entries(of: id).isEmpty
  }

  public var debtDraftIssue: String? {
    guard let draft = debtDraft else { return nil }
    let name = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Enter the person's name." }
    let key = Debt(personName: name, currency: draft.currency).personKey
    if book.debts.contains(where: { $0.id != draft.id && $0.personKey == key && $0.currency == draft.currency }) {
      return "\(name) already has a \(draft.currency.rawValue) debt."
    }
    return nil
  }

  public func saveDebtDraft() async {
    guard let draft = debtDraft, debtDraftIssue == nil else { return }
    let existing = draft.id.flatMap { id in book.debts.first { $0.id == id } }
    var debt = existing ?? Debt(personName: draft.personName, currency: draft.currency)
    debt.personName = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    debt.currency = draft.currency
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

  /// R-DEBT-5: settled (zero balance only) moves the debt to Settled; unsettle moves it back.
  public func setSettled(_ id: Debt.ID, _ settled: Bool) async {
    guard var debt = book.debts.first(where: { $0.id == id }) else { return }
    if settled, (balances[id]?.minorUnits ?? 0) != 0 { return }
    debt.isSettled = settled
    await perform { try await self.dependencies.debts.save(debt) }
    if people.isEmpty || !people.contains(where: { $0.id == debt.personKey }) {
      filter = settled ? .settled : .active
      selectedPerson = debt.personKey
    }
  }

  // MARK: Record form

  public struct RecordDraft: Equatable, Sendable {
    public var recordID: DebtRecord.ID?
    public var debtID: Debt.ID
    public var kind: DebtRecordKind
    public var date: Date
    public var amount: String
    public var accountID: Account.ID?
    /// In the account's currency when it differs from the debt's.
    public var accountAmount: String
    public var note: String
    public var countsInReports: Bool
    /// The stored flag/category of an edited record (kept when the flag stays on).
    var originalReportKind: CategoryKind?
    var originalCategoryID: AbacusDomain.Category.ID?
  }

  /// Accounts offered for a record: not archived (the leg's own account stays offered), under
  /// their groups A–Z (R-MGMT-9).
  public var accountSections: [AccountPickerSection] {
    let current = recordDraft?.accountID
    return AccountOrder.pickerSections(accounts.filter { !$0.isArchived || $0.id == current }, groups: accountGroups)
  }

  public func newRecord(debtID: Debt.ID, kind: DebtRecordKind = .lent) {
    guard let debt = book.debts.first(where: { $0.id == debtID }) else { return }
    let account = accounts.first { !$0.isArchived && $0.currency == debt.currency && !$0.kind.isLiability }
      ?? accounts.first { !$0.isArchived }
    recordDraft = RecordDraft(
      recordID: nil, debtID: debtID, kind: kind, date: dependencies.today().date(calendar: format.calendar), amount: "",
      accountID: kind.movesMoney ? account?.id : nil, accountAmount: "", note: "", countsInReports: kind.reportsByDefault)
  }

  public func editRecord(_ id: DebtRecord.ID) {
    guard let entry = book.entries.first(where: { $0.record.id == id }) else { return }
    let record = entry.record
    recordDraft = RecordDraft(
      recordID: record.id, debtID: record.debtID, kind: record.kind,
      date: (Day(record.day) ?? dependencies.today()).date(calendar: format.calendar),
      amount: format.amountInput(record.amountMinor), accountID: entry.leg?.accountID,
      accountAmount: entry.leg.map { format.amountInput($0.amountMinor) } ?? "", note: record.note,
      countsInReports: record.reportKind != nil, originalReportKind: record.reportKind,
      originalCategoryID: record.categoryID)
  }

  /// Changes the kind; a new record takes the kind's default flag (R-DEBT-4).
  public func setRecordKind(_ kind: DebtRecordKind) {
    guard var draft = recordDraft else { return }
    draft.kind = kind
    if draft.recordID == nil { draft.countsInReports = kind.reportsByDefault }
    if !kind.movesMoney { draft.accountID = nil }
    if kind.movesMoney, draft.accountID == nil, let debt = debt(of: draft) {
      draft.accountID = accounts.first { !$0.isArchived && $0.currency == debt.currency }?.id
    }
    recordDraft = draft
  }

  func debt(of draft: RecordDraft) -> Debt? { book.debts.first { $0.id == draft.debtID } }

  /// "Count as expense" / "Count as income", or nil when the kind has no flag (R-DEBT-4). An
  /// edited record that already counts keeps its toggle.
  public var recordReportKind: CategoryKind? {
    guard let draft = recordDraft else { return nil }
    return draft.kind.offeredReportKind ?? (draft.recordID != nil ? draft.originalReportKind : nil)
  }

  public var recordAccount: Account? {
    recordDraft?.accountID.flatMap { id in accounts.first { $0.id == id } }
  }

  public var recordDebtCurrency: Currency? { recordDraft.flatMap(debt(of:))?.currency }

  /// The account's currency differs from the debt's: the account amount is entered too.
  public var recordNeedsAccountAmount: Bool {
    guard let account = recordAccount, let currency = recordDebtCurrency, recordDraft?.kind.movesMoney == true else {
      return false
    }
    return account.currency != currency
  }

  /// The account amount at the day's rate, for the field's placeholder / pre-fill.
  public var suggestedAccountAmount: String? {
    guard recordNeedsAccountAmount, let draft = recordDraft, let account = recordAccount,
      let currency = recordDebtCurrency, let minor = format.parseAmount(draft.amount), minor > 0
    else { return nil }
    let day = Day(draft.date, calendar: format.calendar)
    return converter.convert(Money(minorUnits: minor, currency: currency), to: account.currency, on: day)
      .map { format.amountInput($0.minorUnits) }
  }

  public var recordDraftIssue: String? {
    guard let draft = recordDraft else { return nil }
    guard let amount = format.parseAmount(draft.amount), amount > 0 else { return "Enter an amount above zero." }
    if recordNeedsAccountAmount {
      let text = draft.accountAmount.isEmpty ? (suggestedAccountAmount ?? "") : draft.accountAmount
      guard let minor = format.parseAmount(text), minor > 0 else {
        return "Enter the amount in \(recordAccount?.currency.rawValue ?? "the account's currency")."
      }
    }
    return nil
  }

  public func saveRecordDraft() async {
    guard let draft = recordDraft, recordDraftIssue == nil, let debt = debt(of: draft),
      let amount = format.parseAmount(draft.amount)
    else { return }
    let reportKind = draft.countsInReports ? recordReportKind : nil
    let existing = draft.recordID.flatMap { id in book.entries.first { $0.record.id == id }?.record }
    var record = existing ?? DebtRecord(debtID: debt.id, kind: draft.kind, day: "", amountMinor: amount)
    record.kind = draft.kind
    record.day = Day(draft.date, calendar: format.calendar).string
    record.amountMinor = amount
    record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    record.reportKind = reportKind
    record.categoryID = reportKind != nil && reportKind == draft.originalReportKind ? draft.originalCategoryID : nil
    var leg: DebtLegInput?
    if draft.kind.movesMoney, let account = recordAccount {
      var legAmount = amount
      if account.currency != debt.currency {
        let text = draft.accountAmount.isEmpty ? (suggestedAccountAmount ?? "") : draft.accountAmount
        legAmount = format.parseAmount(text) ?? 0
      }
      leg = DebtLegInput(accountID: account.id, amountMinor: legAmount)
    }
    await perform {
      try await self.dependencies.debts.save(record, leg: leg)
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

  private func perform(_ work: @MainActor () async throws -> Void) async {
    do {
      try await work()
      errorMessage = nil
      await load()
      await onDataChange?()
    } catch DebtRepositoryError.currencyLocked {
      errorMessage = "The currency can't change: the debt has records."
    } catch {
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
