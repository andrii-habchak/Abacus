import AbacusDomain
import AbacusFX
import Foundation
import Observation

/// State of the Transactions screen (approved prototype 2, R-LIST-1…6): filters, fetched rows,
/// and the presented list in the display currency. Works against the repository protocols;
/// `preview()` runs it on `PreviewData`.
@MainActor
@Observable
public final class TransactionsViewModel {
  /// Filter bar and search. Call `reload()` after a change (the view does it per change).
  public var filters: TransactionFilters
  public var displayCurrency: Currency { didSet { if oldValue != displayCurrency { rebuild() } } }
  /// Rates for the day-by-day conversion (R-FX-3); replace it when rates change.
  public var converter: any CurrencyConverter { didSet { rebuild() } }
  /// R-SET-3; off by default.
  public var refundsReduceSpending: Bool { didSet { if oldValue != refundsReduceSpending { rebuild() } } }
  /// The highlighted row.
  public var selection: Txn.ID?

  /// Names and colours the rows show; a change rebuilds the rows at once (R-MGMT-7).
  public private(set) var reference = TransactionsReference() { didSet { if oldValue != reference { rebuild() } } }
  /// Whether any expense or income has no category; the categories menu then offers
  /// "Uncategorised" (R-LIST-2, R-HOME-3). Checked on `load()`.
  public private(set) var hasUncategorised = false
  public private(set) var rows: [TxnWithLines] = []
  public private(set) var content: TransactionListContent
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  @ObservationIgnored private let transactions: any TxnRepository
  @ObservationIgnored private let accounts: any AccountRepository
  @ObservationIgnored private let categories: any CategoryRepository
  @ObservationIgnored private let events: any EventRepository
  /// Where the built-in "Uncategorised" colour is read (D47); nil uses the default.
  @ObservationIgnored private let settings: (any SettingsRepository)?
  @ObservationIgnored private let today: @Sendable () -> Day
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private var generation = 0
  /// "Transfer to debt account…" (R-DEBT-11, R-DEBT-19); nil = not offered.
  @ObservationIgnored private let debts: (any DebtRepository)?
  /// Accounts linked to a debt (external or virtual), read on `load()` and after a change here.
  @ObservationIgnored private var debtAccountIDs: Set<Account.ID> = []

  /// The "Transfer to debt account" sheet; nil when closed.
  public var debtDraft: DebtLinkDraft?
  /// The transaction the sheet converts.
  public private(set) var debtDraftTxnID: Txn.ID?
  /// A conversion changed balances: the dashboard and other screens re-read.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?

  public init(
    transactions: any TxnRepository, accounts: any AccountRepository,
    categories: any CategoryRepository, events: any EventRepository,
    converter: any CurrencyConverter, displayCurrency: Currency = .UAH,
    refundsReduceSpending: Bool = false, filters: TransactionFilters = .default,
    calendar: Calendar = .current, today: @escaping @Sendable () -> Day = { Day(Date()) },
    settings: (any SettingsRepository)? = nil, debts: (any DebtRepository)? = nil
  ) {
    self.settings = settings
    self.debts = debts
    self.transactions = transactions
    self.accounts = accounts
    self.categories = categories
    self.events = events
    self.converter = converter
    self.displayCurrency = displayCurrency
    self.refundsReduceSpending = refundsReduceSpending
    self.filters = filters
    self.calendar = calendar
    self.today = today
    content = .empty(displayCurrency)
  }

  /// The screen on the synthetic preview data, "today" = `PreviewData.today`.
  public static func preview(
    displayCurrency: Currency = .PLN, filters: TransactionFilters = .default
  ) -> TransactionsViewModel {
    let store = TransactionsPreviewStore.preview()
    return TransactionsViewModel(
      transactions: store.transactions, accounts: store.accounts, categories: store.categories,
      events: store.events,
      converter: RateTable.transactionsPreview, displayCurrency: displayCurrency, filters: filters,
      today: { PreviewData.today })
  }

  // MARK: Loading

  /// First call: `load()`; later calls: `reload()`. The view calls it whenever `query` changes.
  public func refresh() async {
    if referenceLoaded { await reload() } else { await load() }
  }

  @ObservationIgnored private var referenceLoaded = false

  /// Accounts, categories or events changed on another screen (a colour, a name): re-reads
  /// them and the rows if the list was shown before; otherwise its first load picks them up.
  public func referenceChanged() async {
    if referenceLoaded { await load() }
  }

  /// Loads accounts, categories and events, then the rows.
  public func load() async {
    referenceLoaded = true
    do {
      let accountList = try await accounts.accounts(includeArchived: true)
      let categoryList = try await categories.categories(kind: nil, includeArchived: true)
      let eventList = try await events.events(includeArchived: true)
      let uncategorisedColor = await settings?.uncategorisedColor() ?? Uncategorised.defaultColorHex
      let groups = (try? await accounts.groups()) ?? []
      reference = TransactionsReference(
        accounts: accountList, categories: categoryList, events: eventList, uncategorisedColor: uncategorisedColor,
        accountGroups: groups)
    } catch {
      errorMessage = "Couldn't load accounts and categories."
    }
    hasUncategorised =
      (try? await transactions.transactions(matching: TxnQuery(includeUncategorised: true)).isEmpty == false)
      ?? false
    await loadDebtAccounts()
    await reload()
  }

  private func loadDebtAccounts() async {
    guard let debts else { return }
    debtAccountIDs = (try? await debts.book().linkedAccountIDs) ?? []
  }

  /// Fetches the rows for the current filters. Results of an older call that finishes later
  /// are dropped.
  public func reload() async {
    generation += 1
    let current = generation
    guard let query = query else {
      apply([], generation: current)
      return
    }
    isLoading = true
    do {
      let fetched = try await transactions.transactions(matching: query)
      apply(fetched, generation: current)
    } catch {
      guard current == generation else { return }
      isLoading = false
      errorMessage = "Couldn't load transactions."
    }
  }

  private func apply(_ fetched: [TxnWithLines], generation current: Int) {
    guard current == generation else { return }
    rows = fetched
    isLoading = false
    errorMessage = nil
    if let selection, !fetched.contains(where: { $0.txn.id == selection }) { self.selection = nil }
    rebuild()
  }

  /// The repository query of the current filters (nil: no type is on, nothing matches).
  public var query: TxnQuery? { filters.query(today: today(), calendar: calendar) }

  private func rebuild() {
    content = TransactionListContent(
      rows: rows, reference: reference, displayCurrency: displayCurrency, converter: converter,
      today: today(),
      categoryFilter: filters.categoryIDs.isEmpty ? nil : reference.categories.expanded(filters.categoryIDs),
      includeUncategorised: filters.includeUncategorised,
      refundsReduceSpending: refundsReduceSpending, calendar: calendar)
  }

  // MARK: Filter bar

  public var todayValue: Day { today() }

  /// The day range the date chip stands for.
  public var dateRange: ClosedRange<Day> { filters.days(today: today(), calendar: calendar) }

  public var dateLabel: String {
    switch filters.dateRange {
    case .preset(let preset): return preset.title
    case .custom where filters.dateRange == TransactionFilters.allDates:
      return "All dates"
    case .custom(let from, let to):
      let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
      let fromText = from.date(calendar: calendar).formatted(style)
      let toText = to.date(calendar: calendar).formatted(style)
      return from == to ? fromText : "\(fromText) – \(toText)"
    }
  }

  /// "All categories", "Uncategorised", one category's path, or "N categories" (Uncategorised
  /// counts as one).
  public var categoryLabel: String {
    guard filters.includeUncategorised else { return reference.categories.label(for: filters.categoryIDs) }
    return filters.categoryIDs.isEmpty ? Self.uncategorisedTitle : "\(filters.categoryIDs.count + 1) categories"
  }

  public static let uncategorisedTitle = Uncategorised.title

  /// The categories menu offers "Uncategorised" when such transactions exist or it is ticked.
  public var showsUncategorisedOption: Bool { hasUncategorised || filters.includeUncategorised }

  public func toggleUncategorised() { filters.includeUncategorised.toggle() }

  /// "Import: pko_2026-10.csv · Oct 21, 2026" while the list shows one import (R-IMP-6).
  public var importLabel: String? {
    guard let batch = filters.importBatch else { return nil }
    let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
    let day = Day(batch.importedAt, calendar: calendar).date(calendar: calendar).formatted(style)
    return "Import: \(batch.fileName) · \(day)"
  }

  /// Removes the import filter only; the other filters stay.
  public func clearImportFilter() { filters.importBatch = nil }

  public var accountLabel: String {
    switch filters.accountIDs.count {
    case 0: return "All accounts"
    case 1: return filters.accountIDs.first.flatMap { reference.accountsByID[$0]?.name } ?? "1 account"
    default: return "\(filters.accountIDs.count) accounts"
    }
  }

  public var eventLabel: String {
    guard let id = filters.eventID else { return "Any event" }
    return "Event: " + (reference.eventsByID[id]?.name ?? "Unknown")
  }

  /// Accounts offered in the accounts menu: active ones, plus archived ones already selected;
  /// A–Z under their groups (R-MGMT-8).
  public var accountOptions: [Account] {
    accountSections.flatMap(\.accounts)
  }

  /// `accountOptions` in sections: groups A–Z, then the accounts without a group.
  public var accountSections: [AccountPickerSection] {
    AccountOrder.pickerSections(
      reference.accounts.filter { !$0.isArchived || filters.accountIDs.contains($0.id) },
      groups: reference.accountGroups)
  }

  /// Events offered in the event menu: active ones, plus the selected one.
  public var eventOptions: [Event] {
    reference.events.filter { !$0.isArchived || $0.id == filters.eventID }
  }

  public func toggleCategory(_ id: AbacusDomain.Category.ID) {
    filters.categoryIDs = reference.categories.toggled(id, in: filters.categoryIDs)
  }

  public func isCategoryChecked(_ id: AbacusDomain.Category.ID) -> Bool {
    reference.categories.isChecked(id, in: filters.categoryIDs)
  }

  public func clearFilters() { filters.clear() }

  // MARK: Transfer to a debt account (R-DEBT-11, R-DEBT-19, docs/status/C22.md)

  /// An expense or income on an account that is not a debt's own.
  public func canConvertToDebt(_ id: Txn.ID) -> Bool {
    guard debts != nil, let txn = rows.first(where: { $0.txn.id == id })?.txn else { return false }
    return txn.type != .transfer && !debtAccountIDs.contains(txn.accountID)
  }

  /// A transfer between my account and a linked account of a debt: "Undo transfer to debt".
  public func canUnlinkTransfer(_ id: Txn.ID) -> Bool {
    guard debts != nil, let txn = rows.first(where: { $0.txn.id == id })?.txn, txn.type == .transfer,
      let to = txn.toAccountID
    else { return false }
    return debtAccountIDs.contains(txn.accountID) != debtAccountIDs.contains(to)
  }

  /// The transfer becomes an expense or income on my account again (no category).
  public func unlinkTransfer(_ id: Txn.ID) async {
    guard canUnlinkTransfer(id), let debts else { return }
    do {
      try await debts.unlinkTransfer(id)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't undo the transfer to the debt."
    }
    await loadDebtAccounts()
    await reload()
    await onDataChange?()
  }

  /// Opens the sheet for the transaction: person, the person's account, the amount across
  /// currencies.
  public func beginConvertToDebt(_ id: Txn.ID) async {
    guard canConvertToDebt(id), let debts, let txn = rows.first(where: { $0.txn.id == id })?.txn,
      let account = reference.accountsByID[txn.accountID]
    else { return }
    let book: DebtBook
    do {
      book = try await debts.book()
    } catch {
      errorMessage = "Couldn't load debts."
      return
    }
    let inflow = (txn.type == .income) != txn.isRefund
    let day = Day(txn.occurredAt, calendar: calendar)
    var converted: [Currency: Int64] = [:]
    for currency in Currency.allCases where currency != account.currency {
      if let original = txn.originalAmountMinor, txn.originalCurrencyCode == currency.rawValue {
        converted[currency] = original
      } else if let money = converter.convert(
        Money(minorUnits: txn.amountMinor, currency: account.currency), to: currency, on: day)
      {
        converted[currency] = money.minorUnits
      }
    }
    let money = TransactionMoneyFormat()
    let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
    let amount = money.string(minor: inflow ? txn.amountMinor : -txn.amountMinor, code: account.currency.rawValue, sign: .always)
    debtDraftTxnID = id
    debtDraft = DebtLinkDraft(
      title: txn.payee.isEmpty ? "Transfer to debt account" : "Transfer “\(txn.payee)” to a debt account",
      subtitle: "\(amount) on \(account.name) · \(day.date(calendar: calendar).formatted(style))",
      inflow: inflow, accountCurrency: account.currency, accountAmountMinor: txn.amountMinor, book: book,
      convertedAmounts: converted)
  }

  public func cancelConvertToDebt() {
    debtDraft = nil
    debtDraftTxnID = nil
  }

  /// Saves the sheet: the transaction becomes a transfer to the person's account in place (no
  /// second transaction). Takes the draft the sheet showed (SwiftUI may clear the binding first).
  public func saveConvertToDebt(_ draft: DebtLinkDraft? = nil) async {
    guard let draft = draft ?? debtDraft, let id = debtDraftTxnID, let link = draft.link, let debts else { return }
    debtDraft = nil
    debtDraftTxnID = nil
    do {
      try await debts.transferToDebt(id, to: link)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't make the transaction a transfer to the debt account."
    }
    await loadDebtAccounts()
    await reload()
    await onDataChange?()
  }
}
