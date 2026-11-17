import AbacusDomain
import Foundation
import Observation

/// The transaction a "Mark paid" starts with (R-REC-4): the scheduled item's template. The
/// editor opens it as a new transaction (`TransactionEditorMode.newFromTemplate`).
public struct TransactionTemplate: Hashable, Sendable {
  public var type: TxnType
  public var accountID: Account.ID
  public var toAccountID: Account.ID?
  public var amountMinor: Int64
  public var toAmountMinor: Int64?
  public var categoryID: AbacusDomain.Category.ID?
  public var eventID: Event.ID?
  public var payee: String
  public var note: String

  public init(
    type: TxnType, accountID: Account.ID, toAccountID: Account.ID? = nil, amountMinor: Int64,
    toAmountMinor: Int64? = nil, categoryID: AbacusDomain.Category.ID? = nil, eventID: Event.ID? = nil,
    payee: String = "", note: String = ""
  ) {
    self.type = type
    self.accountID = accountID
    self.toAccountID = toAccountID
    self.amountMinor = amountMinor
    self.toAmountMinor = toAmountMinor
    self.categoryID = categoryID
    self.eventID = eventID
    self.payee = payee
    self.note = note
  }
}

/// The form of a scheduled item (R-REC-1, R-REC-12).
public struct ScheduledItemDraft: Hashable, Sendable {
  /// The stored item when editing; nil for a new one.
  public var stored: ScheduledItem?
  public var type: TxnType = .expense
  public var accountID: Account.ID?
  public var toAccountID: Account.ID?
  public var amountText = ""
  /// Amount received (cross-currency transfer).
  public var toAmountText = ""
  public var categoryID: AbacusDomain.Category.ID?
  public var eventID: Event.ID?
  public var payee = ""
  public var note = ""
  public var interval = 1
  public var unit: ScheduleUnit = .month
  public var startDay: Day
  public var lastDayOfMonth = false
  public var endKind: ScheduleEndKind = .never
  public var endDay: Day
  public var endCount = 12
  public var tolerancePercent = 5

  public init(today: Day, format: ManageFormat = ManageFormat()) {
    startDay = today
    endDay = today.plusDays(365)
  }

  public init(item: ScheduledItem, format: ManageFormat = ManageFormat()) {
    let start = Day(item.startDay) ?? Day(Date())
    self.init(today: start, format: format)
    stored = item
    type = item.type
    accountID = item.accountID
    toAccountID = item.toAccountID
    amountText = format.amountInput(item.amountMinor)
    toAmountText = item.toAmountMinor.map(format.amountInput) ?? ""
    categoryID = item.categoryID
    eventID = item.eventID
    payee = item.payee
    note = item.note
    interval = item.interval
    unit = item.unit
    lastDayOfMonth = item.lastDayOfMonth
    endKind = item.endKind
    if let day = item.endDay.flatMap(Day.init) { endDay = day }
    if let count = item.endCount { endCount = count }
    tolerancePercent = item.tolerancePercent
  }

  /// From a subscription suggestion (R-REC-8 "Accept"): starts on the next expected day.
  public init(suggestion: SubscriptionSuggestion, format: ManageFormat = ManageFormat()) {
    self.init(today: suggestion.nextDay, format: format)
    type = suggestion.type
    accountID = suggestion.accountID
    amountText = format.amountInput(suggestion.amountMinor)
    categoryID = suggestion.categoryID
    payee = suggestion.description
    unit = suggestion.period.unit
    interval = suggestion.period.interval
  }

  public var isNew: Bool { stored == nil }

  /// The schedule the form describes (nil while the interval is invalid).
  public var schedule: Schedule? {
    guard interval >= 1 else { return nil }
    let end: Schedule.End =
      switch endKind {
      case .never: .never
      case .onDay: .onDay(endDay)
      case .afterCount: .afterCount(max(1, endCount))
      }
    return Schedule(unit: unit, interval: interval, startDay: startDay, lastDayOfMonth: lastDayOfMonth, end: end)
  }
}

/// Why Save is disabled.
public enum ScheduledItemIssue: Hashable, Sendable {
  case payee, amount, account, toAccount, sameAccounts, receivedAmount, interval, endDay, endCount, tolerance

  public var message: String {
    switch self {
    case .payee: "Enter a description."
    case .amount: "Enter an amount above zero."
    case .account: "Choose an account."
    case .toAccount: "Choose the account the money goes to."
    case .sameAccounts: "From and To must be different accounts."
    case .receivedAmount: "Enter the amount received."
    case .interval: "Repeat every 1 or more."
    case .endDay: "The end day must be on or after the start."
    case .endCount: "End after 1 or more times."
    case .tolerance: "Tolerance must be 0–100 %."
    }
  }
}

/// The scheduled item editor sheet (R-REC-12): fields per R-REC-1, repeat, "Last day of the
/// month", starts, ends, tolerance, the next five dates (`Schedule.next`), Pause / Delete…;
/// opened from a suggestion it shows the evidence rows.
@MainActor
@Observable
public final class ScheduledItemEditorModel: Identifiable {
  public let id = UUID()
  public var draft: ScheduledItemDraft
  /// "6 Jul · 29.99" rows when opened from a suggestion.
  public let evidence: [String]
  public let suggestion: SubscriptionSuggestion?
  public private(set) var accounts: [Account] = []
  public private(set) var categories: [AbacusDomain.Category] = []
  public private(set) var events: [Event] = []
  public private(set) var isWorking = false
  public var errorMessage: String?

  @ObservationIgnored private weak var upcoming: UpcomingModel?
  @ObservationIgnored private let dependencies: UpcomingDependencies
  public let today: Day

  init(
    draft: ScheduledItemDraft, evidence: [String] = [], suggestion: SubscriptionSuggestion? = nil,
    upcoming: UpcomingModel
  ) {
    self.draft = draft
    self.evidence = evidence
    self.suggestion = suggestion
    self.upcoming = upcoming
    dependencies = upcoming.dependencies
    today = upcoming.today
    accounts = upcoming.accounts
    categories = upcoming.categories
  }

  func loadReference() async {
    if let events = try? await dependencies.events.events(includeArchived: false) { self.events = events }
  }

  public var isNew: Bool { draft.isNew }
  public var title: String { isNew ? "New scheduled item" : "Edit scheduled item" }
  public var isPaused: Bool { draft.stored?.status == .paused }
  public var isPausedByArchive: Bool { draft.stored?.pausedBecause == .accountArchived }

  /// Accounts offered: active ones plus the item's own (an archived one keeps showing).
  public var accountChoices: [Account] {
    accounts.filter { !$0.isArchived || $0.id == draft.accountID || $0.id == draft.toAccountID }
  }

  /// Categories of the type's kind (none for a transfer), active ones plus the chosen one.
  public var categoryChoices: [AbacusDomain.Category] {
    guard draft.type != .transfer else { return [] }
    let kind: CategoryKind = draft.type == .income ? .income : .expense
    return categories.filter { $0.kind == kind && (!$0.isArchived || $0.id == draft.categoryID) }
  }

  public var account: Account? { accounts.first { $0.id == draft.accountID } }
  public var toAccount: Account? { accounts.first { $0.id == draft.toAccountID } }
  /// "PLN · currency of the account".
  public var currencyText: String { (account?.currency.rawValue ?? "—") + " · currency of the account" }
  /// A cross-currency transfer asks for the amount received.
  public var needsReceivedAmount: Bool {
    draft.type == .transfer && toAccount != nil && account != nil && toAccount?.currency != account?.currency
  }

  /// Changing the type drops a category of the other kind and the To side.
  /// "Sat, 5 Dec 2026": the Starts / Ends day fields, in the style of the next-date chips.
  public func fieldDayText(_ day: Day) -> String {
    let calendar = dependencies.calendar
    return day.date(calendar: calendar).formatted(
      Date.FormatStyle(locale: dependencies.format.locale, calendar: calendar, timeZone: calendar.timeZone)
        .weekday(.abbreviated).day().month(.abbreviated).year())
  }

  public func setType(_ type: TxnType) {
    guard type != draft.type else { return }
    draft.type = type
    if type == .transfer {
      draft.categoryID = nil
    } else {
      draft.toAccountID = nil
      draft.toAmountText = ""
      if let id = draft.categoryID, !categoryChoices.contains(where: { $0.id == id }) { draft.categoryID = nil }
    }
  }

  // MARK: Validation and preview

  public var issues: [ScheduledItemIssue] {
    var result: [ScheduledItemIssue] = []
    let format = dependencies.format
    if draft.payee.trimmingCharacters(in: .whitespaces).isEmpty { result.append(.payee) }
    if (format.parseAmount(draft.amountText) ?? 0) <= 0 { result.append(.amount) }
    if account == nil { result.append(.account) }
    if draft.type == .transfer {
      if toAccount == nil {
        result.append(.toAccount)
      } else if draft.toAccountID == draft.accountID {
        result.append(.sameAccounts)
      }
      if needsReceivedAmount, (format.parseAmount(draft.toAmountText) ?? 0) <= 0 { result.append(.receivedAmount) }
    }
    if draft.interval < 1 { result.append(.interval) }
    if draft.endKind == .onDay, draft.endDay < draft.startDay { result.append(.endDay) }
    if draft.endKind == .afterCount, draft.endCount < 1 { result.append(.endCount) }
    if !(0...100).contains(draft.tolerancePercent) { result.append(.tolerance) }
    return result
  }

  public var canSave: Bool { issues.isEmpty && !isWorking }

  /// The next five dates on or after today (R-REC-2 preview).
  public var nextDays: [Day] {
    draft.schedule?.next(5, onOrAfter: today) ?? []
  }

  public var nextDayTexts: [String] {
    nextDays.map { upcoming?.longDayText($0) ?? $0.string }
  }

  /// "Months without a 31st use their last day." (monthly, day > 28, not last-day mode).
  public var monthEndHint: String? {
    guard draft.unit == .month || draft.unit == .year, !draft.lastDayOfMonth, draft.startDay.day > 28 else { return nil }
    let day = draft.startDay.day
    let suffix = day == 31 ? "st" : "th"
    return "Months without a \(day)\(suffix) use their last day."
  }

  /// The item to store, nil while invalid.
  public var item: ScheduledItem? {
    guard issues.isEmpty, let accountID = draft.accountID else { return nil }
    let format = dependencies.format
    guard let amount = format.parseAmount(draft.amountText) else { return nil }
    let isTransfer = draft.type == .transfer
    let stored = draft.stored
    return ScheduledItem(
      id: stored?.id ?? UUID(), type: draft.type, accountID: accountID,
      toAccountID: isTransfer ? draft.toAccountID : nil, amountMinor: amount,
      toAmountMinor: isTransfer && needsReceivedAmount ? format.parseAmount(draft.toAmountText) : nil,
      categoryID: isTransfer ? nil : draft.categoryID, eventID: draft.eventID,
      payee: draft.payee.trimmingCharacters(in: .whitespaces), note: draft.note.trimmingCharacters(in: .whitespaces),
      unit: draft.unit, interval: draft.interval, startDay: draft.startDay.string,
      lastDayOfMonth: draft.unit == .month && draft.lastDayOfMonth, endKind: draft.endKind,
      endDay: draft.endKind == .onDay ? draft.endDay.string : nil,
      endCount: draft.endKind == .afterCount ? draft.endCount : nil, mode: .remind,
      tolerancePercent: draft.tolerancePercent, status: stored?.status == .ended ? .active : (stored?.status ?? .active),
      pausedBecause: stored?.pausedBecause, createdAt: stored?.createdAt ?? Date())
  }

  // MARK: Actions

  /// Saves; returns true when stored (the sheet closes).
  @discardableResult
  public func save() async -> Bool {
    guard let item else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      try await dependencies.scheduled.save(item)
    } catch {
      errorMessage = UpcomingModel.message(error)
      return false
    }
    let notice =
      isNew
      ? "Scheduled item added. It appears in Upcoming from \(upcoming?.dayText(draft.startDay) ?? draft.startDay.string)."
      : "Saved. Changes apply to future occurrences only."
    await upcoming?.editorFinished(notice: notice)
    return true
  }

  /// Pause / Resume (an existing item). Edits in the form are saved first.
  public func togglePause() async {
    guard let stored = draft.stored else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      if let item, item != stored { try await dependencies.scheduled.save(item) }
      try await dependencies.scheduled.setPaused(stored.id, !isPaused, today: today)
    } catch {
      errorMessage = UpcomingModel.message(error)
      return
    }
    await upcoming?.editorFinished(notice: isPaused ? "Resumed \(stored.payee)." : "Paused \(stored.payee).")
  }

  /// "Delete…" after the sheet's confirmation; matched transactions stay (R-REC-1).
  public func delete() async {
    guard let stored = draft.stored else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      try await dependencies.scheduled.delete(stored.id)
    } catch {
      errorMessage = UpcomingModel.message(error)
      return
    }
    await upcoming?.editorFinished(notice: "Deleted \(stored.payee). Its transactions are not touched.")
  }

  public func cancel() {
    upcoming?.editor = nil
  }
}
