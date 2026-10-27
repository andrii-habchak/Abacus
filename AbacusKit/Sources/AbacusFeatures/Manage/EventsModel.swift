import AbacusDomain
import Foundation
import Observation

/// One event row (R-MGMT-4): name, dates, spent and budget.
public struct EventRow: Identifiable, Equatable, Sendable {
  public let id: Event.ID
  public let name: String
  /// "01.10 – 19.10.2026" / "No dates (ongoing)".
  public let dates: String
  public let spentText: String
  /// "of €300.00 budget" / "no budget".
  public let budgetText: String
  public let status: LimitStatus?
  public let isArchived: Bool
  /// The event's colour (R-EVT-1).
  public var colorHex: String? = nil
}

/// One category bar of an event's spending (R-EVT-3, R-EVT-4).
public struct EventCategoryBar: Identifiable, Equatable, Sendable {
  public let id: CategoryKey
  public let name: String
  public let colorHex: String?
  public let amountText: String
  /// Relative to the largest category, 0…1.
  public let fraction: Double
}

/// The inspector form of an event (R-EVT-1). Each end of the date range is optional.
public struct EventDraft: Equatable, Sendable {
  public let id: Event.ID
  public let isNew: Bool
  public var name: String
  public var hasStart: Bool
  public var start: Date
  public var hasEnd: Bool
  public var end: Date
  /// Empty = no budget.
  public var budget: String
  public var budgetCurrency: Currency
  /// `#RRGGBB` (R-EVT-1, R-MGMT-7).
  public var colorHex: String? = nil
}

/// The Events screen (approved prototype group 4, R-MGMT-4, R-EVT-1…4): the list with dates and
/// spent against the budget, an inspector to create and edit (dates, optional budget), what the
/// event cost by category, "Show N transactions", archive / unarchive and delete.
///
/// Amounts are in the event's budget currency when it has a budget (so spent and budget compare),
/// otherwise in the display currency; each amount converts at its day's rate (R-FX-3).
@MainActor
@Observable
public final class EventsModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var events: [Event] = []
  public private(set) var totals: [Event.ID: EventTotals] = [:]
  public var showArchived = false
  /// The page search above the list (R-MGMT-11): filters the rows by name.
  public var search = ""
  public private(set) var selection: Event.ID?
  public var draft: EventDraft?
  public private(set) var dialog: ManageDialog?
  public private(set) var errorMessage: String?
  public private(set) var displayCurrency: Currency

  @ObservationIgnored public let dependencies: ManageDependencies
  /// Called after this screen changed data other screens show (names, colours: R-MGMT-7),
  /// so the transaction list and the dashboard re-read it.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?
  @ObservationIgnored private var loaded: Loaded?

  struct Loaded {
    var accounts: [Account]
    var categories: [AbacusDomain.Category]
    var txns: [TxnWithLines]
    var converter: any CurrencyConverter
    var refundsReduceSpending: Bool
  }

  private var format: ManageFormat { dependencies.format }

  public init(dependencies: ManageDependencies, displayCurrency: Currency = .UAH) {
    self.dependencies = dependencies
    self.displayCurrency = displayCurrency
  }

  // MARK: Loading

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      events = try await dependencies.events.events(includeArchived: true)
      loaded = Loaded(
        accounts: try await dependencies.accounts.accounts(includeArchived: true),
        categories: try await dependencies.categories.categories(kind: nil, includeArchived: true),
        txns: try await dependencies.allTransactions(), converter: await dependencies.converter(),
        refundsReduceSpending: await dependencies.refundsReduceSpending())
      recompute()
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load events: \(error.localizedDescription)")
      return
    }
    if let selection, let event = event(selection) {
      if draft?.id != selection { draft = makeDraft(event) }
    } else if draft?.isNew != true {
      select(visibleEvents.first?.id)
    }
  }

  /// Re-reads the rates (after a refresh) and recomputes the totals.
  public func refreshRates() async {
    loaded?.converter = await dependencies.converter()
    recompute()
  }

  public func setDisplayCurrency(_ currency: Currency) {
    guard currency != displayCurrency else { return }
    displayCurrency = currency
    recompute()
  }

  private func recompute() {
    guard let loaded else { return }
    var totals: [Event.ID: EventTotals] = [:]
    for event in events {
      totals[event.id] = Calc.eventTotals(
        event: event, accounts: loaded.accounts, categories: loaded.categories, txns: loaded.txns,
        currency: currency(of: event), converter: loaded.converter,
        refundsReduceSpending: loaded.refundsReduceSpending, calendar: format.calendar)
    }
    self.totals = totals
  }

  /// The budget's currency, or the display currency without a budget.
  public func currency(of event: Event) -> Currency {
    event.budgetMinor != nil ? (event.budgetCurrency ?? displayCurrency) : displayCurrency
  }

  // MARK: List

  public func event(_ id: Event.ID) -> Event? { events.first { $0.id == id } }

  private var visibleEvents: [Event] { events.filter { showArchived || !$0.isArchived } }

  /// Whether the event's name matches the page search (case- and diacritic-insensitive).
  public func matchesSearch(_ event: Event) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    return event.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  /// The list: visible events whose name matches the search.
  public var rows: [EventRow] {
    visibleEvents.filter(matchesSearch).map { event in
      let totals = totals[event.id]
      return EventRow(
        id: event.id, name: event.name, dates: dates(event), spentText: totals.map { format.money($0.spent) } ?? "—",
        budgetText: event.budgetMinor.map { "of \(format.money(Money(minorUnits: $0, currency: currency(of: event)))) budget" }
          ?? "no budget",
        status: totals?.budgetStatus, isArchived: event.isArchived, colorHex: event.colorHex)
    }
  }

  public func dates(_ event: Event) -> String {
    format.dateRange(start: event.startDay.flatMap(Day.init), end: event.endDay.flatMap(Day.init))
  }

  public func select(_ id: Event.ID?) {
    selection = id
    errorMessage = nil
    draft = id.flatMap(event).map(makeDraft)
  }

  public func setShowArchived(_ show: Bool) {
    showArchived = show
    if let selection, let event = event(selection), event.isArchived, !show { select(visibleEvents.first?.id) }
  }

  // MARK: Inspector

  private func makeDraft(_ event: Event) -> EventDraft {
    let today = dependencies.today().date(calendar: format.calendar)
    let start = event.startDay.flatMap(Day.init)?.date(calendar: format.calendar)
    let end = event.endDay.flatMap(Day.init)?.date(calendar: format.calendar)
    return EventDraft(
      id: event.id, isNew: false, name: event.name, hasStart: start != nil, start: start ?? end ?? today,
      hasEnd: end != nil, end: end ?? start ?? today, budget: event.budgetMinor.map(format.amountInput) ?? "",
      budgetCurrency: event.budgetCurrency ?? displayCurrency, colorHex: event.colorHex)
  }

  /// "New event": a name, no dates, no budget.
  public func newEvent() {
    let today = dependencies.today().date(calendar: format.calendar)
    selection = nil
    errorMessage = nil
    draft = EventDraft(
      id: UUID(), isNew: true, name: "", hasStart: false, start: today, hasEnd: false, end: today, budget: "",
      budgetCurrency: displayCurrency, colorHex: ColorPalette.pick(avoiding: events.map(\.colorHex)))
  }

  public var selectedEvent: Event? { selection.flatMap(event) }

  /// An archived event's name, dates, budget and currency are read-only until it is
  /// unarchived; only its colour can still change.
  public var isReadOnly: Bool {
    guard let draft, !draft.isNew else { return false }
    return event(draft.id)?.isArchived == true
  }

  public var inspectorTitle: String {
    guard let draft else { return "" }
    if draft.isNew { return draft.name.isEmpty ? "New event" : draft.name }
    return selectedEvent?.name ?? draft.name
  }

  public var validationMessage: String? {
    guard let draft else { return nil }
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
    if draft.hasStart, draft.hasEnd,
      Day(draft.end, calendar: format.calendar) < Day(draft.start, calendar: format.calendar)
    {
      return "The event ends before it starts."
    }
    let budget = draft.budget.trimmingCharacters(in: .whitespaces)
    if !budget.isEmpty, (format.parseAmount(budget) ?? -1) < 0 { return "The budget is not a valid amount." }
    return nil
  }

  private func built(from draft: EventDraft, base: Event?) -> Event? {
    let budgetText = draft.budget.trimmingCharacters(in: .whitespaces)
    let budget = budgetText.isEmpty ? nil : format.parseAmount(budgetText)
    if !budgetText.isEmpty, budget == nil { return nil }
    var event = base ?? Event(id: draft.id, name: "")
    if let base, base.isArchived {
      // Read-only while archived: only the colour changes.
      event.colorHex = draft.colorHex
      return event
    }
    event.name = draft.name.trimmingCharacters(in: .whitespaces)
    event.startDay = draft.hasStart ? Day(draft.start, calendar: format.calendar).string : nil
    event.endDay = draft.hasEnd ? Day(draft.end, calendar: format.calendar).string : nil
    event.budgetMinor = budget
    event.budgetCurrency = budget == nil ? nil : draft.budgetCurrency
    event.colorHex = draft.colorHex
    return event
  }

  public var isDirty: Bool {
    guard let draft else { return false }
    if draft.isNew { return true }
    guard let event = event(draft.id) else { return false }
    return built(from: draft, base: event) != event
  }

  public var canSave: Bool { isDirty && validationMessage == nil }

  public func save() async {
    guard let draft, canSave, let event = built(from: draft, base: draft.isNew ? nil : event(draft.id)) else { return }
    do {
      try await dependencies.events.save(event)
      await onDataChange?()
      selection = event.id
      self.draft = nil
      await load()
      select(event.id)
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the event")
    }
  }

  public func revert() {
    if draft?.isNew == true { select(visibleEvents.first?.id) } else { select(selection) }
  }

  // MARK: Spending (R-EVT-3)

  public var selectedTotals: EventTotals? { selection.flatMap { totals[$0] } }

  /// "€23.60" or "€23.60 of €300.00".
  public var spentText: String {
    guard let event = selectedEvent, let totals = selectedTotals else { return "—" }
    let spent = format.money(totals.spent)
    guard let budget = event.budgetMinor else { return spent }
    return "\(spent) of \(format.money(Money(minorUnits: budget, currency: currency(of: event))))"
  }

  public var categoryBars: [EventCategoryBar] {
    guard let totals = selectedTotals, let loaded else { return [] }
    let tree = CategoryTree(loaded.categories)
    let largest = totals.byCategory.map { $0.total.minorUnits }.max() ?? 0
    return totals.byCategory.map { item in
      let name: String
      let color: String?
      switch item.key {
      case .category(let id):
        name = tree.category(id)?.name ?? "Unknown category"
        color = tree.category(id)?.colorHex
      case .uncategorized:
        name = "Uncategorized"
        color = nil
      case .refunds:
        name = "Refunds"
        color = nil
      }
      return EventCategoryBar(
        id: item.key, name: name, colorHex: color, amountText: format.money(item.total),
        fraction: largest > 0 ? max(0, Double(item.total.minorUnits) / Double(largest)) : 0)
    }
  }

  /// "Show 14 transactions" (opens Transactions filtered by the event).
  public var showTransactionsTitle: String {
    "Show \(ManageText.transactions(selectedTotals?.txnCount ?? 0))"
  }

  /// The Transactions query of "Show N transactions" (R-EVT-3).
  public var transactionsQuery: TxnQuery? {
    selection.map { TxnQuery(eventIDs: [$0]) }
  }

  /// Amounts left out for want of a rate (D27), or nil.
  public var missingRatesNote: String? {
    guard let totals = selectedTotals, !totals.unconverted.isEmpty else { return nil }
    return "\(totals.unconverted.count) amount\(totals.unconverted.count == 1 ? " has" : "s have") no exchange rate yet and \(totals.unconverted.count == 1 ? "is" : "are") left out."
  }

  // MARK: Archive and delete

  public var archiveTitle: String { selectedEvent?.isArchived == true ? "Unarchive" : "Archive" }

  public func archiveOrUnarchive() async {
    guard let event = selectedEvent else { return }
    do {
      try await dependencies.events.setArchived(event.id, !event.isArchived)
      await onDataChange?()
      if !event.isArchived { showArchived = true }
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: event.isArchived ? "unarchive the event" : "archive the event")
    }
  }

  public func requestDelete() {
    guard let event = selectedEvent else { return }
    let count = totals[event.id]?.txnCount ?? 0
    dialog = ManageDialog(
      action: .deleteEvent(event.id), title: "Delete “\(event.name)”?",
      message: count > 0
        ? "Its \(ManageText.transactions(count)) stay; they are no longer tagged with this event."
        : "No transactions are tagged with it.",
      confirmTitle: "Delete", isDestructive: true)
  }

  public func cancelDialog() { dialog = nil }

  public func confirmDialog() async {
    guard let dialog, case .deleteEvent(let id) = dialog.action else { return }
    self.dialog = nil
    do {
      try await dependencies.events.delete(id)
      await onDataChange?()
      selection = nil
      draft = nil
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "delete the event")
    }
  }
}
