import AbacusDomain
import Foundation
import Observation

/// One category limit in the budget editor (R-BUD-1). The limit stays text until saved.
public struct BudgetLimitDraft: Identifiable, Equatable, Sendable {
  public let categoryID: AbacusDomain.Category.ID
  public var limit: String
  public var id: AbacusDomain.Category.ID { categoryID }
}

/// A presented limit row: name, colour, "incl. Groceries, Eating out" for a parent, share bar.
public struct BudgetLimitRow: Identifiable, Equatable, Sendable {
  public let categoryID: AbacusDomain.Category.ID
  public let name: String
  public let colorHex: String?
  /// "incl. Taxi, Fuel"; empty for a category without children.
  public let covers: String
  /// The limit's share of the total, 0…1 (0 when the total is not positive).
  public let share: Double
  public let isValid: Bool
  public var id: AbacusDomain.Category.ID { categoryID }
}

/// The Budget screen (approved prototype group 4, R-MGMT-3, R-BUD-1…3): a total monthly limit in
/// a chosen currency, per-category limits with share bars, the unallocated remainder (red when
/// the limits exceed the total), and "Applies from <month>": saving writes a plan effective from
/// that month on; earlier months keep theirs (D29).
@MainActor
@Observable
public final class BudgetEditorModel {
  public private(set) var phase: ManagePhase = .idle
  public var total: String = ""
  public var currency: Currency = .PLN
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

  @ObservationIgnored public let dependencies: ManageDependencies
  /// What was loaded or last saved, to tell whether there is something to save.
  @ObservationIgnored private var baseline: Snapshot?
  /// The plan loaded for editing (its id is reused when saving for the same month).
  @ObservationIgnored private var loadedPlan: BudgetPlan?

  struct Snapshot: Equatable {
    var total: String
    var currency: Currency
    var appliesFrom: Month
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
      loadedPlan = found?.plan
      appliesFrom = month
      currency = found?.plan.currency ?? .PLN
      total = format.amountInput(found?.plan.totalMinor ?? 0)
      let order = Dictionary(uniqueKeysWithValues: orderedCategories.enumerated().map { ($1.id, $0) })
      limits = (found?.allocations ?? [])
        .sorted { (order[$0.categoryID] ?? .max, $0.limitMinor) < (order[$1.categoryID] ?? .max, $1.limitMinor) }
        .map { BudgetLimitDraft(categoryID: $0.categoryID, limit: format.amountInput($0.limitMinor)) }
      baseline = snapshot
      savedMessage = nil
      errorMessage = nil
      categoryToAdd = addOptions.first?.id
      await refreshLaterPlan()
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load the budget: \(error.localizedDescription)")
    }
  }

  private var snapshot: Snapshot {
    Snapshot(total: total, currency: currency, appliesFrom: appliesFrom, limits: limits)
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
    appliesFrom = month
    savedMessage = nil
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

  public var totalMinor: Int64? { format.parseAmount(total) }

  public var rows: [BudgetLimitRow] {
    let total = totalMinor ?? 0
    return limits.map { limit in
      let category = tree.category(limit.categoryID)
      let children = tree.children(of: limit.categoryID).filter { !$0.isArchived }
      let minor = format.parseAmount(limit.limit)
      let share = total > 0 ? min(1, max(0, Double(minor ?? 0) / Double(total))) : 0
      return BudgetLimitRow(
        categoryID: limit.categoryID, name: category?.name ?? "Unknown category", colorHex: category?.colorHex,
        covers: children.isEmpty ? "" : "incl. " + children.map(\.name).joined(separator: ", "),
        share: share, isValid: minor.map { $0 >= 0 } ?? false)
    }
  }

  public func setLimit(_ text: String, for categoryID: AbacusDomain.Category.ID) {
    guard let index = limits.firstIndex(where: { $0.categoryID == categoryID }) else { return }
    limits[index].limit = text
    savedMessage = nil
  }

  public func limitText(_ categoryID: AbacusDomain.Category.ID) -> String {
    limits.first { $0.categoryID == categoryID }?.limit ?? ""
  }

  /// Expense categories without a limit yet, in tree order (children indented in the picker).
  public var addOptions: [AbacusDomain.Category] {
    let used = Set(limits.map(\.categoryID))
    return orderedCategories.filter { !$0.isArchived && !used.contains($0.id) }
  }

  /// "Add category limit": adds the picked category with a limit of 0.
  public func addLimit() {
    guard let id = categoryToAdd ?? addOptions.first?.id, !limits.contains(where: { $0.categoryID == id }) else { return }
    limits.append(BudgetLimitDraft(categoryID: id, limit: format.amountInput(0)))
    categoryToAdd = addOptions.first?.id
    savedMessage = nil
  }

  public func removeLimit(_ categoryID: AbacusDomain.Category.ID) {
    limits.removeAll { $0.categoryID == categoryID }
    if categoryToAdd == nil { categoryToAdd = addOptions.first?.id }
    savedMessage = nil
  }

  // MARK: Unallocated (R-BUD-1)

  /// Total − the sum of the limits; nil while a number does not parse.
  public var unallocated: Money? {
    guard let total = totalMinor else { return nil }
    var allocated: Int64 = 0
    for limit in limits {
      guard let minor = format.parseAmount(limit.limit) else { return nil }
      allocated += minor
    }
    return Money(minorUnits: total - allocated, currency: currency)
  }

  public var isOverAllocated: Bool { (unallocated?.minorUnits ?? 0) < 0 }

  public var unallocatedText: String { unallocated.map(format.money) ?? "—" }

  /// "Limits exceed the total by zł400.00" / "Spending in categories without a limit".
  public var unallocatedNote: String {
    guard let unallocated else { return "Check the amounts." }
    return unallocated.minorUnits < 0
      ? "Limits exceed the total by \(format.money(unallocated.negated))"
      : "Spending in categories without a limit"
  }

  // MARK: Saving

  public var validationMessage: String? {
    guard let total = totalMinor, total >= 0 else { return "The total is not a valid amount." }
    if limits.contains(where: { (format.parseAmount($0.limit) ?? -1) < 0 }) {
      return "A category limit is not a valid amount."
    }
    return nil
  }

  public var isDirty: Bool { snapshot != baseline }

  public var canSave: Bool { validationMessage == nil && isDirty }

  /// "Save budget": a plan effective from `appliesFrom` (R-BUD-3). A plan already starting that
  /// month is replaced; earlier and later plans stay (D29).
  public func save() async {
    guard validationMessage == nil, let totalMinor else { return }
    let month = appliesFrom.string
    let planID = loadedPlan?.effectiveMonth == month ? loadedPlan!.id : UUID()
    let plan = BudgetPlan(id: planID, effectiveMonth: month, totalMinor: totalMinor, currency: currency)
    let allocations = limits.compactMap { limit in
      format.parseAmount(limit.limit).map {
        BudgetAllocation(planID: planID, categoryID: limit.categoryID, limitMinor: $0)
      }
    }
    do {
      try await dependencies.budget.save(plan, allocations: allocations)
      loadedPlan = plan
      baseline = snapshot
      errorMessage = nil
      savedMessage = "Saved. It applies from \(format.month(appliesFrom))."
      await refreshLaterPlan()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the budget")
    }
  }
}
