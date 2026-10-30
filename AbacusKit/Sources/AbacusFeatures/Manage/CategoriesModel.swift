import AbacusDomain
import Foundation
import Observation

/// One row of the category tree (R-MGMT-2): parents bold, children indented, usage count.
public struct CategoryRow: Identifiable, Hashable, Sendable {
  public let id: AbacusDomain.Category.ID
  public let name: String
  public let colorHex: String?
  public let isChild: Bool
  public let isArchived: Bool
  /// "124 transactions"; empty when unused.
  public let usage: String
  /// The built-in "Uncategorised" entry (D47): pinned at the top, not draggable, no drop target.
  public var isBuiltIn = false
  /// False for a parent shown only because one of its subcategories matches the search.
  public var matchesSearch = true
}

/// The inspector form of a category (R-CAT-1, R-CAT-2), or of the built-in "Uncategorised"
/// whose colour alone can change (D47).
public struct CategoryDraft: Equatable, Sendable {
  public let id: AbacusDomain.Category.ID
  public let isNew: Bool
  public let kind: CategoryKind
  public var name: String
  public var parentID: AbacusDomain.Category.ID?
  public var colorHex: String?
  public var isBuiltIn = false
}

extension CategoryDraft: Identifiable {}

/// Where a dragged category lands (R-MGMT-8, like Reminders).
public enum CategoryDropPosition: Hashable, Sendable {
  /// Between rows, above / below the target: a reorder (the sort becomes "Custom order").
  case before, after
  /// On the row: becomes a subcategory of the target (one level only).
  case onto
}

/// The Categories screen (approved prototype group 4, R-MGMT-2, R-MGMT-8, R-CAT-1…4): Expense /
/// Income tabs, the built-in "Uncategorised" pinned on top, a one-level tree in the chosen
/// sort with search, drag and drop to reorder or nest, an inspector to create and edit,
/// archive, and delete — a category in use asks where its transactions and budget limit go,
/// or offers to archive it instead.
@MainActor
@Observable
public final class CategoriesModel {
  /// The selection id of the built-in "Uncategorised" row (not a category id).
  public static let uncategorisedID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

  public private(set) var phase: ManagePhase = .idle
  public private(set) var kind: CategoryKind = .expense
  /// Every category, archived too.
  public private(set) var categories: [AbacusDomain.Category] = []
  /// Transactions and attached records using the category directly.
  public private(set) var usage: [AbacusDomain.Category.ID: Int] = [:]
  /// Expenses / incomes without a category (the built-in "Uncategorised").
  public private(set) var uncategorisedUsage: [CategoryKind: Int] = [:]
  /// The built-in "Uncategorised" colour (D47).
  public private(set) var uncategorisedColor = Uncategorised.defaultColorHex
  /// Categories with a limit in the budget in effect this month.
  public private(set) var budgeted: Set<AbacusDomain.Category.ID> = []
  /// The one selected row; nil while several rows are selected (`multiSelection`) or none is.
  public private(set) var selection: AbacusDomain.Category.ID? {
    didSet { if selection != nil { multiSelection = [] } }
  }
  /// Two or more selected rows (Cmd / Shift click, C27); empty otherwise. Only dragging uses it:
  /// the inspector, "New transaction" and the sheets work on `selection`.
  public private(set) var multiSelection: Set<AbacusDomain.Category.ID> = []
  /// Every selected row: `multiSelection`, or the single `selection`.
  public var selectedIDs: Set<AbacusDomain.Category.ID> {
    multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : multiSelection
  }
  public var draft: CategoryDraft?
  public private(set) var dialog: ManageDialog?
  /// The category picked in the delete dialog.
  public var reassignTarget: AbacusDomain.Category.ID?
  public private(set) var errorMessage: String?
  /// The page's order (R-MGMT-8); remembered in the settings.
  public private(set) var sort: CategorySort = .default
  /// The page search: names of categories and subcategories (R-MGMT-11).
  public var searchText = ""
  /// The open editor sheet's starting form (D55); the sheet keeps its own copy and hands it
  /// back on Save. nil while no sheet is open.
  public private(set) var sheet: CategoryDraft?

  @ObservationIgnored public let dependencies: ManageDependencies
  /// The selection before "New category", given back when the sheet is cancelled.
  @ObservationIgnored private var selectionBeforeNew: AbacusDomain.Category.ID?
  /// Called after this screen changed data other screens show (names, colours: R-MGMT-7),
  /// so the transaction list and the dashboard re-read it.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?
  @ObservationIgnored private var sortLoaded = false

  public init(dependencies: ManageDependencies) {
    self.dependencies = dependencies
  }

  // MARK: Loading

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      categories = try await dependencies.categories.categories(kind: nil, includeArchived: true)
      dropChecks = [:]
      let txns = try await dependencies.allTransactions()
      var usage: [AbacusDomain.Category.ID: Int] = [:]
      var uncategorised: [CategoryKind: Int] = [:]
      for item in txns {
        if let id = item.txn.categoryID {
          usage[id, default: 0] += 1
        } else if item.txn.type != .transfer {
          uncategorised[item.txn.type == .income ? .income : .expense, default: 0] += 1
        }
        for line in item.lines {
          if let id = line.categoryID, id != item.txn.categoryID { usage[id, default: 0] += 1 }
        }
      }
      self.usage = usage
      uncategorisedUsage = uncategorised
      uncategorisedColor = await dependencies.settings.uncategorisedColor()
      if !sortLoaded {
        sortLoaded = true
        let stored = try? await dependencies.settings.value(.categorySort)
        sort = stored.flatMap(CategorySort.init(rawValue:)) ?? .default
        dropChecks = [:]
      }
      let plan = try await dependencies.budget.plan(for: dependencies.today().yearMonth)
      budgeted = Set(plan?.allocations.map(\.categoryID) ?? [])
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load categories: \(error.localizedDescription)")
      return
    }
    if selection == Self.uncategorisedID {
      if draft?.isBuiltIn != true { select(Self.uncategorisedID) }
    } else if let selection, let category = category(selection), category.kind == kind {
      if draft?.id != selection { draft = Self.draft(category) }
    } else if multiSelection.count > 1 {
      // Several rows selected: keep those that still exist on this tab.
      let alive = multiSelection.filter { id in category(id)?.kind == kind || id == Self.uncategorisedID }
      if alive.count > 1 { multiSelection = alive } else { select(alive.first) }
    } else if draft?.isNew != true {
      select(rows.first?.id)
    }
  }

  // MARK: Tree

  public func category(_ id: AbacusDomain.Category.ID) -> AbacusDomain.Category? {
    categories.first { $0.id == id }
  }

  /// Categories of `kind` in the page's sort: top-level ones, each followed by its children
  /// (R-CAT-2, R-MGMT-8).
  public func ordered(_ kind: CategoryKind) -> [AbacusDomain.Category] {
    CategoryOrder.tree(categories.filter { $0.kind == kind }, by: sort)
  }

  private func isChild(_ category: AbacusDomain.Category, among ids: Set<AbacusDomain.Category.ID>) -> Bool {
    category.parentID.map(ids.contains) ?? false
  }

  private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }

  private func matches(_ name: String) -> Bool {
    let query = trimmedSearch
    return query.isEmpty || name.localizedStandardContains(query)
  }

  /// The tab's categories in the sort; with a search, the matching ones plus the parent of
  /// each matching subcategory (shown dimmed, so the child is seen under its parent).
  public var rows: [CategoryRow] {
    let ofKind = ordered(kind)
    let ids = Set(ofKind.map(\.id))
    let searching = !trimmedSearch.isEmpty
    var shownParents: Set<AbacusDomain.Category.ID> = []
    if searching {
      for category in ofKind where isChild(category, among: ids) && matches(category.name) {
        shownParents.insert(category.parentID!)
      }
    }
    return ofKind.compactMap { category in
      let matched = matches(category.name)
      guard matched || shownParents.contains(category.id) else { return nil }
      let count = usage[category.id] ?? 0
      return CategoryRow(
        id: category.id, name: category.name, colorHex: category.colorHex,
        isChild: isChild(category, among: ids), isArchived: category.isArchived,
        usage: count > 0 ? ManageText.transactions(count) : "", matchesSearch: matched)
    }
  }

  /// The built-in "Uncategorised" pinned above the tree (D47); hidden when the search does
  /// not match it.
  public var uncategorisedRow: CategoryRow? {
    guard matches(Uncategorised.title) else { return nil }
    let count = uncategorisedUsage[kind] ?? 0
    return CategoryRow(
      id: Self.uncategorisedID, name: Uncategorised.title, colorHex: uncategorisedColor, isChild: false,
      isArchived: false, usage: count > 0 ? ManageText.transactions(count) : "", isBuiltIn: true)
  }

  /// "No categories match “xyz”." while a search hides every row.
  public var emptySearchMessage: String? {
    guard !trimmedSearch.isEmpty, rows.isEmpty, uncategorisedRow == nil else { return nil }
    return "No categories match “\(trimmedSearch)”."
  }

  public func setKind(_ kind: CategoryKind) {
    guard kind != self.kind else { return }
    self.kind = kind
    select(rows.first?.id)
  }

  /// The list's selection (C27): one row selects it as before; several rows (Cmd / Shift click)
  /// are kept as `multiSelection` with the inspector, draft and `selection` cleared.
  public func select(ids: Set<AbacusDomain.Category.ID>) {
    let known = ids.filter { id in id == Self.uncategorisedID || category(id)?.kind == kind }
    if known.count <= 1 { return select(known.first) }
    select(nil)
    multiSelection = known
  }

  public func select(_ id: AbacusDomain.Category.ID?) {
    multiSelection = []
    selection = id
    errorMessage = nil
    if id == Self.uncategorisedID {
      draft = CategoryDraft(
        id: Self.uncategorisedID, isNew: false, kind: kind, name: Uncategorised.title, parentID: nil,
        colorHex: uncategorisedColor, isBuiltIn: true)
    } else {
      draft = id.flatMap(category).map(Self.draft)
    }
  }

  /// The sort selector (R-MGMT-8); the choice is remembered.
  public func setSort(_ sort: CategorySort) async {
    guard sort != self.sort else { return }
    self.sort = sort
    sortLoaded = true
    dropChecks = [:]
    try? await dependencies.settings.set(.categorySort, sort.rawValue)
  }

  // MARK: Inspector

  static func draft(_ category: AbacusDomain.Category) -> CategoryDraft {
    CategoryDraft(
      id: category.id, isNew: false, kind: category.kind, name: category.name, parentID: category.parentID,
      colorHex: category.colorHex)
  }

  /// "New category": a top-level category of the current tab (subcategories come from drag
  /// and drop or the inspector's Parent field).
  public func newCategory() {
    selectionBeforeNew = selection ?? selectionBeforeNew
    selection = nil
    errorMessage = nil
    let siblings = categories.filter { $0.kind == kind && $0.parentID == nil }.map(\.colorHex)
    let draft = CategoryDraft(
      id: UUID(), isNew: true, kind: kind, name: "", parentID: nil, colorHex: ColorPalette.pick(avoiding: siblings))
    self.draft = draft
    sheet = draft
  }

  // MARK: Editor sheet (D55)

  /// Opens the editor sheet on a category or the built-in "Uncategorised" (double-click,
  /// Return, "Edit…").
  public func edit(_ id: AbacusDomain.Category.ID) {
    guard id == Self.uncategorisedID || category(id) != nil else { return }
    select(id)
    sheet = draft
  }

  /// Cancel / Escape: closes the sheet without saving; a new category's sheet gives the
  /// selection back.
  public func dismissSheet() {
    let wasNew = sheet?.isNew == true
    sheet = nil
    if wasNew {
      let previous = selectionBeforeNew.flatMap { id in
        id == Self.uncategorisedID || category(id)?.kind == kind ? id : nil
      }
      selectionBeforeNew = nil
      select(previous ?? rows.first?.id)
    } else {
      select(selection)
    }
  }

  /// Saves the sheet's form; the sheet closes when the save worked.
  public func save(_ draft: CategoryDraft) async {
    self.draft = draft
    if await save() {
      sheet = nil
      selectionBeforeNew = nil
    }
  }

  /// What is wrong with a form, or nil when it can be saved.
  public func validationMessage(_ draft: CategoryDraft) -> String? {
    guard !draft.isBuiltIn else { return nil }
    return draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name." : nil
  }

  public func isDirty(_ draft: CategoryDraft) -> Bool {
    if draft.isNew { return true }
    if draft.isBuiltIn { return ColorPalette.normalized(draft.colorHex) != uncategorisedColor }
    guard let category = category(draft.id) else { return false }
    return built(from: draft, base: category) != category
  }

  public func canSave(_ draft: CategoryDraft) -> Bool { isDirty(draft) && validationMessage(draft) == nil }

  /// Parent choices for a form: "None (top level)" plus top-level categories of its kind, A–Z.
  public func parentOptions(_ draft: CategoryDraft) -> [AbacusDomain.Category] {
    guard !draft.isBuiltIn else { return [] }
    return CategoryOrder.alphabetical(
      categories.filter { $0.kind == draft.kind && $0.parentID == nil && $0.id != draft.id && !$0.isArchived })
  }

  /// A category with subcategories stays top level (one level only, R-CAT-2).
  public func canChangeParent(_ draft: CategoryDraft) -> Bool {
    !draft.isBuiltIn && !categories.contains { $0.parentID == draft.id }
  }

  /// The selected category (nil for the built-in "Uncategorised").
  public var selectedCategory: AbacusDomain.Category? { selection.flatMap(category) }

  public var inspectorTitle: String {
    guard let draft else { return "" }
    if draft.isNew { return draft.name.isEmpty ? "New category" : draft.name }
    if draft.isBuiltIn { return Uncategorised.title }
    return selectedCategory?.name ?? draft.name
  }

  /// Parent choices: "None (top level)" plus top-level categories of the same kind, A–Z. A
  /// category with children stays top level (one level only, R-CAT-2).
  public var parentOptions: [AbacusDomain.Category] {
    draft.map(parentOptions) ?? []
  }

  public var canChangeParent: Bool {
    draft.map(canChangeParent) ?? false
  }

  /// "Used by 124 transactions and the monthly budget." (+ "Parent totals include its
  /// subcategories." for a top-level one).
  public var usageText: String {
    draft.map(usageText) ?? ""
  }

  public func usageText(_ draft: CategoryDraft) -> String {
    if draft.isBuiltIn {
      let count = uncategorisedUsage[draft.kind] ?? 0
      let kindName = draft.kind == .income ? "incomes" : "expenses"
      let used = count > 0 ? "\(ManageText.transactions(count)) (\(kindName)) have no category." : "Every \(draft.kind.rawValue) has a category."
      return "\(used) Built in: transactions without a category use this name and colour in the list, the dashboard and filters. Only the colour can change."
    }
    let count = usage[draft.id] ?? 0
    var text = count > 0 ? "Used by \(ManageText.transactions(count))" : "Not used by any transaction"
    text += budgeted.contains(draft.id) ? " and the monthly budget." : "."
    if draft.parentID == nil { text += " Parent totals include its subcategories." }
    return text
  }

  public var validationMessage: String? {
    draft.flatMap(validationMessage)
  }

  public var isDirty: Bool {
    draft.map(isDirty) ?? false
  }

  public var canSave: Bool { isDirty && validationMessage == nil }

  private func built(from draft: CategoryDraft, base: AbacusDomain.Category?) -> AbacusDomain.Category {
    var category =
      base
      ?? AbacusDomain.Category(
        id: draft.id, name: "", kind: draft.kind, position: (categories.map(\.position).max() ?? -1) + 1)
    category.name = draft.name.trimmingCharacters(in: .whitespaces)
    category.parentID = draft.parentID
    category.colorHex = draft.colorHex
    return category
  }

  /// Saves the open form; true when it was saved.
  @discardableResult
  public func save() async -> Bool {
    guard let draft, canSave else { return false }
    if draft.isBuiltIn {
      return await saveUncategorisedColor(draft.colorHex)
    }
    let category = built(from: draft, base: draft.isNew ? nil : category(draft.id))
    do {
      try await dependencies.categories.save(category)
      await onDataChange?()
      selection = category.id
      self.draft = nil
      await load()
      select(category.id)
      return true
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the category")
      return false
    }
  }

  private func saveUncategorisedColor(_ hex: String?) async -> Bool {
    guard let hex = ColorPalette.normalized(hex) else { return false }
    do {
      try await dependencies.settings.set(.uncategorisedColor, hex)
      uncategorisedColor = hex
      await onDataChange?()
      select(Self.uncategorisedID)
      return true
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the colour")
      return false
    }
  }

  public func revert() {
    if draft?.isNew == true { select(rows.first?.id) } else { select(selection) }
  }

  // MARK: Drag and drop (R-MGMT-8)

  /// Whether `moving` may be dropped there: same tab, not the built-in entry, one level only
  /// (a category with subcategories never becomes one).
  public func canDrop(
    _ moving: AbacusDomain.Category.ID, on target: AbacusDomain.Category.ID?, position: CategoryDropPosition
  ) -> Bool {
    // Asked on every mouse move of a drag: answered once per proposal until the data changes (S1).
    let key = DropCheck(kind: kind, moving: moving, target: target, position: position)
    if let known = dropChecks[key] { return known }
    let allowed = plan(moving, on: target, position: position) != nil
    dropChecks[key] = allowed
    return allowed
  }

  /// A multi-selection drag (C27): what is really moved, in list order. A parent carries its own
  /// subcategories, so selected subcategories of a selected parent are left out; unknown ids
  /// (the built-in "Uncategorised" row, other tab) are dropped.
  public func draggedItems(_ ids: [AbacusDomain.Category.ID]) -> [AbacusDomain.Category.ID] {
    let wanted = Set(ids)
    let current = ordered(kind)
    let rowIDs = Set(current.map(\.id))
    return current.compactMap { category -> AbacusDomain.Category.ID? in
      guard wanted.contains(category.id) else { return nil }
      if let parent = category.parentID, rowIDs.contains(parent), wanted.contains(parent) { return nil }
      return category.id
    }
  }

  /// Whether the whole selection may be dropped there (C27). All or nothing: one item that
  /// can't go there (a parent with subcategories onto a row, a row onto itself, the built-in
  /// entry…) refuses the drop, which the outline shows as the no-drop cursor before release.
  public func canDrop(
    _ moving: [AbacusDomain.Category.ID], on target: AbacusDomain.Category.ID?, position: CategoryDropPosition
  ) -> Bool {
    let items = draggedItems(moving)
    // An id that is not a row of this tab (Uncategorised) makes the drop impossible.
    guard !items.isEmpty, Set(moving).subtracting(Set(ordered(kind).map(\.id))).isEmpty else { return false }
    return items.allSatisfy { canDrop($0, on: target, position: position) }
  }

  private struct DropCheck: Hashable {
    let kind: CategoryKind
    let moving: AbacusDomain.Category.ID
    let target: AbacusDomain.Category.ID?
    let position: CategoryDropPosition
  }

  /// `canDrop` answers for the current categories and sort.
  @ObservationIgnored private var dropChecks: [DropCheck: Bool] = [:]

  /// After a drop only parents and positions changed: the categories are re-read without the
  /// transactions (usage counts stay) (S1).
  private func reloadOrder() async {
    guard phase == .loaded,
      let categories = try? await dependencies.categories.categories(kind: nil, includeArchived: true)
    else { return await load() }
    self.categories = categories
    dropChecks = [:]
  }

  /// Applies a drop:
  /// - `.onto` a row: `moving` becomes its subcategory (onto a subcategory: a sibling of it),
  ///   at the end of that group; the sort stays;
  /// - `.before` / `.after` a row: a reorder in what the page shows, so the sort becomes
  ///   "Custom order". Between top-level rows → top level; next to a subcategory → a sibling
  ///   of it; right below a parent whose subcategories follow → its first subcategory;
  /// - `target` nil (the space below the list): top level, last.
  /// Changed categories are saved, the moved one first; the store keeps the tree one level
  /// deep and of one kind, transactions and budget limits keep their category.
  public func drop(
    _ moving: AbacusDomain.Category.ID, on target: AbacusDomain.Category.ID?, position: CategoryDropPosition
  ) async {
    await drop([moving], on: target, position: position)
  }

  /// Applies a multi-selection drop (C27) with the same rules for every dragged row, in list
  /// order (after a row: they land in that order too). A refused drop (see `canDrop`) changes
  /// nothing.
  public func drop(
    _ moving: [AbacusDomain.Category.ID], on target: AbacusDomain.Category.ID?, position: CategoryDropPosition
  ) async {
    guard canDrop(moving, on: target, position: position) else { return }
    let items = draggedItems(moving)
    // "After a row": last item first, so each one lands right below the row.
    let sequence = position == .after ? Array(items.reversed()) : items
    var changed = false
    var sorted = false
    do {
      for id in sequence {
        guard let plan = plan(id, on: target, position: position) else { continue }
        if plan.reorders, !sorted {
          sorted = true
          await setSort(.custom)
        }
        for category in plan.changed { try await dependencies.categories.save(category) }
        if !plan.changed.isEmpty { changed = true }
        await reloadOrder()
      }
      if changed { await onDataChange?() }
    } catch {
      errorMessage = ManageFailure.message(error, doing: "move the category")
      await load()
    }
  }

  private struct DropPlan {
    /// The moved category first.
    var changed: [AbacusDomain.Category]
    var reorders: Bool
  }

  private func plan(
    _ movingID: AbacusDomain.Category.ID, on targetID: AbacusDomain.Category.ID?, position: CategoryDropPosition
  ) -> DropPlan? {
    let current = ordered(kind)
    let ids = Set(current.map(\.id))
    guard movingID != targetID, var moving = current.first(where: { $0.id == movingID }) else { return nil }
    let target = targetID.flatMap { id in current.first { $0.id == id } }
    if targetID != nil, target == nil { return nil }
    let movingHasChildren = current.contains { $0.parentID == movingID }

    if position == .onto {
      guard let target, !movingHasChildren else { return nil }
      let parentID = isChild(target, among: ids) ? target.parentID! : target.id
      guard parentID != movingID else { return nil }
      // Last in the new group; positions only order siblings, so the rest stays as it is.
      let siblings = current.filter { $0.parentID == parentID && $0.id != movingID }
      moving.parentID = parentID
      moving.position = (siblings.map(\.position) + [target.position]).max()! + 1
      return DropPlan(changed: [moving], reorders: false)
    }

    // Reorder: blocks of the order shown (parent + children), the moving category taken out.
    var blocks: [[AbacusDomain.Category]] = []
    for category in current {
      // A child before any parent (an orphan the tree put first) starts a block of its own
      // rather than trapping on `blocks[-1]` (S1).
      if isChild(category, among: ids), !blocks.isEmpty {
        blocks[blocks.count - 1].append(category)
      } else {
        blocks.append([category])
      }
    }
    var movingBlock: [AbacusDomain.Category] = [moving]
    if let index = blocks.firstIndex(where: { $0[0].id == movingID }) {
      movingBlock = blocks.remove(at: index)
    } else {
      for index in blocks.indices { blocks[index].removeAll { $0.id == movingID } }
    }

    if let target {
      if isChild(target, among: ids) {
        // Next to a subcategory: a sibling of it.
        guard !movingHasChildren,
          let group = blocks.firstIndex(where: { $0.contains { $0.id == target.id } }),
          let at = blocks[group].firstIndex(where: { $0.id == target.id })
        else { return nil }
        moving.parentID = target.parentID
        blocks[group].insert(moving, at: position == .before ? at : at + 1)
      } else {
        guard let group = blocks.firstIndex(where: { $0[0].id == target.id }) else { return nil }
        if position == .after, blocks[group].count > 1, !movingHasChildren {
          // Right below a parent whose subcategories follow: its first subcategory.
          moving.parentID = target.id
          blocks[group].insert(moving, at: 1)
        } else {
          moving.parentID = nil
          movingBlock[0] = moving
          blocks.insert(movingBlock, at: position == .before ? group : group + 1)
        }
      }
    } else {
      moving.parentID = nil
      movingBlock[0] = moving
      blocks.append(movingBlock)
    }

    var changed: [AbacusDomain.Category] = []
    for (index, category) in blocks.flatMap({ $0 }).enumerated() {
      var updated = category.id == movingID ? moving : category
      updated.position = index
      if updated != self.category(category.id) {
        if updated.id == movingID { changed.insert(updated, at: 0) } else { changed.append(updated) }
      }
    }
    return DropPlan(changed: changed, reorders: true)
  }

  // MARK: Archive and delete (R-CAT-3)

  public var archiveTitle: String { selectedCategory?.isArchived == true ? "Unarchive" : "Archive" }

  public func archiveOrUnarchive() async {
    guard let category = selectedCategory else { return }
    await setArchived(category.id, !category.isArchived)
  }

  private func setArchived(_ id: AbacusDomain.Category.ID, _ archived: Bool) async {
    do {
      try await dependencies.categories.setArchived(id, archived)
      await onDataChange?()
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: archived ? "archive the category" : "unarchive the category")
    }
  }

  /// Delete…: a used category asks where its transactions and budget limit go (same kind), with
  /// "Archive instead"; a parent's subcategories move to the top level.
  public func requestDelete() {
    guard let category = selectedCategory else { return }
    let count = usage[category.id] ?? 0
    let inBudget = budgeted.contains(category.id)
    let inUse = count > 0 || inBudget
    let children = categories.filter { $0.parentID == category.id }
    var message: String
    if inUse {
      let uses = count > 0 ? "\(ManageText.transactions(count))\(inBudget ? " and the monthly budget" : "")" : "the monthly budget"
      message = "\(category.name) is used by \(uses). Choose where they go, or archive the category to keep it on old transactions."
    } else {
      message = "It is not used anywhere."
    }
    if !children.isEmpty {
      message += " Its subcategories (\(children.map(\.name).joined(separator: ", "))) move to the top level."
    }
    // The target picker lists categories A–Z (R-MGMT-8).
    let targets: [ManageDialog.Target] =
      inUse
      ? CategoryOrder.alphabetical(categories.filter { $0.kind == category.kind })
        .filter { $0.id != category.id && !$0.isArchived }
        .map {
          ManageDialog.Target(id: $0.id, name: $0.name, isChild: $0.parentID != nil && $0.parentID != category.id)
        } : []
    if inUse, targets.isEmpty {
      message += " There is no other \(category.kind.rawValue) category to move them to."
    }
    reassignTarget = defaultTarget(for: category, among: targets)
    dialog = ManageDialog(
      action: .deleteCategory(category.id), title: "Delete “\(category.name)”?", message: message,
      confirmTitle: inUse ? "Move and delete" : "Delete", isDestructive: true, targets: targets, offersArchive: inUse)
  }

  /// A sibling first (Groceries → Eating out, as the prototype), then the parent, then the first.
  private func defaultTarget(for category: AbacusDomain.Category, among targets: [ManageDialog.Target]) -> AbacusDomain.Category.ID? {
    let ids = Set(targets.map(\.id))
    if let parent = category.parentID {
      if let sibling = CategoryOrder.tree(categories.filter { $0.kind == category.kind }, by: .custom)
        .first(where: { $0.parentID == parent && $0.id != category.id && ids.contains($0.id) })
      {
        return sibling.id
      }
      if ids.contains(parent) { return parent }
    }
    return targets.first?.id
  }

  /// "Move and delete" stays disabled until a target is picked (a used category).
  public var canConfirmDialog: Bool {
    guard let dialog else { return false }
    return !dialog.offersArchive || reassignTarget != nil
  }

  public func cancelDialog() { dialog = nil }

  public func confirmDialog() async {
    guard let dialog, canConfirmDialog, case .deleteCategory(let id) = dialog.action else { return }
    self.dialog = nil
    do {
      try await dependencies.categories.delete(id, reassignTo: dialog.offersArchive ? reassignTarget : nil)
      sheet = nil
      await onDataChange?()
      selection = nil
      draft = nil
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "delete the category")
    }
  }

  /// "Archive instead" (R-CAT-3).
  public func archiveInstead() async {
    guard let dialog, case .deleteCategory(let id) = dialog.action else { return }
    self.dialog = nil
    sheet = nil
    await setArchived(id, true)
  }
}
