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
  /// The rows loaded so far: the first page(s) of the filtered set, newest (or oldest) first.
  public private(set) var rows: [TxnWithLines] = []
  public private(set) var content: TransactionListContent
  /// Rows per page (C28); the next one loads when the list scrolls near the end.
  public let pageSize: Int
  /// Count and amounts of the WHOLE filtered set (not of `rows`): the footer, "N transactions" and
  /// every day's net come from it.
  public private(set) var summary = TxnListSummary()
  /// More rows of the filtered set than `rows` holds.
  public var hasMoreRows: Bool { !exhausted && rows.count < summary.count }
  public private(set) var isLoadingMore = false
  /// The last rows loaded (about 100): when any of them appears the next page loads. A set, not one
  /// row: dragging the scroller can jump past a single trigger row without realising it.
  public private(set) var loadMoreTriggerIDs: Set<Txn.ID> = []
  @ObservationIgnored private var exhausted = false
  @ObservationIgnored private var builder: TransactionListContent.Builder?
  /// Per dimension, how many rows each value has under the other filters (cascading filters,
  /// C28); nil until computed.
  public private(set) var facetCounts: [TxnFacetDimension: TxnFacetCounts] = [:]
  @ObservationIgnored private var facetGeneration = 0
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

  /// Debts the debt filter offers (R-DEBT-22), A–Z; loaded by `loadDebtOptions()`.
  public private(set) var debtOptions: [DebtFilterOption] = []

  /// Refund links of the loaded rows (C30): per expense its refunds, per refund its original.
  /// Read with each page in two aggregate queries.
  public private(set) var refundLinks = RefundLinkSummary()
  /// "Link a refund…", "This is a refund of…", "Unlink refund"; nil = not offered.
  @ObservationIgnored let refunds: (any RefundRepository)?
  /// The search sheet of a refund link; nil when closed.
  public var refundPicker: RefundPickerModel?

  public init(
    transactions: any TxnRepository, accounts: any AccountRepository,
    categories: any CategoryRepository, events: any EventRepository,
    converter: any CurrencyConverter, displayCurrency: Currency = .UAH,
    refundsReduceSpending: Bool = false, filters: TransactionFilters = .default,
    calendar: Calendar = .current, today: @escaping @Sendable () -> Day = { Day(Date()) },
    settings: (any SettingsRepository)? = nil, debts: (any DebtRepository)? = nil,
    refunds: (any RefundRepository)? = nil, pageSize: Int = 500
  ) {
    self.refunds = refunds
    self.pageSize = max(1, pageSize)
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
    if !filters.debtIDs.isEmpty { await loadDebtOptions() }
    await loadDebtAccounts()
    await reload()
  }

  private func loadDebtAccounts() async {
    guard let debts else { return }
    debtAccountIDs = (try? await debts.book().linkedAccountIDs) ?? []
  }

  // MARK: Paged rows (C28)

  /// Fetches the first page (or, for the same query, as many rows as are loaded, so a refresh
  /// after an edit keeps the scroll position and the selection) and the aggregate of the whole
  /// filtered set, then the facets of the filter menus. Results of an older call that finishes
  /// later are dropped.
  public func reload() async {
    generation += 1
    let current = generation
    guard let query = query else {
      apply(page: [], summary: TxnListSummary(), generation: current, query: nil, links: RefundLinkSummary())
      await loadFacets()
      return
    }
    isLoading = true
    let limit = query == loadedQuery ? max(rows.count, pageSize) : pageSize
    do {
      async let page = transactions.page(matching: query, offset: 0, limit: limit)
      async let aggregate = transactions.summary(matching: query)
      let (fetched, sum) = try await (page, aggregate)
      let links = await links(for: fetched)
      apply(page: fetched, summary: sum, generation: current, query: query, links: links, limit: limit)
    } catch {
      guard current == generation else { return }
      isLoading = false
      errorMessage = "Couldn't load transactions."
    }
    await loadFacets()
  }

  /// The query the rows on screen were fetched with. The list view uses it as its identity: a
  /// different query rebuilds the table in one go instead of diffing thousands of inserted rows
  /// (AppKit sizes every inserted row on the main thread: removing a debt filter that showed
  /// every date hung the app, docs/status/C24.md). Loading the next page keeps it.
  public private(set) var loadedQuery: TxnQuery?

  /// Refund links of a page (two aggregate reads); empty without a refund repository.
  private func links(for page: [TxnWithLines]) async -> RefundLinkSummary {
    guard let refunds, !page.isEmpty else { return RefundLinkSummary() }
    return (try? await refunds.refundLinks(for: page.map(\.txn.id))) ?? RefundLinkSummary()
  }

  private func apply(
    page fetched: [TxnWithLines], summary sum: TxnListSummary, generation current: Int, query: TxnQuery?,
    links: RefundLinkSummary, limit: Int? = nil
  ) {
    guard current == generation else { return }
    loadedQuery = query
    refundLinks = links
    rows = fetched
    summary = sum
    exhausted = limit.map { fetched.count < $0 } ?? true
    isLoading = false
    errorMessage = nil
    if let selection, !fetched.contains(where: { $0.txn.id == selection }) { self.selection = nil }
    rebuild()
  }

  /// Loads the next page and appends it: new rows join the last day section when they share its
  /// day, and the footer, day nets and counts do not change (they cover the whole set).
  public func loadMore() async {
    guard hasMoreRows, !isLoadingMore, !isLoading, let query = loadedQuery, query == self.query,
      let builder
    else { return }
    isLoadingMore = true
    let current = generation
    let offset = rows.count
    let fetched = try? await transactions.page(matching: query, offset: offset, limit: pageSize)
    let pageLinks = await links(for: fetched ?? [])
    isLoadingMore = false
    guard current == generation, let fetched, rows.count == offset else { return }
    if fetched.count < pageSize { exhausted = true }
    guard !fetched.isEmpty else { return }
    rows += fetched
    refundLinks.merge(pageLinks)
    builder.append(fetched, refundLinks: pageLinks, to: &content)
    updateLoadMoreTrigger()
  }

  /// The list calls this when a row appears: the trigger row loads the next page.
  public func rowAppeared(_ id: Txn.ID) {
    guard loadMoreTriggerIDs.contains(id) else { return }
    Task { await loadMore() }
  }

  private func updateLoadMoreTrigger() {
    guard hasMoreRows, !rows.isEmpty else {
      loadMoreTriggerIDs = []
      return
    }
    let lead = max(1, min(100, pageSize / 5))
    loadMoreTriggerIDs = Set(rows.suffix(lead).map(\.txn.id))
  }

  /// The repository query of the current filters (nil: no type is on, nothing matches).
  public var query: TxnQuery? { filters.query(today: today(), calendar: calendar) }

  private func rebuild() {
    let newBuilder = TransactionListContent.Builder(
      summary: summary, reference: reference, displayCurrency: displayCurrency, converter: converter,
      today: today(),
      categoryFilter: filters.categoryIDs.isEmpty ? nil : reference.categories.expanded(filters.categoryIDs),
      includeUncategorised: filters.includeUncategorised,
      refundsReduceSpending: refundsReduceSpending, calendar: calendar)
    builder = newBuilder
    content = newBuilder.content(rows: rows, refundLinks: refundLinks)
    updateLoadMoreTrigger()
  }

  // MARK: Facets (cascading filters, C28)

  /// Recomputes, for every menu, how many rows each value has under all the OTHER filters (four
  /// GROUP BY queries). A newer call supersedes an older one; a cancelled task stops at once.
  public func loadFacets() async {
    facetGeneration += 1
    let mine = facetGeneration
    let base = filters.rawQuery(today: today(), calendar: calendar)
    for dimension in TxnFacetDimension.allCases {
      guard mine == facetGeneration, !Task.isCancelled else { return }
      let counts: TxnFacetCounts
      if filters.matchesNothing(whenDropping: dimension) {
        counts = TxnFacetCounts()
      } else if let fetched = try? await transactions.facets(matching: base, dimension: dimension) {
        counts = fetched
      } else {
        continue
      }
      guard mine == facetGeneration, !Task.isCancelled else { return }
      facetCounts[dimension] = counts
    }
  }

  /// Whether the menu of `dimension` should list a value: it has rows under the other filters, or
  /// it is selected (selected values never disappear, they are marked instead), or the counts are
  /// not known yet.
  private func offers(_ count: Int?, selected: Bool) -> Bool { selected || count == nil || count! > 0 }

  /// Rows under the other filters for an account; nil while unknown.
  public func accountCount(_ id: Account.ID) -> Int? {
    facetCounts[.accounts].map { $0.accounts[id] ?? 0 }
  }

  public func eventCount(_ id: Event.ID) -> Int? {
    facetCounts[.events].map { $0.events[id] ?? 0 }
  }

  public func typeCount(_ type: TxnType) -> Int? {
    facetCounts[.types].map { $0.types[type] ?? 0 }
  }

  /// Rows of the category itself (not summed over children) under the other filters.
  public func categoryCount(_ id: AbacusDomain.Category.ID) -> Int? {
    facetCounts[.categories].map { $0.categories[id] ?? 0 }
  }

  public var uncategorisedCount: Int? { facetCounts[.categories]?.uncategorised }

  /// Whether a debt has rows under the other filters (any of its accounts has some); nil while
  /// unknown.
  public func debtHasRows(_ debt: DebtFilterOption) -> Bool? {
    guard let counts = facetCounts[.accounts] else { return nil }
    return debt.accountIDs.contains { (counts.accounts[$0] ?? 0) > 0 }
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

  /// The categories menu offers "Uncategorised" when such rows exist under the other filters (or
  /// the counts are not known yet), or it is ticked (C28).
  public var showsUncategorisedOption: Bool {
    offers(uncategorisedCount, selected: filters.includeUncategorised)
  }

  /// Ticked but no row is left under the other filters.
  public var isUncategorisedImpossible: Bool { filters.includeUncategorised && uncategorisedCount == 0 }

  /// One line of the categories menu with what the cascading filters know about it.
  public struct CategoryMenuEntry: Identifiable, Hashable, Sendable {
    public var option: TransactionCategoryTree.Option
    /// Rows of the category itself under the other filters; nil for parents and while unknown.
    public var count: Int?
    /// Ticked, yet no row has it under the other filters (it stays visible, marked).
    public var isImpossible: Bool
    public var id: AbacusDomain.Category.ID { option.id }
  }

  /// The categories menu: only categories with rows under the other filters (a parent when it or
  /// a child has some), plus every category the user ticked, even when it has none (C28).
  public var categoryMenu: [CategoryMenuEntry] {
    let tree = reference.categories
    let counts = facetCounts[.categories]?.categories
    // Categories with rows, and their parents.
    var available = Set<AbacusDomain.Category.ID>()
    for (id, count) in counts ?? [:] where count > 0 {
      available.insert(id)
      if let parent = tree.category(id)?.parentID { available.insert(parent) }
    }
    return tree.options.compactMap { option in
      let selected = filters.categoryIDs.contains(option.id)
      // A child under a ticked parent is covered by it; it needs rows of its own to be listed.
      let childSelected = option.hasChildren && tree.children(of: option.id).contains(where: filters.categoryIDs.contains)
      let visible = counts == nil || available.contains(option.id) || selected || childSelected
      guard visible else { return nil }
      let isLeaf = !option.hasChildren
      let count = isLeaf ? counts.map { $0[option.id] ?? 0 } : nil
      let impossible = counts != nil && selected && !available.contains(option.id)
      return CategoryMenuEntry(option: option, count: count, isImpossible: impossible)
    }
  }

  public func toggleUncategorised() { filters.includeUncategorised.toggle() }

  /// "Import: pko_2026-10.csv · Oct 21, 2026" while the list shows one import (R-IMP-6).
  public var importLabel: String? {
    guard let batch = filters.importBatch else { return nil }
    let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
    let day = Day(batch.importedAt, calendar: calendar).date(calendar: calendar).formatted(style)
    return "Import: \(batch.fileName) · \(day)"
  }

  /// The import's file name alone, for the narrow filter bar.
  public var importFileLabel: String? { filters.importBatch?.fileName }

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

  /// "All types", "Expenses", "Expenses, Income", "No types".
  public var typeLabel: String {
    let titles: [(TxnType, String)] = [(.expense, "Expenses"), (.income, "Income"), (.transfer, "Transfers")]
    if filters.types.count == titles.count { return "All types" }
    let on = titles.filter { filters.types.contains($0.0) }.map(\.1)
    return on.isEmpty ? "No types" : on.joined(separator: ", ")
  }

  /// The type menu's lines: every type that has rows under the other filters, and every type that
  /// is ticked while the types are being filtered; with all three on, the ones without rows are
  /// left out (nothing is being filtered by them).
  public var typeMenu: [(type: TxnType, title: String, count: Int?, isImpossible: Bool)] {
    let all: [(TxnType, String)] = [(.expense, "Expense"), (.income, "Income"), (.transfer, "Transfer")]
    return all.compactMap { type, title in
      let count = typeCount(type)
      let on = filters.types.contains(type)
      let shown = count == nil || count! > 0 || (filters.isTypeFiltered && on)
      guard shown else { return nil }
      return (type, title, count, on && count == 0 && filters.isTypeFiltered)
    }
  }

  /// Labels cut short for a narrow window (the filter bar scrolls instead of wrapping, C28).
  public var compactLabels: FilterBarLabels {
    func cut(_ text: String, _ limit: Int = 14) -> String {
      text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
    let date: String
    switch filters.dateRange {
    case .preset(.last30Days): date = "30 days"
    case .preset(.last3Months): date = "3 months"
    case .preset(let preset): date = preset.title
    case .custom where filters.dateRange == TransactionFilters.allDates: date = "All dates"
    case .custom: date = "Custom"
    }
    var categories = categoryLabel
    if filters.categoryIDs.isEmpty && !filters.includeUncategorised {
      categories = "Categories"
    } else if filters.categoryIDs.count + (filters.includeUncategorised ? 1 : 0) == 1 {
      categories = cut(categories)
    }
    let accounts = filters.accountIDs.isEmpty ? "Accounts" : cut(accountLabel)
    let debts = filters.debtIDs.isEmpty ? "Debts" : (filters.debtIDs.count == 1 ? cut(debtLabel, 16) : debtLabel)
    let event = filters.eventID == nil ? "Events" : cut(eventLabel, 16)
    return FilterBarLabels(
      date: date, categories: categories, accounts: accounts, debts: debts,
      types: filters.isTypeFiltered ? typeLabel : "Types", event: event,
      importFile: cut(importFileLabel ?? "Import", 18), sort: filters.newestFirst ? "Newest" : "Oldest")
  }

  public var fullLabels: FilterBarLabels {
    FilterBarLabels(
      date: dateLabel, categories: categoryLabel, accounts: accountLabel, debts: debtLabel, types: typeLabel,
      event: eventLabel, importFile: importLabel ?? "Import", sort: filters.newestFirst ? "Newest first" : "Oldest first")
  }

  /// Accounts offered in the accounts menu: active ones, plus archived ones already selected;
  /// A–Z under their groups (R-MGMT-8).
  public var accountOptions: [Account] {
    accountSections.flatMap(\.accounts)
  }

  /// `accountOptions` in sections: groups A–Z, then the accounts without a group.
  public var accountSections: [AccountPickerSection] {
    AccountOrder.pickerSections(
      reference.accounts.filter { account in
        let selected = filters.accountIDs.contains(account.id)
        // C24: while a debt filter is active, only the selected debts' accounts are offered.
        return (!filters.isDebtFiltered || filters.debtLinkedAccountIDs.contains(account.id))
          // Archived accounts only when selected; accounts without rows under the other filters
          // only when selected too (C28: they stay visible and are marked).
          && (!account.isArchived || selected) && offers(accountCount(account.id), selected: selected)
      },
      groups: reference.accountGroups)
  }

  /// Ticked, yet no row has this account under the other filters.
  public func isAccountImpossible(_ id: Account.ID) -> Bool {
    filters.accountIDs.contains(id) && accountCount(id) == 0
  }

  /// Events offered in the event menu: active ones with rows under the other filters, plus the
  /// selected one.
  public var eventOptions: [Event] {
    reference.events.filter { event in
      let selected = event.id == filters.eventID
      return (!event.isArchived || selected) && offers(eventCount(event.id), selected: selected)
    }
  }

  public var isEventImpossible: Bool { filters.eventID.map { eventCount($0) == 0 } ?? false }

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

  // MARK: Refund links (R-TX-4, C30)

  private func row(_ id: Txn.ID) -> Txn? { rows.first { $0.txn.id == id }?.txn }

  private func isPlainTransaction(_ txn: Txn) -> Bool {
    !txn.isBalanceCorrection && txn.debtRecordID == nil && !txn.isPendingAtBank
  }

  /// An expense that is not a refund: "Link a refund…".
  public func canLinkRefund(_ id: Txn.ID) -> Bool {
    guard refunds != nil, let txn = row(id) else { return false }
    return isPlainTransaction(txn) && txn.type == .expense && !txn.isRefund
  }

  /// An income, or an expense refund that is not linked yet: "This is a refund of…".
  public func canChooseOriginal(_ id: Txn.ID) -> Bool {
    guard refunds != nil, let txn = row(id) else { return false }
    guard isPlainTransaction(txn) else { return false }
    return (txn.type == .income && !txn.isRefund) || (txn.type == .expense && txn.isRefund && txn.refundOfID == nil)
  }

  /// A refund linked to its original: "Unlink refund".
  public func canUnlinkRefund(_ id: Txn.ID) -> Bool {
    guard refunds != nil, let txn = row(id) else { return false }
    return txn.isLinkedRefund
  }

  private func accountNames() -> [Account.ID: String] {
    Dictionary(reference.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private func shortSubtitle(_ txn: Txn) -> String {
    let code = reference.accountsByID[txn.accountID]?.currency.rawValue ?? "UAH"
    let amount = TransactionMoneyFormat().string(minor: txn.amountMinor, code: code)
    let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
    let day = Day(txn.occurredAt, calendar: calendar).date(calendar: calendar).formatted(style)
    return "\(amount) · \(day)"
  }

  /// "Link a refund…": opens the search over incoming transactions that may be the refund of the
  /// expense (same account, not more than what is still open, equal amounts first).
  public func beginLinkRefund(_ id: Txn.ID) async {
    guard canLinkRefund(id), let refunds, let txn = row(id) else { return }
    let picker = RefundPickerModel(
      kind: .chooseRefund, subjectID: id, title: "Link a refund",
      subtitle: (txn.payee.isEmpty ? "Expense" : "“\(txn.payee)”") + " · " + shortSubtitle(txn),
      repository: refunds, accountNames: accountNames(), calendar: calendar)
    refundPicker = picker
    await picker.load()
  }

  /// "This is a refund of…": opens the search over expenses (ranked suggestions + search).
  public func beginChooseOriginal(_ id: Txn.ID) async {
    guard canChooseOriginal(id), let refunds, let txn = row(id) else { return }
    let picker = RefundPickerModel(
      kind: .chooseOriginal, subjectID: id, probe: RefundProbe(txn), title: "This is a refund of…",
      subtitle: (txn.payee.isEmpty ? "Refund" : "“\(txn.payee)”") + " · " + shortSubtitle(txn),
      repository: refunds, accountNames: accountNames(), calendar: calendar)
    refundPicker = picker
    await picker.load()
  }

  public func cancelRefundPicker() { refundPicker = nil }

  /// Links the chosen option: for "This is a refund of…" the subject becomes the refund of the
  /// option (an income turns into an expense refund of the original's category); for "Link a
  /// refund…" the option becomes the refund of the subject. A failure stays in the sheet.
  public func chooseRefundOption(_ optionID: Txn.ID) async {
    guard let refunds, let picker = refundPicker, let subject = picker.subjectID else { return }
    do {
      switch picker.kind {
      case .chooseOriginal: try await refunds.linkRefund(subject, to: optionID)
      case .chooseRefund: try await refunds.linkRefund(optionID, to: subject)
      }
    } catch {
      picker.errorMessage = RefundMessages.text(for: error)
      return
    }
    refundPicker = nil
    errorMessage = nil
    await reload()
    await onDataChange?()
  }

  /// "Unlink refund": the refund keeps its category and follows R-SET-3 again.
  public func unlinkRefund(_ id: Txn.ID) async {
    guard canUnlinkRefund(id), let refunds else { return }
    do {
      try await refunds.unlinkRefund(id)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't unlink the refund."
    }
    await reload()
    await onDataChange?()
  }

  /// Whether `id` is among the loaded rows (the list can scroll to it).
  public func isLoaded(_ id: Txn.ID) -> Bool { rows.contains { $0.txn.id == id } }

  // MARK: Debt filter (R-DEBT-22, docs/status/C21.md)

  /// The debt filter is offered when the model has a debt repository.
  public var offersDebtFilter: Bool { debts != nil }

  /// Reads the debts and their linked account ids (no per-row lookups: the account set of a debt
  /// is computed once here). Safe to call repeatedly; keeps the old options when the read fails.
  public func loadDebtOptions() async {
    guard let debts, let book = try? await debts.book() else { return }
    let ids = Dictionary(grouping: book.links, by: \.debtID).mapValues { Set($0.map(\.accountID)) }
    debtOptions = book.debts
      .map { DebtFilterOption(id: $0.id, name: $0.personName, accountIDs: ids[$0.id] ?? [], isSettled: $0.isSettled) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The options whose name contains `text` (case and diacritics ignored); all for blank text.
  public func debtOptions(matching text: String) -> [DebtFilterOption] {
    let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return debtOptions }
    return debtOptions.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }

  /// Ticks or un-ticks a debt: its linked accounts appear as (or leave) the account entries.
  public func toggleDebt(_ id: Debt.ID) {
    if filters.debtIDs.contains(id) {
      filters.removeDebt(id)
    } else if let option = debtOptions.first(where: { $0.id == id }) {
      filters.addDebt(id, accountIDs: option.accountIDs)
    }
  }

  public func isDebtChecked(_ id: Debt.ID) -> Bool { filters.debtIDs.contains(id) }

  public func debtName(_ id: Debt.ID) -> String { debtOptions.first { $0.id == id }?.name ?? "Unknown" }

  /// "All debts", "Debt: <name>", or "N debts".
  public var debtLabel: String {
    switch filters.debtIDs.count {
    case 0: "All debts"
    case 1: filters.debtIDs.first.map { "Debt: " + debtName($0) } ?? "1 debt"
    default: "\(filters.debtIDs.count) debts"
    }
  }

  /// The debts menu: matching `text`, and only debts with rows under the other filters (any of
  /// their accounts has some) plus the selected ones (C28).
  public func debtMenu(matching text: String) -> [DebtFilterOption] {
    debtOptions(matching: text).filter { offers(debtHasRows($0).map { $0 ? 1 : 0 }, selected: filters.debtIDs.contains($0.id)) }
  }

  /// Ticked, yet none of its accounts has rows under the other filters.
  public func isDebtImpossible(_ debt: DebtFilterOption) -> Bool {
    filters.debtIDs.contains(debt.id) && debtHasRows(debt) == false
  }

  /// Filters for "Show transactions" of a debt: every date, the debt and its accounts selected.
  /// The date range in use now is remembered, so removing the debt filter brings it back (C28).
  /// Nil when the debt is unknown or there is no debt repository.
  public func filters(showingDebt id: Debt.ID) async -> TransactionFilters? {
    await loadDebtOptions()
    guard let option = debtOptions.first(where: { $0.id == id }) else { return nil }
    var shown = TransactionFilters.debt(id, accountIDs: option.accountIDs)
    shown.dateRangeBeforeDebt = filters.dateRangeBeforeDebt ?? filters.dateRange
    return shown
  }
}

/// One debt in the debt filter's picker.
public struct DebtFilterOption: Hashable, Identifiable, Sendable {
  public let id: Debt.ID
  public let name: String
  /// The debt's linked accounts (R-DEBT-17).
  public let accountIDs: Set<Account.ID>
  public let isSettled: Bool
}

/// The texts of the filter bar's buttons (one row; compact ones when the window is narrow).
public struct FilterBarLabels: Hashable, Sendable {
  public var date: String
  public var categories: String
  public var accounts: String
  public var debts: String
  public var types: String
  public var event: String
  public var importFile: String
  public var sort: String
}
