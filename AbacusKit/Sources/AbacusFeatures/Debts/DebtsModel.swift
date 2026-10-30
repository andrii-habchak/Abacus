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
  public var displayCurrency: Currency = .UAH {
    didSet { if oldValue != displayCurrency { recompute() } }
  }
  public private(set) var errorMessage: String?

  public var debtDraft: DebtDraft?
  public var recordDraft: RecordDraft?

  @ObservationIgnored public let dependencies: DebtsDependencies
  /// Observed: the converted totals follow a rate refresh (R-DEBT-15).
  public private(set) var converter: any CurrencyConverter = NoRates()
  /// After a save or delete: the transaction list, dashboard and balances follow.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?
  /// "Show transactions" (R-DEBT-21, R-DEBT-22): the shell opens the Transactions list filtered to
  /// the debt's accounts. A no-op until the shell wires it.
  @ObservationIgnored public var onShowTransactions: @MainActor (Debt.ID) -> Void = { _ in }

  public init(dependencies: DebtsDependencies) {
    self.dependencies = dependencies
  }

  public var format: ManageFormat { dependencies.format }

  // MARK: Derived figures (computed once per load, S1)

  /// Everything that replays the ledger, computed when the book, the rates or the display
  /// currency change, never per view update or per row.
  struct Derived {
    var balances: [Debt.ID: [Money]] = [:]
    var summary: DebtSummary
    var duplicates: [DebtDuplicateHint] = []
    var idle: [DebtIdleAccountHint] = []
  }

  /// Linked accounts without a transaction for this many days get the idle notice (R-DEBT-21).
  public static let idlePeriodDays = 30

  private var derived: Derived = Derived(
    summary: Calc.debtSummary(.empty, currency: .UAH, converter: NoRates()))
  @ObservationIgnored private var accountBalanceCache: [Debt.ID: [DebtAccountBalance]] = [:]

  private func recompute() {
    let calendar = format.calendar
    accountBalanceCache = [:]
    derived = Derived(
      balances: Calc.debtBalances(book, calendar: calendar),
      summary: Calc.debtSummary(book, currency: displayCurrency, converter: converter, calendar: calendar),
      duplicates: Calc.debtDuplicateHints(book, calendar: calendar),
      idle: Calc.debtIdleAccountHints(
        book, today: dependencies.today(), periodDays: Self.idlePeriodDays, calendar: calendar))
  }

  private var balances: [Debt.ID: [Money]] { derived.balances }

  // MARK: Loading

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      book = try await dependencies.debts.book()
      accounts = try await dependencies.accounts.accounts(includeArchived: true)
      accountGroups = (try? await dependencies.accounts.groups()) ?? []
      converter = await dependencies.converter()
      recompute()
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
    recompute()
  }

  /// The widget's actions can run before the tab was ever opened.
  private func ensureLoaded() async {
    if phase != .loaded { await load() }
  }

  // MARK: People

  /// One balance as shown (R-DEBT-21, `DebtSign`): `money` is the stored one (positive = they owe
  /// me), the texts are in the display sign.
  public struct BalanceText: Hashable, Sendable, Identifiable {
    public let money: Money
    /// "−€260.00" (you lent) / "+€50.00" (you borrowed).
    public let amountText: String
    /// "you lent" / "you borrowed" / "settled up".
    public let directionText: String
    public var id: Currency { money.currency }
    /// Stored sign: they owe me (shown negative, red).
    public var owesMe: Bool { money.minorUnits > 0 }
    public var isZero: Bool { money.minorUnits == 0 }
    public var tone: DebtSign.Tone { DebtSign.tone(money) }
  }

  public struct PersonRow: Hashable, Sendable, Identifiable {
    public let id: String
    /// The person's debt (context menu actions).
    public let debtID: Debt.ID
    public let name: String
    public let balances: [BalanceText]
    /// "Due 1 Dec 2026".
    public let detail: String?
    public let isSettled: Bool
    /// The ONE main figure (R-DEBT-21): the person's balances summed in the display currency;
    /// nil when a rate is missing ("No rate").
    public var total: BalanceText? = nil
    /// A balance was converted, so the figure is approximate ("≈").
    public var isApproximate = false
    /// Per-currency amounts, no lent/borrowed labels; only for a debt with several currencies.
    public var secondaryText: String? = nil
  }

  /// Open balances summed in the display currency at the latest rate; nil when a rate is missing.
  func rowTotal(_ balances: [Money]) -> Money? {
    var minor: Int64 = 0
    for money in balances where money.minorUnits != 0 {
      if money.currency == displayCurrency {
        minor += money.minorUnits
        continue
      }
      guard let converted = converter.convertAtLatest(money, to: displayCurrency) else { return nil }
      minor += converted.minorUnits
    }
    return Money(minorUnits: minor, currency: displayCurrency)
  }

  func balanceText(_ money: Money) -> BalanceText {
    BalanceText(
      money: money, amountText: DebtSign.text(stored: money, magnitude: format.money),
      directionText: DebtSign.label(stored: money.minorUnits))
  }

  private var dashboardFormat: DashboardFormat { DashboardFormat(locale: format.locale, calendar: format.calendar) }

  /// People of the filter (Active: an open debt; Settled: a settled one), matching the search, by
  /// name. One debt per person (R-DEBT-16); its balances are listed per currency (never netted).
  public var people: [PersonRow] {
    let balances = self.balances
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return book.debts.compactMap { debt -> PersonRow? in
      guard debt.isSettled == (filter == .settled) else { return nil }
      let name = debt.personName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !query.isEmpty, name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
      let shown = (balances[debt.id] ?? []).filter { $0.minorUnits != 0 }
      let due = debt.dueDay.flatMap(Day.init)
      return PersonRow(
        id: debt.personKey, debtID: debt.id, name: name,
        balances: (shown.isEmpty ? [Money.zero(displayCurrency)] : shown).map(balanceText),
        detail: due.map { "Due \(format.day($0))" }, isSettled: debt.isSettled,
        total: rowTotal(shown).map(balanceText), isApproximate: shown.contains { $0.currency != displayCurrency },
        secondaryText: DebtSign.caption(shown, magnitude: dashboardFormat.money))
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Header totals in the display currency (latest rate), stored signs: `owedToMe` is what people
  /// owe me, `iOwe` what I owe. Shown through `lentTotalText` / `borrowedTotalText`.
  public var summary: DebtSummary { derived.summary }

  /// "You lent" (negative) and "You borrowed" (positive) in whole units, as on the widget.
  public var lentTotalText: String { DebtSign.lentTotalText(summary.owedToMe, magnitude: dashboardFormat.money) }
  public var borrowedTotalText: String { DebtSign.borrowedTotalText(summary.iOwe, magnitude: dashboardFormat.money) }

  /// "≈ −₴3,400" for a person whose open balances are not all in the display currency (the
  /// widget's rule, `DashboardDebts`); "≈ no rate" when a rate is missing.
  func convertedText(_ person: DebtPersonSummary) -> String? {
    guard person.balances.count > 1 || person.balances.first?.currency != displayCurrency else { return nil }
    guard let converted = person.converted else { return "≈ no rate" }
    return "≈ " + DebtSign.text(stored: converted, magnitude: dashboardFormat.money)
  }

  /// A person's total in the display currency (R-DEBT-15).
  public struct PersonTotal: Hashable, Sendable {
    /// The total; nil when a rate to the display currency is missing.
    public let balance: BalanceText?
    /// "≈ total in UAH" (some balance was converted) / "Total in UAH".
    public let caption: String
    /// Some balance was converted at today's rate.
    public let isApproximate: Bool
  }

  /// The selected person's open balances summed in the display currency at the latest rate
  /// (the widget's figure); zero when nothing is open. Per-currency balances stay as they are.
  public var selectedTotal: PersonTotal? {
    guard let selectedPerson else { return nil }
    guard book.debts.contains(where: { $0.personKey == selectedPerson }) else { return nil }
    let person = summary.people.first { $0.personKey == selectedPerson }
    let approximate = person?.balances.contains { $0.currency != displayCurrency } ?? false
    let caption = (approximate ? "≈ total in " : "Total in ") + displayCurrency.rawValue
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
    public let transactions: Int
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
        recordsText: "\(count) · \(flow.role.rawValue)", transactions: flow.transactions)
      return (account, row)
    }
    .sorted { AccountOrder.byName($0.0, $1.0) }
    .map(\.1)
  }

  // MARK: Per-account breakdown and notices (R-DEBT-21)

  /// One linked account in the detail: role, currency, balance and opening balance, all in the
  /// display sign.
  public struct AccountBreakdownRow: Hashable, Sendable, Identifiable {
    public let id: Account.ID
    public let name: String
    public let role: DebtAccountRole
    /// "external" / "virtual".
    public let roleTitle: String
    public let currency: Currency
    public let balance: BalanceText
    /// "−€100.00"; "—" when the account opens at zero.
    public let openingText: String
    public let transactionsText: String
    public let isArchived: Bool
  }

  private func accountBalances(of debtID: Debt.ID) -> [DebtAccountBalance] {
    if let cached = accountBalanceCache[debtID] { return cached }
    let computed = Calc.debtAccountBalances(book, debtID: debtID, calendar: format.calendar)
    accountBalanceCache[debtID] = computed
    return computed
  }

  /// The selected person's linked accounts, A–Z.
  public var selectedBreakdown: [AccountBreakdownRow] {
    guard let debt = selectedDebt else { return [] }
    let accountsByID = Dictionary(book.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let counts = Dictionary(selectedAccountFlows.map { ($0.id, $0.transactions) }, uniquingKeysWith: { first, _ in first })
    return accountBalances(of: debt.id).compactMap { item -> (Account, AccountBreakdownRow)? in
      guard let account = accountsByID[item.accountID] else { return nil }
      let opening = Money(minorUnits: account.openingBalanceMinor, currency: account.currency)
      let count = counts[account.id] ?? 0
      let row = AccountBreakdownRow(
        id: account.id, name: account.name, role: item.role, roleTitle: item.role.rawValue, currency: account.currency,
        balance: balanceText(item.balance),
        openingText: opening.minorUnits == 0 ? "—" : DebtSign.text(stored: opening, magnitude: format.money),
        transactionsText: count == 1 ? "1 transaction" : "\(count) transactions", isArchived: account.isArchived)
      return (account, row)
    }
    .sorted { AccountOrder.byName($0.0, $1.0) }
    .map(\.1)
  }

  /// A non-blocking hint on the detail: a possible double entry (R-DEBT-20) or a linked account
  /// without recent transactions (R-DEBT-21). Nothing is merged or changed.
  public struct Notice: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case duplicate, idle }
    public let id: String
    public let kind: Kind
    public let text: String
    /// The transactions of a duplicate pair.
    public let txnIDs: [Txn.ID]
  }

  public var selectedNotices: [Notice] {
    guard let debt = selectedDebt else { return [] }
    let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    func name(_ id: Account.ID) -> String { names[id] ?? "an account" }
    var notices: [Notice] = []
    for hint in derived.duplicates where hint.debtID == debt.id {
      let amount = format.money(Money(minorUnits: hint.amountMinor, currency: hint.currency))
      let when =
        hint.firstDay == hint.secondDay
        ? format.day(hint.firstDay) : "\(format.day(hint.firstDay)) and \(format.day(hint.secondDay))"
      notices.append(
        Notice(
          id: "dup-" + hint.id, kind: .duplicate,
          text:
            "Possible duplicate: \(amount) on “\(name(hint.firstAccountID))” and “\(name(hint.secondAccountID))” (\(when)). "
            + "If it is one payment, delete one of the two transactions.",
          txnIDs: [hint.first, hint.second]))
    }
    for hint in derived.idle where hint.debtID == debt.id {
      let last = hint.lastTransactionDay.map { "last on \(format.day($0))" } ?? "never had one"
      notices.append(
        Notice(
          id: "idle-" + hint.id.uuidString, kind: .idle,
          text: "“\(name(hint.accountID))” has no transactions in the last \(Self.idlePeriodDays) days (\(last)).",
          txnIDs: []))
    }
    return notices
  }

  // MARK: Detail

  public struct RecordRow: Hashable, Sendable, Identifiable {
    public let id: DebtRecord.ID
    public let dayText: String
    public let kindTitle: String
    /// Signed in the display sign (R-DEBT-21): more owed to me is "−€300.00" (you lent more), less
    /// owed to me "+€120.00".
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
        let settleable = canSettle(debt.id)
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
              amountText: (record.balanceEffect >= 0 ? "−" : "+") + format.money(money),
              increasesBalance: record.balanceEffect >= 0, accountText: "Manual record", note: record.note,
              reportText: report)
          }
          return DebtDetail(
            debt: debt, currency: currency, balance: balanceText(balance),
            dueText: debt.dueDay.flatMap(Day.init).map { "Due \(format.day($0))" },
            totalsText: totalsText.isEmpty ? nil : totalsText, records: rows, canSettle: settleable)
        }
      }
  }

  public var selectedPersonName: String? {
    book.debts.first { $0.personKey == selectedPerson }?.personName
  }

  /// The selected person's debt (one per person, R-DEBT-16).
  public var selectedDebt: Debt? {
    guard let selectedPerson else { return nil }
    return book.debts.first { $0.personKey == selectedPerson }
  }

  /// What the detail header shows about the whole debt (not per currency).
  public struct Header: Hashable, Sendable {
    public let debtID: Debt.ID
    public let name: String
    public let dueText: String?
    public let note: String
    public let isSettled: Bool
    public let countsInNetWorth: Bool
    public let canSettle: Bool
  }

  public var selectedHeader: Header? {
    guard let debt = selectedDebt else { return nil }
    return Header(
      debtID: debt.id, name: debt.personName.trimmingCharacters(in: .whitespacesAndNewlines),
      dueText: debt.dueDay.flatMap(Day.init).map { "Due \(format.day($0))" }, note: debt.note,
      isSettled: debt.isSettled, countsInNetWorth: debt.countsInNetWorth, canSettle: canSettle(debt.id))
  }

  /// R-DEBT-5: a zero balance in every currency can be marked settled.
  public func canSettle(_ id: Debt.ID) -> Bool {
    (balances[id] ?? []).allSatisfy { $0.minorUnits == 0 }
  }

  /// What the right-click menu of a debt offers (Debts list and dashboard widget, R-DEBT-21).
  public struct RowActions: Hashable, Sendable {
    public let isSettled: Bool
    /// "Mark settled" needs a zero balance; "Reopen" is always possible.
    public let canToggleSettled: Bool
    public let settledTitle: String

    public init(isSettled: Bool, canToggleSettled: Bool) {
      self.isSettled = isSettled
      self.canToggleSettled = canToggleSettled
      self.settledTitle = isSettled ? "Reopen" : "Mark settled"
    }
  }

  public func rowActions(for id: Debt.ID) -> RowActions? {
    guard let debt = book.debts.first(where: { $0.id == id }) else { return nil }
    return RowActions(isSettled: debt.isSettled, canToggleSettled: debt.isSettled || canSettle(id))
  }

  /// "Show transactions" (R-DEBT-21): hands the debt to the shell, which opens the Transactions
  /// list filtered to its accounts (R-DEBT-22).
  public func showTransactions(_ id: Debt.ID) {
    onShowTransactions(id)
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

  // MARK: Debt form (R-DEBT-16, R-DEBT-17, R-DEBT-21)

  /// A virtual account to create with the debt: a `.debt`-kind account of the person (R-DEBT-17).
  public struct NewAccountDraft: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Empty = "<person> (<CCY>)".
    public var name: String
    public var currency: Currency
    /// Opening balance as typed, in the display sign (negative = they owe me); empty = zero.
    public var opening: String

    public init(id: UUID = UUID(), name: String = "", currency: Currency, opening: String = "") {
      self.id = id
      self.name = name
      self.currency = currency
      self.opening = opening
    }
  }

  public struct DebtDraft: Equatable, Sendable {
    public var id: Debt.ID?
    public var personName: String
    public var hasDueDay: Bool
    public var dueDate: Date
    public var note: String
    public var countsInNetWorth: Bool
    public var isSettled: Bool
    /// Every account linked to the debt after saving (existing links and new picks).
    public var accountIDs: Set<Account.ID> = []
    /// Opening balance per linked account as typed, in the display sign (negative = they owe me).
    public var openings: [Account.ID: String] = [:]
    /// Virtual accounts created on save.
    public var newAccounts: [NewAccountDraft] = []
  }

  /// One row of the account picker in the dialog.
  public struct AccountChoice: Hashable, Sendable, Identifiable {
    public let id: Account.ID
    public let name: String
    public let currency: Currency
    public let kindTitle: String
    public let isSelected: Bool
    /// In another debt: "In Alex Example"; nil when free to pick.
    public let disabledReason: String?
    public var isDisabled: Bool { disabledReason != nil }
  }

  public func newDebt() {
    debtDraft = DebtDraft(
      id: nil, personName: "", hasDueDay: false,
      dueDate: dependencies.today().date(calendar: format.calendar), note: "", countsInNetWorth: false, isSettled: false)
  }

  public func editDebt(_ id: Debt.ID) {
    guard let debt = book.debts.first(where: { $0.id == id }) else { return }
    let due = debt.dueDay.flatMap(Day.init)
    let linked = book.accounts(of: id)
    var draft = DebtDraft(
      id: debt.id, personName: debt.personName, hasDueDay: due != nil,
      dueDate: (due ?? dependencies.today()).date(calendar: format.calendar), note: debt.note,
      countsInNetWorth: debt.countsInNetWorth, isSettled: debt.isSettled)
    draft.accountIDs = Set(linked.map(\.id))
    for account in linked { draft.openings[account.id] = openingText(of: account) }
    selectedPerson = debt.personKey
    filter = debt.isSettled ? .settled : .active
    debtDraft = draft
  }

  /// Edit from outside the tab (the dashboard widget): loads first when the tab was never opened.
  public func edit(debtID: Debt.ID) async {
    await ensureLoaded()
    editDebt(debtID)
  }

  /// An account's opening balance as the form shows it (display sign).
  private func openingText(of account: Account) -> String {
    format.amountInput(DebtSign.display(stored: account.openingBalanceMinor))
  }

  /// Accounts to pick from (A–Z): every account that is not archived (an archived one only while
  /// it is linked here), matching `search`. Accounts of another debt are listed disabled with that
  /// debt's name (R-DEBT-17: an account is in at most one debt).
  public func accountChoices(search: String = "") -> [AccountChoice] {
    guard let draft = debtDraft else { return [] }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return accounts.filter { account in
      if account.isArchived, !draft.accountIDs.contains(account.id) { return false }
      if !query.isEmpty, account.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
        return false
      }
      return true
    }
    .sorted(by: AccountOrder.byName)
    .map { account in
      let elsewhere = book.debtID(ofAccount: account.id).flatMap { $0 == draft.id ? nil : book.debt($0) }
      return AccountChoice(
        id: account.id, name: account.name, currency: account.currency, kindTitle: ManageText.kindTitle(account.kind),
        isSelected: draft.accountIDs.contains(account.id),
        disabledReason: elsewhere.map { "In \($0.personName)" })
    }
  }

  /// One linked account in the dialog's "Linked accounts" section (R-DEBT-17, R-DEBT-21).
  public struct LinkedAccountRow: Hashable, Sendable, Identifiable {
    public let id: Account.ID
    public let name: String
    public let role: DebtAccountRole
    /// "external" / "virtual".
    public let roleTitle: String
    public let currency: Currency
    public let isArchived: Bool
  }

  /// The accounts linked in the open dialog (existing links and new picks), A-Z. An account already
  /// linked keeps its role; a new pick is `external`. The opening balance is `debtDraft.openings[id]`.
  public var linkedAccountRows: [LinkedAccountRow] {
    guard let draft = debtDraft else { return [] }
    let roles = Dictionary(
      book.links(of: draft.id ?? UUID()).map { ($0.accountID, $0.role) }, uniquingKeysWith: { first, _ in first })
    return accounts.filter { draft.accountIDs.contains($0.id) }
      .sorted(by: AccountOrder.byName)
      .map { account in
        let role = roles[account.id] ?? .external
        return LinkedAccountRow(
          id: account.id, name: account.name, role: role, roleTitle: role.rawValue, currency: account.currency,
          isArchived: account.isArchived)
      }
  }

  /// The "Add accounts" picker: every non-archived account not yet linked here, matching `search`;
  /// accounts of another debt are listed disabled ("In <debt>").
  public func addableAccountChoices(search: String = "") -> [AccountChoice] {
    accountChoices(search: search).filter { !$0.isSelected }
  }

  /// Picks or drops an account of the dialog; an account of another debt is refused.
  public func toggleAccount(_ id: Account.ID) {
    guard var draft = debtDraft, let account = accounts.first(where: { $0.id == id }) else { return }
    if draft.accountIDs.contains(id) {
      draft.accountIDs.remove(id)
      draft.openings[id] = nil
    } else {
      if let other = book.debtID(ofAccount: id), other != draft.id { return }
      draft.accountIDs.insert(id)
      draft.openings[id] = openingText(of: account)
    }
    debtDraft = draft
  }

  /// "Create account" in the dialog: a virtual account in `currency` (default: the display one).
  public func addNewAccount(currency: Currency? = nil) {
    guard var draft = debtDraft else { return }
    draft.newAccounts.append(NewAccountDraft(currency: currency ?? displayCurrency))
    debtDraft = draft
  }

  public func removeNewAccount(_ id: NewAccountDraft.ID) {
    guard var draft = debtDraft else { return }
    draft.newAccounts.removeAll { $0.id == id }
    debtDraft = draft
  }

  public var debtDraftIssue: String? {
    guard let draft = debtDraft else { return nil }
    let name = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Enter the person's name." }
    let key = Debt.personKey(name)
    if let other = book.debts.first(where: { $0.id != draft.id && $0.personKey == key }) {
      return "\(other.personName) is already in your debts. Choose another name, or edit that debt."
    }
    for id in draft.accountIDs {
      if let text = draft.openings[id], !text.trimmingCharacters(in: .whitespaces).isEmpty, format.parseAmount(text) == nil {
        let account = accounts.first { $0.id == id }?.name ?? "an account"
        return "The opening balance of \(account) is not a number."
      }
    }
    for item in draft.newAccounts
    where !item.opening.trimmingCharacters(in: .whitespaces).isEmpty && format.parseAmount(item.opening) == nil {
      return "The opening balance of the new \(item.currency.rawValue) account is not a number."
    }
    return nil
  }

  /// Saves the debt, then its links, the opening balances (through `AccountRepository.save`) and
  /// the new virtual accounts.
  public func saveDebtDraft() async {
    guard let draft = debtDraft, debtDraftIssue == nil else { return }
    let existing = draft.id.flatMap { id in book.debts.first { $0.id == id } }
    var debt = existing ?? Debt(personName: draft.personName)
    debt.personName = draft.personName.trimmingCharacters(in: .whitespacesAndNewlines)
    debt.dueDay = draft.hasDueDay ? Day(draft.dueDate, calendar: format.calendar).string : nil
    debt.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    debt.countsInNetWorth = draft.countsInNetWorth
    debt.isSettled = draft.isSettled
    let linkedBefore = Set(existing.map { book.links(of: $0.id).map(\.accountID) } ?? [])
    await perform {
      try await self.dependencies.debts.save(debt)
      for id in linkedBefore.subtracting(draft.accountIDs) { try await self.dependencies.debts.unlink(id) }
      for id in draft.accountIDs.subtracting(linkedBefore) {
        try await self.dependencies.debts.link(id, to: debt.id, role: .external)
      }
      for id in draft.accountIDs {
        guard var account = self.accounts.first(where: { $0.id == id }),
          let text = draft.openings[id], let typed = self.openingMinor(text)
        else { continue }
        let stored = DebtSign.stored(display: typed)
        if account.openingBalanceMinor != stored {
          account.openingBalanceMinor = stored
          try await self.dependencies.accounts.save(account)
        }
      }
      for item in draft.newAccounts {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await self.dependencies.debts.createVirtualAccount(
          for: debt.id, currency: item.currency, name: name.isEmpty ? nil : name,
          openingBalanceMinor: DebtSign.stored(display: self.openingMinor(item.opening) ?? 0))
      }
      self.debtDraft = nil
      self.selectedPerson = debt.personKey
      self.filter = debt.isSettled ? .settled : .active
    }
  }

  /// Typed opening balance (display sign) in minor units; empty = zero, nil = not a number.
  private func openingMinor(_ text: String) -> Int64? {
    text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : format.parseAmount(text)
  }

  public func deleteDebt(_ id: Debt.ID) async {
    await perform {
      try await self.dependencies.debts.delete(id)
      self.debtDraft = nil
    }
  }

  // MARK: Settle prompt (R-DEBT-5, R-DEBT-17, C29)

  /// One linked account of the debt that is not archived yet, with the checkbox of the prompt.
  public struct SettleAccountChoice: Identifiable, Equatable, Sendable {
    public let id: Account.ID
    public let name: String
    public let role: DebtAccountRole
    /// The account's balance in its own currency ("€310.00"); a settled debt can hold accounts
    /// with a balance (they are archived as is).
    public let balanceText: String
    public var archive: Bool

    /// "virtual" / "external" for the row's caption.
    public var roleText: String { role == .virtual ? "Virtual account" : "External account" }
  }

  /// "Archive the related accounts?" asked when a debt with non-archived linked accounts is
  /// marked settled.
  public struct SettlePrompt: Identifiable, Equatable, Sendable {
    public let debtID: Debt.ID
    public let personName: String
    public var accounts: [SettleAccountChoice]
    public var id: Debt.ID { debtID }
  }

  public private(set) var settlePrompt: SettlePrompt?

  /// "Mark settled" in the Debts tab and the row / widget menus (R-DEBT-5, C29). A debt with no
  /// non-archived linked account is settled at once; otherwise `settlePrompt` asks which of them to
  /// archive: virtual accounts ticked by default (they exist only for this person), external ones
  /// not (they may be statements still imported). Nothing changes until `confirmSettle`.
  public func requestSettle(_ id: Debt.ID) async {
    await ensureLoaded()
    guard let debt = book.debts.first(where: { $0.id == id }), !debt.isSettled, canSettle(id) else { return }
    let roles = Dictionary(book.links(of: id).map { ($0.accountID, $0.role) }, uniquingKeysWith: { first, _ in first })
    let open = book.accounts(of: id).filter { !$0.isArchived }
    guard !open.isEmpty else { return await setSettled(id, true) }
    let balances = Calc.balances(
      accounts: open, txns: book.txns, through: dependencies.today(), calendar: format.calendar)
    let choices = open.map { account -> SettleAccountChoice in
      let role = roles[account.id] ?? .external
      let balance = balances[account.id] ?? .zero(account.currency)
      return SettleAccountChoice(
        id: account.id, name: account.name, role: role, balanceText: format.money(balance), archive: role == .virtual)
    }
    settlePrompt = SettlePrompt(
      debtID: id, personName: debt.personName.trimmingCharacters(in: .whitespacesAndNewlines), accounts: choices)
  }

  public func setArchiveOnSettle(_ accountID: Account.ID, _ archive: Bool) {
    guard let index = settlePrompt?.accounts.firstIndex(where: { $0.id == accountID }) else { return }
    settlePrompt?.accounts[index].archive = archive
  }

  public func cancelSettlePrompt() { settlePrompt = nil }

  /// "Settle": marks the debt settled and archives the ticked accounts **as they are**, with no
  /// compensation and no forgive record: the debt is already at zero in every currency, so an
  /// account with a balance of its own keeps it in its (archived) history. Reopening the debt
  /// later does not unarchive anything.
  public func confirmSettle() async {
    guard let prompt = settlePrompt, var debt = book.debts.first(where: { $0.id == prompt.debtID }) else {
      settlePrompt = nil
      return
    }
    settlePrompt = nil
    guard canSettle(debt.id) else { return }
    debt.isSettled = true
    let archive = prompt.accounts.filter(\.archive).map(\.id)
    await perform {
      try await self.dependencies.debts.save(debt)
      for id in archive { try await self.dependencies.accounts.setArchived(id, true) }
    }
    if people.isEmpty || !people.contains(where: { $0.id == debt.personKey }) {
      filter = .settled
      selectedPerson = debt.personKey
    }
  }

  /// R-DEBT-5: settled (zero balances only) moves the debt to Settled; unsettle moves it back.
  /// Direct, without the prompt: the UI's "Mark settled" goes through `requestSettle`.
  public func setSettled(_ id: Debt.ID, _ settled: Bool) async {
    await ensureLoaded()
    guard var debt = book.debts.first(where: { $0.id == id }) else { return }
    if settled, !canSettle(id) { return }
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
    } catch DebtRepositoryError.accountLinkedElsewhere(let other) {
      isSaving = false
      errorMessage = "An account is already linked to \(book.debt(other)?.personName ?? "another debt")."
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
