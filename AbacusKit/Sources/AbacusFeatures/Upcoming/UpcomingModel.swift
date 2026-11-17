import AbacusDomain
import AbacusFX
import Foundation
import Observation

/// What "Mark paid" hands the transaction editor (R-REC-4): the template of the item and the
/// occurrence the saved transaction pays.
public struct ScheduledPayment: Hashable, Sendable {
  public var itemID: ScheduledItem.ID
  public var expectedDay: Day
  public var template: TransactionTemplate

  public init(itemID: ScheduledItem.ID, expectedDay: Day, template: TransactionTemplate) {
    self.itemID = itemID
    self.expectedDay = expectedDay
    self.template = template
  }
}

/// The Upcoming section (R-REC-10, R-REC-4, R-REC-8, R-REC-16): Bills (grouped occurrences with
/// header totals and row actions), All items (search, next date, monthly cost) and the
/// suggestions card; the item editor sheet (`ScheduledItemEditorModel`, R-REC-12). The Forecast
/// tab is another model (N5d). Also feeds the sidebar badge and the dashboard widget.
@MainActor
@Observable
public final class UpcomingModel {
  public enum Phase: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
  }

  /// The toolbar tabs (prototype: Bills · Forecast).
  public enum Tab: String, CaseIterable, Identifiable, Sendable {
    case bills, forecast
    public var id: Self { self }
    public var title: String { self == .bills ? "Bills" : "Forecast" }
  }

  /// The Bills tab's views (prototype: Upcoming · All items).
  public enum View: String, CaseIterable, Identifiable, Sendable {
    case upcoming, all
    public var id: Self { self }
  }

  public static let ranges = [7, 30, 90]

  public private(set) var phase: Phase = .idle
  public var tab: Tab = .bills
  public var view: View = .upcoming
  /// Bills range in days (R-REC-10: 7 / 30 / 90, default 30).
  public var rangeDays = 30
  public var displayCurrency: Currency = .UAH
  /// All items search.
  public var search = ""
  /// The suggestions card is collapsed ("Hide").
  public var suggestionsCollapsed = false
  /// "Show dismissed" in the suggestions card (R-REC-16).
  public var showsDismissed = false
  /// The item editor sheet while non-nil (R-REC-12).
  public var editor: ScheduledItemEditorModel?
  /// "Link existing…" picker while non-nil (R-REC-4).
  public var linkPicker: UpcomingLinkPicker?
  /// A short confirmation ("Skipped Phone plan · 22 Nov.") or an error.
  public var notice: String?

  public private(set) var items: [ScheduledItem] = []
  public private(set) var stored: [ScheduledOccurrence] = []
  public private(set) var accounts: [Account] = []
  public private(set) var categories: [AbacusDomain.Category] = []
  public private(set) var suggestions: [SubscriptionSuggestion] = []
  public private(set) var dismissals: [SuggestionDismissal] = []
  public private(set) var today: Day
  public private(set) var graceDays = ScheduledOccurrences.defaultGraceDays
  /// The rates both tabs (Bills and All items) convert with. Observed, so a new table redraws the
  /// totals, the "≈" lines and the monthly average (QA-N2 H1).
  public private(set) var converter: any CurrencyConverter = RateTable()
  /// Bumped last whenever `converter` is replaced: an observed value that always changes, so views
  /// that only read derived figures still recompute after new rates arrive.
  public private(set) var ratesVersion = 0
  /// Evidence rows of the suggestions (day and amount).
  @ObservationIgnored private var evidence: [Txn.ID: Txn] = [:]
  /// "Not now": suggestion id → its newest row's day; shown again when a newer row arrives.
  @ObservationIgnored private var notNow: [String: Day] = [:]
  public private(set) var notNowCount = 0

  /// "Mark paid": the shell opens the transaction editor pre-filled (R-REC-4).
  @ObservationIgnored public var onMarkPaid: (@MainActor (ScheduledPayment) -> Void)?
  /// Items or occurrences changed (badge, dashboard widget, forecast).
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?

  @ObservationIgnored let dependencies: UpcomingDependencies

  public init(dependencies: UpcomingDependencies) {
    self.dependencies = dependencies
    today = dependencies.today()
  }

  public var format: ManageFormat { dependencies.format }

  // MARK: Loading

  /// Items, stored occurrences, accounts, categories and rates; then the suggestions (off the
  /// main actor, R-REC-21).
  public func load() async {
    if phase != .loaded { phase = .loading }
    today = dependencies.today()
    do {
      async let items = dependencies.scheduled.items()
      async let stored = dependencies.scheduled.occurrences(itemID: nil)
      async let accounts = dependencies.accounts.accounts(includeArchived: true)
      async let categories = dependencies.categories.categories(kind: nil, includeArchived: true)
      async let dismissals = dependencies.scheduled.dismissals()
      (self.items, self.stored, self.accounts, self.categories, self.dismissals) =
        try await (items, stored, accounts, categories, dismissals)
      graceDays = (try? await dependencies.settings.value(.scheduledGraceDays)).flatMap { $0.flatMap(Int.init) }
        ?? ScheduledOccurrences.defaultGraceDays
      let rates = await dependencies.converter()
      phase = .loaded
      setRates(rates)
    } catch {
      phase = .failed("Couldn't load scheduled items: \(error.localizedDescription)")
      return
    }
    await loadSuggestions()
  }

  /// New rates: totals and converted amounts follow.
  public func refreshRates() async {
    setRates(await dependencies.converter())
  }

  private func setRates(_ rates: any CurrencyConverter) {
    converter = rates
    ratesVersion &+= 1
  }

  private func loadSuggestions() async {
    let today = today
    let from = today.plusDays(-SubscriptionDetector.windowDays)
    guard let rows = try? await dependencies.transactions.transactions(matching: TxnQuery(fromDay: from, toDay: today))
    else { return }
    let txns = rows.map(\.txn)
    let accounts = accounts
    let matched = Set(stored.compactMap(\.txnID))
    let dismissed = Set(dismissals.map { SubscriptionDetector.dismissalID(accountID: $0.accountID, key: $0.key) })
    let calendar = dependencies.calendar
    let found = await Task.detached(priority: .utility) {
      SubscriptionDetector.detect(
        txns: txns, accounts: accounts, matchedTxnIDs: matched, dismissed: dismissed, today: today, calendar: calendar)
    }.value
    // An item already covering the pattern (same account, type and description) is not suggested.
    let covered = Set(items.compactMap { item in
      accounts.first { $0.id == item.accountID }.flatMap { account in
        SubscriptionDetector.key(description: item.payee, type: item.type, currency: account.currency)
          .map { "\(item.accountID.uuidString)|\($0)" }
      }
    })
    suggestions = found.filter { !covered.contains($0.id) }
    let wanted = Set(found.flatMap(\.evidence))
    evidence = Dictionary(txns.filter { wanted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  }

  // MARK: Bills

  /// Occurrences of the range (expected and resolved, R-REC-10).
  public var occurrences: [UpcomingOccurrence] {
    UpcomingCalc.occurrences(
      items: items, stored: stored, accounts: accounts, today: today, rangeDays: rangeDays, graceDays: graceDays)
  }

  public var groups: [(group: UpcomingGroup, rows: [UpcomingRow])] {
    UpcomingCalc.grouped(occurrences, today: today).map { ($0.group, $0.rows.map(row)) }
  }

  public var totals: UpcomingTotals {
    UpcomingCalc.totals(occurrences, accounts: accounts, currency: displayCurrency, converter: converter)
  }

  /// Sidebar badge: overdue plus the next 7 days (R-REC-10).
  public var badgeCount: Int {
    UpcomingCalc.badgeCount(items: items, stored: stored, accounts: accounts, today: today, graceDays: graceDays)
  }

  /// "Converted at the latest rates · rates as of 3 Nov 2026. Transfers are not counted."
  public var totalsNote: String {
    var text = "Converted at the latest rates"
    if let day = converter.latestDay { text += " · rates as of \(dayText(day, year: true))" }
    text += ". Transfers are not counted."
    let missing = totals.unconverted
    if !missing.isEmpty {
      text += " No rate for \(missing.map(\.rawValue).sorted().joined(separator: ", ")); left out."
    }
    return text
  }

  public func money(_ minor: Int64, _ currency: Currency) -> String {
    format.money(Money(minorUnits: minor, currency: currency))
  }

  /// "+4,365.70 zł" / "−4,365.70 zł".
  public func signedMoney(_ minor: Int64, _ currency: Currency) -> String {
    (minor < 0 ? "−" : "+") + money(abs(minor), currency)
  }

  func row(_ occurrence: UpcomingOccurrence) -> UpcomingRow {
    let item = occurrence.item
    let account = accounts.first { $0.id == item.accountID }
    var chip: UpcomingRow.Chip?
    var resolvedText: String?
    if let resolved = occurrence.resolved {
      chip = resolved.status == .paid ? .paid : .skipped
      if resolved.status == .paid {
        resolvedText =
          switch resolved.matchKind {
          case .auto?: "Matched to a transaction" + (resolved.actualDay.flatMap(Day.init).map { " on \(dayText($0))" } ?? "")
          case .linked?: "Linked to a transaction"
          default: "Marked paid"
          }
      }
    } else if occurrence.day < today {
      chip = .overdue
    } else if occurrence.day == today {
      chip = .today
    }
    let amounts = amountTexts(item, account: account)
    return UpcomingRow(
      occurrence: occurrence, title: item.payee.isEmpty ? "Untitled" : item.payee,
      subtitle: [categoryName(item), UpcomingCalc.repeatLabel(item)].compactMap { $0 }.joined(separator: " · "),
      accountText: accountText(item), dayText: longDayText(occurrence.day),
      relativeText: UpcomingCalc.relative(occurrence.day, today: today), amountText: amounts.main,
      convertedText: amounts.converted, isIncome: item.type == .income, colorHex: color(item),
      chip: chip, resolvedText: resolvedText)
  }

  func amountTexts(_ item: ScheduledItem, account: Account?) -> (main: String, converted: String?) {
    guard let account else { return (money(item.amountMinor, displayCurrency), nil) }
    let main: String =
      switch item.type {
      case .expense: "−" + money(item.amountMinor, account.currency)
      case .income: "+" + money(item.amountMinor, account.currency)
      case .transfer: money(item.amountMinor, account.currency)
      }
    guard account.currency != displayCurrency,
      let converted = converter.convertAtLatest(Money(minorUnits: item.amountMinor, currency: account.currency), to: displayCurrency)
    else { return (main, nil) }
    let sign = item.type == .expense ? "−" : item.type == .income ? "+" : ""
    return (main, "≈ " + sign + format.money(converted))
  }

  func categoryName(_ item: ScheduledItem) -> String? {
    if item.type == .transfer { return "Transfer" }
    return item.categoryID.flatMap { id in categories.first { $0.id == id }?.name }
  }

  func color(_ item: ScheduledItem) -> String? {
    if let id = item.categoryID, let category = categories.first(where: { $0.id == id }) {
      return category.colorHex ?? category.parentID.flatMap { parent in categories.first { $0.id == parent }?.colorHex }
    }
    return accounts.first { $0.id == item.accountID }?.colorHex
  }

  func accountText(_ item: ScheduledItem) -> String {
    let name = accounts.first { $0.id == item.accountID }?.name ?? "Account missing"
    guard item.type == .transfer, let to = item.toAccountID else { return name }
    return name + " → " + (accounts.first { $0.id == to }?.name ?? "Account missing")
  }

  /// "Thu 5 Nov".
  public func longDayText(_ day: Day) -> String {
    day.date(calendar: dependencies.calendar).formatted(
      Date.FormatStyle(locale: format.locale, calendar: dependencies.calendar, timeZone: dependencies.calendar.timeZone)
        .weekday(.abbreviated).day().month(.abbreviated))
  }

  /// "5 Nov" (or "5 Nov 2026").
  public func dayText(_ day: Day, year: Bool = false) -> String {
    let style = Date.FormatStyle(locale: format.locale, calendar: dependencies.calendar, timeZone: dependencies.calendar.timeZone)
      .day().month(.abbreviated)
    return day.date(calendar: dependencies.calendar).formatted(year ? style.year() : style)
  }

  // MARK: Row actions (R-REC-4)

  /// Opens the New transaction editor pre-filled from the template; saving it pays the
  /// occurrence (the shell calls `paid(_:txnID:)`).
  public func markPaid(_ occurrence: UpcomingOccurrence) {
    let item = occurrence.item
    let template = TransactionTemplate(
      type: item.type, accountID: item.accountID, toAccountID: item.toAccountID, amountMinor: item.amountMinor,
      toAmountMinor: item.toAmountMinor, categoryID: item.categoryID, eventID: item.eventID, payee: item.payee,
      note: item.note)
    onMarkPaid?(ScheduledPayment(itemID: item.id, expectedDay: occurrence.day, template: template))
  }

  /// The editor saved the transaction of a "Mark paid".
  public func paid(_ payment: ScheduledPayment, txnID: Txn.ID) async {
    await perform {
      try await self.dependencies.scheduled.markPaid(
        itemID: payment.itemID, expectedDay: payment.expectedDay, txnID: txnID, kind: .typed)
    }
  }

  public func skip(_ occurrence: UpcomingOccurrence) async {
    let ok = await perform {
      try await self.dependencies.scheduled.skip(itemID: occurrence.item.id, expectedDay: occurrence.day)
    }
    if ok { notice = "Skipped \(occurrence.item.payee) · \(dayText(occurrence.day)). It leaves the forecast." }
  }

  /// Unlink a paid occurrence (its transaction is not matched again) or undo a skip.
  public func reopen(_ occurrence: UpcomingOccurrence) async {
    guard let resolved = occurrence.resolved else { return }
    await perform { try await self.dependencies.scheduled.reopen(resolved.id) }
  }

  /// "Link existing…": transactions on the item's account of its type within ±3 days of the
  /// expected day (the match window), not linked to another occurrence; nearest first.
  public func beginLink(_ occurrence: UpcomingOccurrence) async {
    let item = occurrence.item
    let window = dependencies.matcher.dayWindow
    let query = TxnQuery(
      fromDay: occurrence.day.plusDays(-window), toDay: occurrence.day.plusDays(window), accountIDs: [item.accountID],
      types: [item.type])
    do {
      let rows = try await dependencies.transactions.transactions(matching: query)
      let linked = Set(stored.compactMap(\.txnID))
      let calendar = dependencies.calendar
      let currency = accounts.first { $0.id == item.accountID }?.currency ?? displayCurrency
      let candidates = rows.map(\.txn).compactMap { txn -> (Txn, ScheduledProbe)? in
        guard !linked.contains(txn.id), let probe = dependencies.matcher.probe(txn, calendar: calendar),
          probe.accountID == item.accountID, probe.type == item.type
        else { return nil }
        return (txn, probe)
      }
      .sorted {
        (abs($0.1.day.daysUntil(occurrence.day)), abs($0.1.amountMinor - item.amountMinor), $0.0.id.uuidString)
          < (abs($1.1.day.daysUntil(occurrence.day)), abs($1.1.amountMinor - item.amountMinor), $1.0.id.uuidString)
      }
      .map { txn, probe in
        let delta = probe.day.daysUntil(occurrence.day) * -1
        return UpcomingLinkPicker.Candidate(
          txnID: txn.id, payee: txn.payee.isEmpty ? "—" : txn.payee, dayText: longDayText(probe.day),
          deltaText: delta == 0 ? "same day" : delta > 0 ? "\(delta) day\(delta == 1 ? "" : "s") late" : "\(-delta) day\(delta == -1 ? "" : "s") early",
          amountText: money(probe.amountMinor, currency))
      }
      linkPicker = UpcomingLinkPicker(
        occurrence: occurrence,
        title: "\(occurrence.item.payee) · \(dayText(occurrence.day))",
        windowText: "Transactions on \(accountText(item)) within ±\(window) days of \(dayText(occurrence.day))",
        candidates: candidates)
    } catch {
      notice = "Couldn't read the transactions: \(error.localizedDescription)"
    }
  }

  public func link(_ txnID: Txn.ID) async {
    guard let picker = linkPicker else { return }
    linkPicker = nil
    await perform {
      try await self.dependencies.scheduled.markPaid(
        itemID: picker.occurrence.item.id, expectedDay: picker.occurrence.day, txnID: txnID, kind: .linked)
    }
  }

  // MARK: All items

  public var allRows: [ScheduledItemRow] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return items
      .filter { query.isEmpty || $0.payee.localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) }
      .sorted { (statusOrder($0), $0.payee.lowercased()) < (statusOrder($1), $1.payee.lowercased()) }
      .map(itemRow)
  }

  private func statusOrder(_ item: ScheduledItem) -> Int {
    switch item.status {
    case .active: 0
    case .paused: 1
    case .ended: 2
    }
  }

  func itemRow(_ item: ScheduledItem) -> ScheduledItemRow {
    let account = accounts.first { $0.id == item.accountID }
    let chip: String? =
      if account == nil { "Account missing" }
      else if item.status == .paused { item.pausedBecause == .accountArchived ? "Account archived" : "Paused" }
      else if item.status == .ended { "Ended" }
      else { nil }
    let next = item.status == .active ? UpcomingCalc.nextDay(item, today: today) : nil
    let amounts = amountTexts(item, account: account)
    let kind = item.type == .transfer ? "Transfer" : item.type == .income ? "Income" : "Expense"
    return ScheduledItemRow(
      item: item, title: item.payee.isEmpty ? "Untitled" : item.payee,
      subtitle: [item.type == .transfer ? nil : categoryName(item), kind].compactMap { $0 }.joined(separator: " · "),
      accountText: accountText(item), repeatText: UpcomingCalc.repeatLabel(item),
      nextText: next.map { "Next \(dayText($0))" } ?? "Next —", amountText: amounts.main,
      convertedText: amounts.converted, isIncome: item.type == .income, colorHex: color(item), chip: chip,
      isDimmed: item.status != .active || account == nil)
  }

  /// "Average per month (display currency, excluding transfers): −1,234.00 zł".
  public var monthlyAverageText: String {
    let average = UpcomingCalc.monthlyAverage(items, accounts: accounts, currency: displayCurrency, converter: converter)
    var text = signedMoney(average.minor, displayCurrency)
    if !average.unconverted.isEmpty {
      text += " (no rate for \(average.unconverted.map(\.rawValue).sorted().joined(separator: ", ")))"
    }
    return text
  }

  // MARK: Suggestions (R-REC-8, R-REC-16)

  public var visibleSuggestions: [SuggestionRow] {
    suggestions.filter { suggestion in notNow[suggestion.id].map { suggestion.latestDay > $0 } ?? true }.map(suggestionRow)
  }

  func suggestionRow(_ suggestion: SubscriptionSuggestion) -> SuggestionRow {
    let account = accounts.first { $0.id == suggestion.accountID }
    let period =
      switch suggestion.period {
      case .weekly: "Weekly"
      case .biweekly: "Every 2 weeks"
      case .monthly: "Monthly"
      case .quarterly: "Every 3 months"
      case .yearly: "Yearly"
      }
    let evidence = suggestion.evidence.compactMap { self.evidence[$0] }.suffix(6).map { txn in
      dayText(Day(txn.occurredAt, calendar: dependencies.calendar)) + " · " + format.amountInput(txn.amountMinor)
    }
    let category = suggestion.categoryID.flatMap { id in categories.first { $0.id == id } }
    return SuggestionRow(
      suggestion: suggestion, title: suggestion.description,
      confidenceText: suggestion.confidence == .high ? "High confidence" : "Medium confidence",
      isHighConfidence: suggestion.confidence == .high,
      subtitle: "\(period) · next \(dayText(suggestion.nextDay)) · \(account?.name ?? "Account missing")",
      amountText: (suggestion.type == .income ? "+" : "−") + money(suggestion.amountMinor, suggestion.currency),
      evidence: Array(evidence), colorHex: category?.colorHex ?? account?.colorHex)
  }

  /// "Accept…": the editor pre-filled from the suggestion, with its evidence rows (R-REC-12).
  public func accept(_ suggestion: SubscriptionSuggestion) {
    let draft = ScheduledItemDraft(suggestion: suggestion, format: format)
    let evidence = suggestionRow(suggestion).evidence
    openEditor(ScheduledItemEditorModel(draft: draft, evidence: evidence, suggestion: suggestion, upcoming: self))
  }

  /// "Not now": hidden until a newer matching transaction arrives (this session).
  public func notNow(_ suggestion: SubscriptionSuggestion) {
    notNow[suggestion.id] = suggestion.latestDay
    notNowCount = notNow.count
    notice = "Hidden until a new matching transaction arrives."
  }

  /// "Dismiss": for good (R-REC-16).
  public func dismiss(_ suggestion: SubscriptionSuggestion) async {
    let ok = await perform(reloadsData: false) {
      try await self.dependencies.scheduled.dismiss(accountID: suggestion.accountID, key: suggestion.key)
    }
    guard ok else { return }
    notice = "Dismissed for good. “Show dismissed” brings it back."
    await load()
  }

  /// "Show dismissed" → Restore.
  public func restore(_ dismissal: SuggestionDismissal) async {
    let ok = await perform(reloadsData: false) { try await self.dependencies.scheduled.restore(dismissal.id) }
    if ok { await load() }
  }

  /// "Language app · Main account" for a dismissed row (the key's normalised text).
  public func dismissalText(_ dismissal: SuggestionDismissal) -> String {
    let text = dismissal.key.split(separator: "|").first.map(String.init) ?? dismissal.key
    let account = accounts.first { $0.id == dismissal.accountID }?.name ?? "Account missing"
    return "\(text) · \(account)"
  }

  // MARK: Editor (R-REC-12)

  public func newItem() {
    var draft = ScheduledItemDraft(today: today, format: format)
    draft.accountID = accounts.first { !$0.isArchived }?.id
    openEditor(ScheduledItemEditorModel(draft: draft, upcoming: self))
  }

  public func edit(_ id: ScheduledItem.ID) {
    guard let item = items.first(where: { $0.id == id }) else { return }
    openEditor(ScheduledItemEditorModel(draft: ScheduledItemDraft(item: item, format: format), upcoming: self))
  }

  private func openEditor(_ model: ScheduledItemEditorModel) {
    linkPicker = nil
    editor = model
    Task { await model.loadReference() }
  }

  /// The editor saved, paused or deleted an item.
  func editorFinished(notice: String?) async {
    editor = nil
    self.notice = notice
    await load()
    await onDataChange?()
  }

  // MARK: Helpers

  /// Runs a store write, reloads and tells the shell; false (with a notice) when it failed.
  @discardableResult
  func perform(reloadsData: Bool = true, _ write: @escaping () async throws -> Void) async -> Bool {
    do {
      try await write()
    } catch {
      notice = Self.message(error)
      return false
    }
    if reloadsData {
      await load()
      await onDataChange?()
    }
    return true
  }

  static func message(_ error: any Error) -> String {
    switch error {
    case ScheduledError.invalidItem(let text): text + "."
    case ScheduledError.notAnOccurrence: "That day is not an occurrence of the item."
    case ScheduledError.occurrenceAlreadyPaid: "This occurrence is already paid."
    case ScheduledError.transactionAlreadyLinked: "That transaction already pays another occurrence."
    default: error.localizedDescription
    }
  }
}

/// A Bills row (R-REC-10): tile, description, "Category · Monthly", account, day, amount.
public struct UpcomingRow: Identifiable, Hashable, Sendable {
  public enum Chip: Hashable, Sendable {
    case overdue, today, paid, skipped

    public var title: String {
      switch self {
      case .overdue: "Overdue"
      case .today: "Today"
      case .paid: "Paid"
      case .skipped: "Skipped"
      }
    }
  }

  public var id: String { occurrence.id }
  public let occurrence: UpcomingOccurrence
  public let title: String
  public let subtitle: String
  public let accountText: String
  public let dayText: String
  public let relativeText: String
  public let amountText: String
  /// "≈ −36.46 zł" when the account currency is not the display currency.
  public let convertedText: String?
  public let isIncome: Bool
  public let colorHex: String?
  public let chip: Chip?
  /// "Matched to a transaction on 4 Nov" for a paid row.
  public let resolvedText: String?

  public var initial: String { String(title.first.map { String($0).uppercased() } ?? "•") }
  public var isResolved: Bool { occurrence.resolved != nil }
  public var isOverdue: Bool { chip == .overdue }
}

/// An All items row (R-REC-10).
public struct ScheduledItemRow: Identifiable, Hashable, Sendable {
  public var id: ScheduledItem.ID { item.id }
  public let item: ScheduledItem
  public let title: String
  public let subtitle: String
  public let accountText: String
  public let repeatText: String
  public let nextText: String
  public let amountText: String
  public let convertedText: String?
  public let isIncome: Bool
  public let colorHex: String?
  /// "Paused", "Account archived", "Ended", "Account missing".
  public let chip: String?
  public let isDimmed: Bool

  public var initial: String { String(title.first.map { String($0).uppercased() } ?? "•") }
}

/// A suggestion card row (R-REC-8).
public struct SuggestionRow: Identifiable, Hashable, Sendable {
  public var id: String { suggestion.id }
  public let suggestion: SubscriptionSuggestion
  public let title: String
  public let confidenceText: String
  public let isHighConfidence: Bool
  public let subtitle: String
  public let amountText: String
  /// "6 Jul · 29.99".
  public let evidence: [String]
  public let colorHex: String?

  public var initial: String { String(title.first.map { String($0).uppercased() } ?? "•") }
}

/// "Link existing…" (R-REC-4).
public struct UpcomingLinkPicker: Identifiable, Hashable, Sendable {
  public struct Candidate: Identifiable, Hashable, Sendable {
    public var id: Txn.ID { txnID }
    public let txnID: Txn.ID
    public let payee: String
    public let dayText: String
    /// "1 day early", "same day".
    public let deltaText: String
    public let amountText: String
  }

  public var id: String { occurrence.id }
  public let occurrence: UpcomingOccurrence
  public let title: String
  public let windowText: String
  public let candidates: [Candidate]
}
