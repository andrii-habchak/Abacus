import AbacusDomain
import Foundation
import Observation

/// One category limit in the budget editor (R-BUD-1, D43): an amount in its own currency. The
/// amount stays text until saved.
public struct BudgetLimitDraft: Identifiable, Equatable, Sendable {
  public let categoryID: AbacusDomain.Category.ID
  public var limit: String
  public var currency: Currency
  public var id: AbacusDomain.Category.ID { categoryID }
}

/// A presented limit row: name, colour, "incl. Groceries, Eating out" for a parent, share bar.
public struct BudgetLimitRow: Identifiable, Equatable, Sendable {
  public let categoryID: AbacusDomain.Category.ID
  public let name: String
  public let colorHex: String?
  /// "incl. Taxi, Fuel"; empty for a category without children.
  public let covers: String
  public let currency: Currency
  /// The limit's share of the total (the sum of the limits without one) in the display
  /// currency, 0…1 (0 without a rate or when the total is not positive).
  public let share: Double
  public let isValid: Bool
  public var id: AbacusDomain.Category.ID { categoryID }
}

/// The Save button's state (D56): blue and disabled with nothing to save, blue and enabled
/// after an edit, green, disabled and "Saved" after a successful save until the next edit.
public enum BudgetSaveState: Equatable, Sendable {
  /// Nothing edited since the page was loaded (or reverted).
  case unchanged
  /// Unsaved edits: Save and Revert are enabled.
  case edited
  /// Just saved; stays until the next edit.
  case saved
}

/// The Budget screen (approved prototype group 4 as changed by TA v1.6, R-MGMT-3, R-BUD-1…3,
/// D43, D46): a total limit in its own currency (optional: empty or 0 = the sum of the limits),
/// per-category limits each in its own currency, share bars and the unallocated remainder
/// (total − limits at the latest rate). Totals, unallocated and shares are shown in the display
/// currency (the toolbar switch); inputs stay in their own currencies. "Applies from <month>":
/// saving writes a plan effective from that month on; earlier months keep theirs (D29).
@MainActor
@Observable
public final class BudgetEditorModel {
  public private(set) var phase: ManagePhase = .idle
  /// The first month the saved budget applies to.
  public var appliesFrom: Month
  public private(set) var limits: [BudgetLimitDraft] = []
  /// Expense categories (archived too, to name old limits).
  public private(set) var categories: [AbacusDomain.Category] = []
  /// The category picked in "Add category limit".
  public var categoryToAdd: AbacusDomain.Category.ID?
  public private(set) var errorMessage: String?
  /// "Saved. It applies from November 2026." after a save.
  public private(set) var savedMessage: String?
  /// The month a later plan starts (it is kept, so the saved budget stops there).
  public private(set) var laterPlanMonth: Month?
  /// The total limit as typed; empty (or 0) = no total, the sum of the limits is the total.
  public var totalLimit: String = "" {
    didSet { if totalLimit != oldValue { edited() } }
  }
  /// The total limit's currency.
  public var totalCurrency: Currency = .UAH {
    didSet { if totalCurrency != oldValue { edited() } }
  }
  /// Set by a successful save, cleared by the next edit (`saveState`).
  public private(set) var justSaved = false
  /// The currency the page's sums are shown in (the toolbar switch, R-HOME-4); read from the
  /// settings on the first load, then set by the app (`setDisplayCurrency`).
  public private(set) var displayCurrency: Currency = .UAH
  /// The currency a new limit starts in: the last one picked or loaded, else the display
  /// currency.
  public private(set) var lastUsedCurrency: Currency?

  @ObservationIgnored public let dependencies: ManageDependencies
  /// What was loaded or last saved, to tell whether there is something to save. Observed:
  /// `isDirty` and `saveState` read it, and a save changes only it (and `justSaved`, which a view
  /// showing "edited" never read), so the Save button would otherwise stay blue (D56).
  private var baseline: Snapshot?
  /// The plan loaded for editing (its id is reused when saving for the same month).
  @ObservationIgnored private var loadedPlan: BudgetPlan?
  /// The rates in memory when the screen loaded (the total uses the latest rate).
  private var converter: (any CurrencyConverter)?

  /// Set once the app has pushed its display currency, so a reload does not reset it.
  @ObservationIgnored private var displayCurrencyIsSet = false

  struct Snapshot: Equatable {
    var appliesFrom: Month
    var totalLimit: String
    var totalCurrency: Currency
    var limits: [BudgetLimitDraft]
  }

  private var format: ManageFormat { dependencies.format }

  public init(dependencies: ManageDependencies) {
    self.dependencies = dependencies
    appliesFrom = dependencies.today().yearMonth
  }

  // MARK: Loading

  /// Loads the budget in effect this month into the form, applying from this month.
  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      categories = try await dependencies.categories.categories(kind: .expense, includeArchived: true)
      let month = dependencies.today().yearMonth
      let found = try await dependencies.budget.plan(for: month)
      if !displayCurrencyIsSet {
        let display = try? await dependencies.settings.value(.displayCurrency)
        displayCurrency = display.flatMap(Currency.init(rawValue:)) ?? .UAH
      }
      converter = await dependencies.converter()
      // Loading is not an edit: the field observers must not end the "Saved" state.
      let wasJustSaved = justSaved
      let previousSavedMessage = savedMessage
      loadedPlan = found?.plan
      appliesFrom = month
      if let total = found?.plan.total {
        totalLimit = format.amountInput(total.minorUnits)
        totalCurrency = total.currency
      } else {
        totalLimit = ""
        totalCurrency = found?.plan.currency ?? displayCurrency
      }
      let order = Dictionary(uniqueKeysWithValues: orderedCategories.enumerated().map { ($1.id, $0) })
      limits = (found?.allocations ?? [])
        .sorted { (order[$0.categoryID] ?? .max, $0.limitMinor) < (order[$1.categoryID] ?? .max, $1.limitMinor) }
        .map { BudgetLimitDraft(categoryID: $0.categoryID, limit: format.amountInput($0.limitMinor), currency: $0.currency) }
      lastUsedCurrency = limits.last?.currency
      // A reload right after saving (the data-changed signal, the page shown again) keeps
      // "Saved" while it shows exactly the saved values.
      let keepsSaved = wasJustSaved && baseline.map(normalized) == normalized(snapshot)
      baseline = snapshot
      justSaved = keepsSaved
      savedMessage = keepsSaved ? previousSavedMessage : nil
      errorMessage = nil
      categoryToAdd = addOptions.first?.id
      await refreshLaterPlan()
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load the budget: \(error.localizedDescription)")
    }
  }

  /// Re-reads the rates (after a refresh or loading the cache) for the total; edits are kept.
  public func refreshRates() async {
    converter = await dependencies.converter()
  }

  /// The screen is shown again, or data changed elsewhere: re-reads the budget unless there
  /// are unsaved edits, which are kept (only the rates are re-read then).
  public func reappeared() async {
    if phase == .loaded, isDirty {
      await refreshRates()
    } else {
      await load()
    }
  }

  /// The toolbar's display currency switch (R-HOME-4, D46): totals, unallocated and shares
  /// follow it; the inputs keep their own currencies.
  public func setDisplayCurrency(_ currency: Currency) {
    displayCurrencyIsSet = true
    displayCurrency = currency
  }

  /// "Revert": back to what was loaded or last saved.
  public func revert() async {
    guard let baseline else { return }
    appliesFrom = baseline.appliesFrom
    totalLimit = baseline.totalLimit
    totalCurrency = baseline.totalCurrency
    limits = baseline.limits
    categoryToAdd = addOptions.first?.id
    errorMessage = nil
    savedMessage = nil
    justSaved = false
    await refreshLaterPlan()
  }

  private var snapshot: Snapshot {
    Snapshot(appliesFrom: appliesFrom, totalLimit: totalLimit, totalCurrency: totalCurrency, limits: limits)
  }

  /// The values a snapshot stands for: amounts as stored ("4100" = "4100.00"), limits in a fixed
  /// order (a reload sorts them by category).
  private func normalized(_ snapshot: Snapshot) -> Snapshot {
    func amount(_ text: String) -> String { format.parseAmount(text).map(format.amountInput) ?? text }
    var copy = snapshot
    copy.totalLimit = snapshot.totalLimit.trimmingCharacters(in: .whitespaces).isEmpty ? "" : amount(snapshot.totalLimit)
    if (format.parseAmount(copy.totalLimit) ?? -1) == 0 { copy.totalLimit = "" }
    copy.limits = snapshot.limits
      .map { BudgetLimitDraft(categoryID: $0.categoryID, limit: amount($0.limit), currency: $0.currency) }
      .sorted { $0.categoryID.uuidString < $1.categoryID.uuidString }
    return copy
  }

  /// Finds a plan that starts after `appliesFrom` (the saved one runs until then).
  private func refreshLaterPlan() async {
    let farFuture = Month(year: 9999, month: 12)
    let latest = try? await dependencies.budget.plan(for: farFuture)
    if let start = latest.flatMap({ Month($0.plan.effectiveMonth) }), start > appliesFrom {
      laterPlanMonth = start
    } else {
      laterPlanMonth = nil
    }
  }

  // MARK: Applies from (R-BUD-3)

  /// This month and the next eleven: past months keep their limits.
  public var monthOptions: [Month] {
    let first = dependencies.today().yearMonth
    return (0..<12).map { first.adding(months: $0) }
  }

  public func setAppliesFrom(_ month: Month) async {
    if month != appliesFrom { edited() }
    appliesFrom = month
    await refreshLaterPlan()
  }

  public func monthTitle(_ month: Month) -> String { format.month(month) }

  /// "Earlier months keep the budget they had. It repeats every month until you change it."
  public var appliesNote: String {
    var note = "Earlier months keep the budget they had. It repeats every month until you change it."
    if let later = laterPlanMonth {
      note += " From \(format.month(later)) the budget saved for that month applies."
    }
    return note
  }

  // MARK: Limits

  private var tree: CategoryTree { CategoryTree(categories) }

  private var orderedCategories: [AbacusDomain.Category] {
    let byOrder: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = { ($0.position, $0.name) < ($1.position, $1.name) }
    let ids = Set(categories.map(\.id))
    let parents = categories.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: byOrder)
    return parents.flatMap { parent in [parent] + categories.filter { $0.parentID == parent.id }.sorted(by: byOrder) }
  }

  public var rows: [BudgetLimitRow] {
    let total = totalMinor ?? 0
    return limits.map { limit in
      let category = tree.category(limit.categoryID)
      let children = tree.children(of: limit.categoryID).filter { !$0.isArchived }
      let minor = format.parseAmount(limit.limit)
      let shown = minor.flatMap { inDisplayCurrency(Money(minorUnits: $0, currency: limit.currency)) }
      let share = total > 0 ? min(1, max(0, Double(shown?.minorUnits ?? 0) / Double(total))) : 0
      return BudgetLimitRow(
        categoryID: limit.categoryID, name: category?.name ?? "Unknown category", colorHex: category?.colorHex,
        covers: children.isEmpty ? "" : "incl. " + children.map(\.name).joined(separator: ", "),
        currency: limit.currency, share: share, isValid: minor.map { $0 >= 0 } ?? false)
    }
  }

  public func setLimit(_ text: String, for categoryID: AbacusDomain.Category.ID) {
    guard let index = limits.firstIndex(where: { $0.categoryID == categoryID }) else { return }
    guard limits[index].limit != text else { return }
    limits[index].limit = text
    edited()
  }

  public func limitText(_ categoryID: AbacusDomain.Category.ID) -> String {
    limits.first { $0.categoryID == categoryID }?.limit ?? ""
  }

  /// A limit's currency (R-MGMT-3); it becomes the default for the next limit added.
  public func setCurrency(_ currency: Currency, for categoryID: AbacusDomain.Category.ID) {
    guard let index = limits.firstIndex(where: { $0.categoryID == categoryID }) else { return }
    lastUsedCurrency = currency
    guard limits[index].currency != currency else { return }
    limits[index].currency = currency
    edited()
  }

  public func currency(_ categoryID: AbacusDomain.Category.ID) -> Currency {
    limits.first { $0.categoryID == categoryID }?.currency ?? newLimitCurrency
  }

  /// The currency of a limit added now: the last one used, else the display currency.
  public var newLimitCurrency: Currency { lastUsedCurrency ?? displayCurrency }

  /// Expense categories without a limit yet, A–Z (R-MGMT-8); a subcategory is named
  /// "Parent › Child" (`addOptionTitle`).
  public var addOptions: [AbacusDomain.Category] {
    let used = Set(limits.map(\.categoryID))
    return categories.filter { !$0.isArchived && !used.contains($0.id) }
      .sorted { addOptionTitle($0).localizedStandardCompare(addOptionTitle($1)) == .orderedAscending }
  }

  /// "Groceries", or "Transport › Taxi" for a subcategory.
  public func addOptionTitle(_ category: AbacusDomain.Category) -> String {
    guard let parent = category.parentID.flatMap({ tree.category($0) }) else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  /// "Add category limit": adds the picked category with a limit of 0 in the last used currency.
  public func addLimit() {
    guard let id = categoryToAdd ?? addOptions.first?.id, !limits.contains(where: { $0.categoryID == id }) else { return }
    limits.append(BudgetLimitDraft(categoryID: id, limit: format.amountInput(0), currency: newLimitCurrency))
    categoryToAdd = addOptions.first?.id
    edited()
  }

  public func removeLimit(_ categoryID: AbacusDomain.Category.ID) {
    guard limits.contains(where: { $0.categoryID == categoryID }) else { return }
    limits.removeAll { $0.categoryID == categoryID }
    if categoryToAdd == nil { categoryToAdd = addOptions.first?.id }
    edited()
  }

  // MARK: Total and unallocated (R-BUD-1, D43, D46)

  private func converted(_ money: Money, to currency: Currency) -> Money? {
    if money.currency == currency { return money }
    return converter?.convertAtLatest(money, to: currency)
  }

  private func inDisplayCurrency(_ money: Money) -> Money? { converted(money, to: displayCurrency) }

  /// The total limit typed; nil when the field is empty, 0 (no total) or not an amount.
  public var total: Money? {
    guard let minor = format.parseAmount(totalLimit), minor > 0 else { return nil }
    return Money(minorUnits: minor, currency: totalCurrency)
  }

  /// Whether a total is set (a positive amount in the total field): the unallocated row shows.
  public var hasTotal: Bool { total != nil }

  private var totalFieldIsValid: Bool {
    if totalLimit.trimmingCharacters(in: .whitespaces).isEmpty { return true }
    return (format.parseAmount(totalLimit) ?? -1) >= 0
  }

  /// Currencies (of the limits and the total) without a rate to the display currency or to the
  /// total's; those amounts are left out of the sums and named, never counted at 1.
  public var currenciesWithoutRate: [Currency] {
    let targets = [displayCurrency] + (total.map { [$0.currency] } ?? [])
    var seen: Set<Currency> = []
    return (limits.map(\.currency) + (total.map { [$0.currency] } ?? [])).filter { currency in
      guard seen.insert(currency).inserted else { return false }
      let probe = Money(minorUnits: 100, currency: currency)
      return targets.contains { converted(probe, to: $0) == nil }
    }
  }

  /// The sum of the limits in the display currency at the latest rate; nil while an amount does
  /// not parse. Limits without a rate are left out.
  public var limitsSumMinor: Int64? {
    var sum: Int64 = 0
    for limit in limits {
      guard let minor = format.parseAmount(limit.limit) else { return nil }
      if let shown = inDisplayCurrency(Money(minorUnits: minor, currency: limit.currency)) {
        sum += shown.minorUnits
      }
    }
    return sum
  }

  /// The budget's total in the display currency (what the share bars divide): the total limit
  /// at the latest rate, or the sum of the limits without one. nil while an amount does not
  /// parse or the total has no rate.
  public var totalMinor: Int64? {
    guard totalFieldIsValid, limitsSumMinor != nil else { return nil }
    if let total { return inDisplayCurrency(total)?.minorUnits }
    return limitsSumMinor
  }

  /// "₴101,700.00"; "—" while an amount does not parse.
  public var totalText: String {
    totalMinor.map { format.money(Money(minorUnits: $0, currency: displayCurrency)) } ?? "—"
  }

  /// "Total limit €3,000.00 at the latest rate" / "No total set: the sum of the limits" / "No
  /// EUR rate: those amounts are not counted".
  public var totalNote: String {
    guard totalFieldIsValid, limitsSumMinor != nil else { return "Check the amounts." }
    let missing = currenciesWithoutRate
    if !missing.isEmpty {
      let codes = missing.map(\.rawValue).joined(separator: ", ")
      return "No \(codes)→\(displayCurrency.rawValue) rate: those amounts are not counted"
    }
    if let total {
      return total.currency == displayCurrency
        ? "The total limit" : "Total limit \(format.money(total)) at the latest rate"
    }
    return limits.allSatisfy { $0.currency == displayCurrency }
      ? "No total set: the sum of the limits"
      : "No total set: the sum of the limits at the latest rate"
  }

  /// Unallocated = total − the limits converted to the total's currency at the latest rate
  /// (R-BUD-1, D46), in the total's currency. nil without a total or while an amount does not
  /// parse; limits without a rate are left out.
  public var unallocated: Money? {
    guard let total else { return nil }
    var allocated: Int64 = 0
    for limit in limits {
      guard let minor = format.parseAmount(limit.limit) else { return nil }
      if let inTotal = converted(Money(minorUnits: minor, currency: limit.currency), to: total.currency) {
        allocated += inTotal.minorUnits
      }
    }
    return Money(minorUnits: total.minorUnits - allocated, currency: total.currency)
  }

  /// The unallocated remainder in the display currency.
  public var unallocatedShown: Money? { unallocated.flatMap(inDisplayCurrency) }

  /// "₴12,400.00" (negative when the limits exceed the total); "—" without a rate.
  public var unallocatedText: String { unallocatedShown.map(format.money) ?? "—" }

  /// The unallocated share of the total, 0…1.
  public var unallocatedShare: Double {
    guard let shown = unallocatedShown, let base = totalMinor, base > 0 else { return 0 }
    return min(1, max(0, Double(shown.minorUnits) / Double(base)))
  }

  /// "Other categories and uncategorised spending" / "The limits exceed the total by €40.00".
  public var unallocatedNote: String {
    guard let unallocated else { return "" }
    if unallocated.minorUnits < 0 {
      return "The limits exceed the total by \(format.money(unallocated.negated))"
    }
    return "Other categories and uncategorised spending"
  }

  // MARK: Saving

  public var validationMessage: String? {
    if !totalFieldIsValid {
      return "The total limit is not a valid amount."
    }
    if limits.contains(where: { (format.parseAmount($0.limit) ?? -1) < 0 }) {
      return "A category limit is not a valid amount."
    }
    return nil
  }

  public var isDirty: Bool { snapshot != baseline }

  public var canSave: Bool { validationMessage == nil && isDirty }

  /// The Save button (D56): "Saved" (green, disabled) right after a save until the next edit;
  /// otherwise blue, enabled while there are unsaved edits. A failed save stays `.edited`.
  public var saveState: BudgetSaveState {
    if isDirty { return .edited }
    return justSaved ? .saved : .unchanged
  }

  /// Any edit: the "Saved" state and message end.
  private func edited() {
    justSaved = false
    savedMessage = nil
  }

  /// "Save": a plan effective from `appliesFrom` (R-BUD-3) with the total (0 = none) and each
  /// limit in its own currency. A plan already starting that month is replaced; earlier and
  /// later plans stay (D29).
  public func save() async {
    guard canSave else { return }  // valid and edited (D56: no save without an edit)
    let month = appliesFrom.string
    let planID: UUID = loadedPlan.flatMap { $0.effectiveMonth == month ? $0.id : nil } ?? UUID()
    let plan = BudgetPlan(
      id: planID, effectiveMonth: month, totalMinor: total?.minorUnits ?? 0, currency: totalCurrency)
    let allocations = limits.compactMap { limit in
      format.parseAmount(limit.limit).map {
        BudgetAllocation(planID: planID, categoryID: limit.categoryID, limitMinor: $0, currency: limit.currency)
      }
    }
    do {
      try await dependencies.budget.save(plan, allocations: allocations)
      loadedPlan = plan
      baseline = snapshot
      errorMessage = nil
      justSaved = true
      savedMessage = "Saved. It applies from \(format.month(appliesFrom))."
      await refreshLaterPlan()
    } catch {
      justSaved = false
      errorMessage = ManageFailure.message(error, doing: "save the budget")
    }
  }
}
