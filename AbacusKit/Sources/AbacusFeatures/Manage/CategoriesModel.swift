import AbacusDomain
import Foundation
import Observation

/// One row of the category tree (R-MGMT-2): parents bold, children indented, usage count.
public struct CategoryRow: Identifiable, Equatable, Sendable {
  public let id: AbacusDomain.Category.ID
  public let name: String
  public let colorHex: String?
  public let isChild: Bool
  public let isArchived: Bool
  /// "124 transactions"; empty when unused.
  public let usage: String
}

/// The inspector form of a category (R-CAT-1, R-CAT-2).
public struct CategoryDraft: Equatable, Sendable {
  public let id: AbacusDomain.Category.ID
  public let isNew: Bool
  public let kind: CategoryKind
  public var name: String
  public var parentID: AbacusDomain.Category.ID?
  public var colorHex: String?
}

/// The Categories screen (approved prototype group 4, R-MGMT-2, R-CAT-1…4): Expense / Income
/// tabs, a one-level tree with drag-to-reorder and usage counts, an inspector to create and edit,
/// archive, and delete — a category in use asks where its transactions and budget limit go, or
/// offers to archive it instead.
@MainActor
@Observable
public final class CategoriesModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var kind: CategoryKind = .expense
  /// Every category, archived too.
  public private(set) var categories: [AbacusDomain.Category] = []
  /// Transactions and attached records using the category directly.
  public private(set) var usage: [AbacusDomain.Category.ID: Int] = [:]
  /// Categories with a limit in the budget in effect this month.
  public private(set) var budgeted: Set<AbacusDomain.Category.ID> = []
  public private(set) var selection: AbacusDomain.Category.ID?
  public var draft: CategoryDraft?
  public private(set) var dialog: ManageDialog?
  /// The category picked in the delete dialog.
  public var reassignTarget: AbacusDomain.Category.ID?
  public private(set) var errorMessage: String?

  @ObservationIgnored public let dependencies: ManageDependencies

  public init(dependencies: ManageDependencies) {
    self.dependencies = dependencies
  }

  // MARK: Loading

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      categories = try await dependencies.categories.categories(kind: nil, includeArchived: true)
      let txns = try await dependencies.allTransactions()
      var usage: [AbacusDomain.Category.ID: Int] = [:]
      for item in txns {
        if let id = item.txn.categoryID { usage[id, default: 0] += 1 }
        for line in item.lines {
          if let id = line.categoryID, id != item.txn.categoryID { usage[id, default: 0] += 1 }
        }
      }
      self.usage = usage
      let plan = try await dependencies.budget.plan(for: dependencies.today().yearMonth)
      budgeted = Set(plan?.allocations.map(\.categoryID) ?? [])
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load categories: \(error.localizedDescription)")
      return
    }
    if let selection, let category = category(selection), category.kind == kind {
      if draft?.id != selection { draft = Self.draft(category) }
    } else if draft?.isNew != true {
      select(rows.first?.id)
    }
  }

  // MARK: Tree

  public func category(_ id: AbacusDomain.Category.ID) -> AbacusDomain.Category? {
    categories.first { $0.id == id }
  }

  private var tree: CategoryTree { CategoryTree(categories) }

  /// Top-level categories of `kind` in order, each followed by its children (R-CAT-2).
  public func ordered(_ kind: CategoryKind) -> [AbacusDomain.Category] {
    let ofKind = categories.filter { $0.kind == kind }
    let ids = Set(ofKind.map(\.id))
    let byOrder: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = { ($0.position, $0.name) < ($1.position, $1.name) }
    // A child whose parent is missing (or of another kind) is shown at the top level.
    let parents = ofKind.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: byOrder)
    return parents.flatMap { parent in
      [parent] + ofKind.filter { $0.parentID == parent.id }.sorted(by: byOrder)
    }
  }

  public var rows: [CategoryRow] {
    let ids = Set(categories.filter { $0.kind == kind }.map(\.id))
    return ordered(kind).map { category in
      let count = usage[category.id] ?? 0
      return CategoryRow(
        id: category.id, name: category.name, colorHex: category.colorHex,
        isChild: category.parentID.map(ids.contains) ?? false, isArchived: category.isArchived,
        usage: count > 0 ? ManageText.transactions(count) : "")
    }
  }

  public func setKind(_ kind: CategoryKind) {
    guard kind != self.kind else { return }
    self.kind = kind
    select(rows.first?.id)
  }

  public func select(_ id: AbacusDomain.Category.ID?) {
    selection = id
    errorMessage = nil
    draft = id.flatMap(category).map(Self.draft)
  }

  // MARK: Inspector

  static func draft(_ category: AbacusDomain.Category) -> CategoryDraft {
    CategoryDraft(
      id: category.id, isNew: false, kind: category.kind, name: category.name, parentID: category.parentID,
      colorHex: category.colorHex)
  }

  /// "New category": a top-level category of the current tab.
  public func newCategory() {
    selection = nil
    errorMessage = nil
    draft = CategoryDraft(id: UUID(), isNew: true, kind: kind, name: "", parentID: nil, colorHex: ManageText.swatches[0])
  }

  /// "New subcategory": under the selected category (or under its parent).
  public func newSubcategory() {
    let parent = selection.flatMap(category).map { $0.parentID ?? $0.id }
    guard let parent, let parentCategory = category(parent) else { return }
    selection = nil
    errorMessage = nil
    draft = CategoryDraft(
      id: UUID(), isNew: true, kind: parentCategory.kind, name: "", parentID: parent, colorHex: parentCategory.colorHex)
  }

  public var canAddSubcategory: Bool {
    selection.flatMap(category).map { !$0.isArchived } ?? false
  }

  public var selectedCategory: AbacusDomain.Category? { selection.flatMap(category) }

  public var inspectorTitle: String {
    guard let draft else { return "" }
    if draft.isNew { return draft.name.isEmpty ? (draft.parentID == nil ? "New category" : "New subcategory") : draft.name }
    return selectedCategory?.name ?? draft.name
  }

  /// Parent choices: "None (top level)" plus top-level categories of the same kind. A category
  /// with children stays top level (one level only, R-CAT-2).
  public var parentOptions: [AbacusDomain.Category] {
    guard let draft else { return [] }
    return ordered(draft.kind).filter { $0.parentID == nil && $0.id != draft.id && !$0.isArchived }
  }

  public var canChangeParent: Bool {
    guard let draft else { return false }
    return !categories.contains { $0.parentID == draft.id }
  }

  /// "Used by 124 transactions and the monthly budget." (+ "Parent totals include its
  /// subcategories." for a top-level one).
  public var usageText: String {
    guard let draft else { return "" }
    let count = usage[draft.id] ?? 0
    var text = count > 0 ? "Used by \(ManageText.transactions(count))" : "Not used by any transaction"
    text += budgeted.contains(draft.id) ? " and the monthly budget." : "."
    if draft.parentID == nil { text += " Parent totals include its subcategories." }
    return text
  }

  public var validationMessage: String? {
    guard let draft else { return nil }
    return draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name." : nil
  }

  public var isDirty: Bool {
    guard let draft else { return false }
    if draft.isNew { return true }
    guard let category = category(draft.id) else { return false }
    return built(from: draft, base: category) != category
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

  public func save() async {
    guard let draft, canSave else { return }
    let category = built(from: draft, base: draft.isNew ? nil : category(draft.id))
    do {
      try await dependencies.categories.save(category)
      selection = category.id
      self.draft = nil
      await load()
      select(category.id)
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the category")
    }
  }

  public func revert() {
    if draft?.isNew == true { select(rows.first?.id) } else { select(selection) }
  }

  // MARK: Reorder (R-MGMT-2)

  /// Applies a drag in the tree (`List.onMove` offsets over `rows`):
  /// - a top-level category moves with its children, between other top-level blocks;
  /// - a subcategory dropped under a category joins that category's group (or its parent's),
  ///   dropped above everything it becomes top level.
  /// Positions of the tab's categories are renumbered and the changed ones saved.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
    let current = ordered(kind)
    guard source.count == 1, let from = source.first, current.indices.contains(from) else { return }
    let moving = current[from]
    let ids = Set(current.map(\.id))
    let isChild = moving.parentID.map(ids.contains) ?? false
    let hasChildren = current.contains { $0.parentID == moving.id }
    let above = destination > 0 ? current[destination - 1] : nil
    // `above` must not be the moving block itself.
    var blocks: [[AbacusDomain.Category]] = []
    for category in current {
      if category.parentID.map(ids.contains) ?? false { blocks[blocks.count - 1].append(category) } else { blocks.append([category]) }
    }

    var reparented = moving
    if !isChild || hasChildren {
      // Move the whole block after the block containing `above`.
      guard let movingBlock = blocks.firstIndex(where: { $0.first?.id == moving.id }) else { return }
      let block = blocks.remove(at: movingBlock)
      var insertAt = 0
      if let above, let aboveBlock = blocks.firstIndex(where: { $0.contains { $0.id == above.id } }) {
        insertAt = aboveBlock + 1
      } else if let above, block.contains(where: { $0.id == above.id }) {
        insertAt = movingBlock
      }
      blocks.insert(block, at: insertAt)
    } else {
      // A subcategory: remove it, then place it after `above` in `above`'s group.
      for index in blocks.indices { blocks[index].removeAll { $0.id == moving.id } }
      if let above, above.id != moving.id {
        let groupIndex = blocks.firstIndex { $0.contains { $0.id == above.id } }!
        let parent = blocks[groupIndex][0]
        reparented.parentID = parent.id
        let position = blocks[groupIndex].firstIndex { $0.id == above.id }! + 1
        blocks[groupIndex].insert(reparented, at: position)
      } else if above == nil {
        reparented.parentID = nil
        blocks.insert([reparented], at: 0)
      } else {
        return
      }
    }

    let flat = blocks.flatMap { $0 }
    var changed: [AbacusDomain.Category] = []
    for (position, category) in flat.enumerated() {
      var updated = category.id == reparented.id ? reparented : category
      updated.position = position
      if updated != self.category(category.id) { changed.append(updated) }
    }
    do {
      // Save a new parent first so the one-level rule holds while saving.
      for category in changed { try await dependencies.categories.save(category) }
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "move the category")
      await load()
    }
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
    let targets: [ManageDialog.Target] =
      inUse
      ? ordered(category.kind).filter { $0.id != category.id && !$0.isArchived }.map {
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
      if let sibling = ordered(category.kind).first(where: { $0.parentID == parent && $0.id != category.id && ids.contains($0.id) }) {
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
    await setArchived(id, true)
  }
}
