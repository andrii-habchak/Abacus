import AbacusDomain
import AbacusImport
import Foundation

// C31: row selection, bulk assignment, rule suggestions and "+ New category…" of the import
// wizard. Bulk actions apply the per-row decisions of the preview to every selected row that
// can take them; rows that cannot are counted in `bulkMessage`.

// MARK: - Types

/// How a click changes the selection (Accounts/Categories manner).
public enum ImportSelectionMode: Sendable {
  /// Plain click: this row only.
  case replace
  /// Cmd+click: add or remove this row.
  case toggle
  /// Shift+click: the rows from the last clicked one to this one.
  case range
}

/// What the bulk bar can do with the current selection.
public struct ImportBulkInfo: Equatable, Sendable {
  public var selected = 0
  /// Selected rows that take a category, by kind. Both kinds present = mixed selection.
  public var expenseRows = 0
  public var incomeRows = 0
  /// Rows that can become a transfer to an own account.
  public var accountRows = 0
  public var debtRows = 0
  /// Rows that can be excluded / included again.
  public var skipRows = 0
  public var includeRows = 0

  public var isMixedKinds: Bool { expenseRows > 0 && incomeRows > 0 }
  /// The kinds a category can be assigned for, in menu order.
  public var categoryKinds: [CategoryKind] {
    var kinds: [CategoryKind] = []
    if expenseRows > 0 { kinds.append(.expense) }
    if incomeRows > 0 { kinds.append(.income) }
    return kinds
  }
}

/// One rule the "Save rules" sheet offers: a pattern shared by some rows of the bulk selection.
public struct RuleSuggestion: Identifiable, Hashable, Sendable {
  public var id: String
  /// Editable; saved as the rule's text.
  public var pattern: String
  /// What `RulePattern.derive` gave.
  public var derived: String
  public var categoryID: AbacusDomain.Category.ID
  public var categoryName: String
  public var rowIDs: [String]
  /// A description of the first row, to show where the pattern comes from.
  public var example: String
  public var isOn = true

  public var rowCount: Int { rowIDs.count }
  /// A rule text needs at least three characters (like the derived ones).
  public var isValid: Bool { RulePattern.normalized(pattern).count >= 3 }
}

public struct RuleSuggestionSheet: Equatable, Sendable {
  public var suggestions: [RuleSuggestion]
  public var canConfirm: Bool { suggestions.allSatisfy { !$0.isOn || $0.isValid } }
}

/// The "New category" sheet opened from a row picker or the bulk bar.
public struct NewCategoryDraft: Equatable, Sendable {
  public enum Target: Equatable, Sendable {
    case row(String)
    case selection
  }

  public var name = ""
  public let kind: CategoryKind
  public var parentID: AbacusDomain.Category.ID?
  public let target: Target

  public var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Selection

extension ImportWizardModel {
  /// Rows of the current tab in display order: what a Shift click ranges over.
  var selectableIDs: [String] {
    switch tab {
    case .transactions: visibleRows.map(\.id)
    case .categoryAssignment: categoryAssignmentRows.map(\.id)
    case .review: reviewItems.map(\.id)
    case .mapping, .events: []
    }
  }

  /// The "Category assignment" tab: rows that still need a category.
  public var categoryAssignmentRows: [ImportRowItem] {
    rowItems.filter(\.needsCategory)
  }

  public func select(_ id: String, mode: ImportSelectionMode) {
    switch mode {
    case .replace:
      selection = [id]
      selectionAnchor = id
    case .toggle:
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      selectionAnchor = id
    case .range:
      let ids = selectableIDs
      guard let end = ids.firstIndex(of: id) else { return }
      let start = selectionAnchor.flatMap { ids.firstIndex(of: $0) } ?? end
      selection = Set(ids[min(start, end)...max(start, end)])
      if selectionAnchor == nil || !ids.contains(selectionAnchor!) { selectionAnchor = id }
    }
  }

  /// The current tab lists rows that can be selected.
  public var hasSelectableRows: Bool { !selectableIDs.isEmpty }

  public func selectAll() {
    selection = Set(selectableIDs)
  }

  public func clearSelection() {
    if !selection.isEmpty { selection = [] }
    selectionAnchor = nil
  }

  /// Rows that left the list (categorised, filtered out) leave the selection.
  func pruneSelection() {
    guard !selection.isEmpty else { return }
    let visible = Set(selectableIDs)
    let kept = selection.intersection(visible)
    if kept != selection { selection = kept }
    if let anchor = selectionAnchor, !visible.contains(anchor) { selectionAnchor = nil }
  }

  /// The selected row ids in list order.
  var selectedIDsInOrder: [String] {
    selectableIDs.filter { selection.contains($0) }
  }

  // MARK: What the selection can do

  /// The kind of category a row takes: the picker's kind, or the sign of a Needs review row;
  /// nil for rows without a category choice.
  func categoryKind(ofRow id: String, items: [String: ImportRowItem]? = nil) -> CategoryKind? {
    guard let row = preview?.row(id) else { return nil }
    if row.review != nil { return row.isInflow ? .income : .expense }
    let item = items?[id] ?? rowItems.first { $0.id == id }
    guard case .picker? = item?.category else { return nil }
    return row.type == .income ? .income : .expense
  }

  public var bulk: ImportBulkInfo {
    var info = ImportBulkInfo()
    guard let preview, !selection.isEmpty else { return info }
    let items = Dictionary(rowItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for id in selection {
      guard let row = preview.row(id) else { continue }
      info.selected += 1
      switch categoryKind(ofRow: id, items: items) {
      case .expense?: info.expenseRows += 1
      case .income?: info.incomeRows += 1
      case nil: break
      }
      if row.review != nil || (row.createsTransaction && row.review == nil && (row.type == .expense || row.type == .income)) {
        info.accountRows += 1
      }
      if row.canRecordDebt { info.debtRows += 1 }
      if canSkip(row) { info.skipRows += 1 }
      if row.excludedByUser { info.includeRows += 1 }
    }
    return info
  }

  private func canSkip(_ row: PreviewRow) -> Bool {
    if let review = row.review { return review.choice != .skip }
    switch row.status {
    case .new: return row.createsTransaction && !row.excludedByUser
    case .possibleDuplicate: return row.duplicate?.action != .skip
    default: return false
    }
  }

  /// Categories of `kind` the bulk Category menu lists (A–Z, subcategories under their parent).
  public func bulkCategoryOptions(_ kind: CategoryKind) -> [ImportCategoryOption] {
    categoryOptions(kind).filter { $0.choice != .none }
  }

  /// Own accounts a bulk "Account" can send the rows to, in the pickers' grouping.
  public var bulkAccountSections: [AccountPickerSection] {
    AccountOrder.pickerSections(accounts.filter { !$0.isArchived }, groups: accountGroups)
  }

  // MARK: Bulk actions

  private func beginBulk() {
    guard let preview else { return }
    bulkUndo = (preview, noRuleRows)
    bulkMessage = nil
  }

  private func finishBulk(_ text: String) {
    bulkMessage = text
  }

  private static func rows(_ n: Int) -> String { ImportFormat.count(n, "row") }

  /// Category for the selected rows of `kind` (the other kind stays as it is). Rows of Needs
  /// review are recorded as that kind with the category; others get it as their pick. Opens the
  /// "Save rules" sheet when picks can become rules.
  public func bulkSetCategory(_ categoryID: AbacusDomain.Category.ID, kind: CategoryKind) {
    guard preview != nil, categories.contains(where: { $0.id == categoryID && $0.kind == kind }) else { return }
    let items = Dictionary(rowItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let ids = selectedIDsInOrder.filter { categoryKind(ofRow: $0, items: items) == kind }
    guard !ids.isEmpty else { return }
    beginBulk()
    let reviewIDs = Set(ids.filter { preview?.row($0)?.review != nil })
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for id in ids {
          if reviewIDs.contains(id) {
            preview.setReviewChoice(.record(kind, categoryID: categoryID), forRow: id)
          } else {
            preview.setCategory(categoryID, forRow: id)
            preview.setSavesRule(true, forRow: id)
          }
        }
      }
    }
    noRuleRows.subtract(ids)
    finishBulk("Category set on \(Self.rows(ids.count)).")
    offerRules(forRows: ids)
  }

  /// Transfers to the own account `accountID` for the selected rows that can take it.
  public func bulkSetTransfer(to accountID: Account.ID) {
    guard let preview, !selection.isEmpty else { return }
    let ids = selectedIDsInOrder
    var applied = 0
    var skipped = 0
    var reviewIDs: [String] = []
    var plainIDs: [String] = []
    for id in ids {
      guard let row = preview.row(id) else { continue }
      if row.review != nil {
        if row.account == .existing(accountID) { skipped += 1 } else { reviewIDs.append(id) }
      } else if preview.canTransfer(row: id, to: accountID) {
        plainIDs.append(id)
      } else if row.createsTransaction, row.type == .expense || row.type == .income {
        skipped += 1
      }
    }
    guard !reviewIDs.isEmpty || !plainIDs.isEmpty else {
      bulkMessage = "None of the selected rows can be a transfer to that account (same account, or the amount in its currency is unknown)."
      return
    }
    beginBulk()
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for id in plainIDs { preview.setTransfer(toAccount: accountID, forRow: id) }
        for id in reviewIDs { preview.setReviewChoice(.transfer(accountID: accountID), forRow: id) }
      }
    }
    applied = plainIDs.count + reviewIDs.count
    let name = accounts.first { $0.id == accountID }?.name ?? "the account"
    finishBulk("\(Self.rows(applied)) now transfer\(applied == 1 ? "s" : "") to “\(name)”." + (skipped > 0 ? " \(Self.rows(skipped)) can't." : ""))
  }

  /// Opens the debt sheet for the selection: the first row's amounts are shown; the choice
  /// (person, debt, account) applies to every selected row that can be recorded as a debt.
  public func openBulkDebt() async {
    guard let preview else { return }
    let ids = selectedIDsInOrder.filter { preview.row($0)?.canRecordDebt == true }
    guard let first = ids.first else { return }
    await openDebt(forRow: first, bulkRows: ids)
  }

  func applyBulkDebt(link: DebtLink, personCurrency: Currency, baseRow: String, rows ids: [String]) {
    beginBulk()
    var count = 0
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for id in ids {
          guard let row = preview.row(id), row.canRecordDebt else { continue }
          let choice = ImportDebtChoice(
            personName: link.personName, debtID: link.debtID, accountID: link.accountID,
            currency: link.currency ?? personCurrency, amountMinor: id == baseRow ? link.amountMinor : nil)
          if row.review != nil {
            preview.setReviewChoice(.debt(choice), forRow: id)
          } else {
            preview.setDebt(choice, forRow: id)
          }
          count += 1
        }
      }
    }
    finishBulk("\(Self.rows(count)) now transfer\(count == 1 ? "s" : "") to the debt account of “\(link.personName)”.")
  }

  /// Excludes the selected rows from the import.
  public func bulkSkip() {
    guard let preview else { return }
    let rows = selectedIDsInOrder.compactMap { preview.row($0) }.filter(canSkip)
    guard !rows.isEmpty else { return }
    beginBulk()
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for row in rows {
          if row.review != nil {
            preview.setReviewChoice(.skip, forRow: row.id)
          } else if row.status == .possibleDuplicate {
            preview.setDuplicateAction(.skip, forRow: row.id)
          } else {
            preview.setExcluded(true, forRow: row.id)
          }
        }
      }
    }
    finishBulk("\(Self.rows(rows.count)) skipped.")
  }

  /// Brings rows excluded by "Skip" back.
  public func bulkInclude() {
    guard let preview else { return }
    let ids = selectedIDsInOrder.filter { preview.row($0)?.excludedByUser == true }
    guard !ids.isEmpty else { return }
    beginBulk()
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for id in ids { preview.setExcluded(false, forRow: id) }
      }
    }
    finishBulk("\(Self.rows(ids.count)) included again.")
  }

  /// A single row's "Include" (after a bulk skip).
  public func includeRow(_ id: String) {
    update { $0.setExcluded(false, forRow: id) }
  }

  /// Takes back the last bulk action.
  public func undoBulk() {
    guard let saved = bulkUndo else { return }
    bulkUndo = nil
    noRuleRows = saved.noRuleRows
    ruleSheet = nil
    setPreview(saved.preview)
    bulkMessage = "Undone."
  }

  // MARK: Rule suggestions (R-IMP-8)

  /// One suggested rule per distinct pattern and category among `ids`; rows whose payee already
  /// has an enabled rule never get a learned pattern, so they are not offered.
  public func ruleSuggestions(forRows ids: [String]) -> [RuleSuggestion] {
    guard let preview else { return [] }
    var order: [String] = []
    var groups: [String: RuleSuggestion] = [:]
    for id in ids {
      guard let row = preview.row(id), row.categorySource == .user, let pattern = row.rulePattern,
        case .existing(let categoryID)? = row.category
      else { continue }
      let key = "\(pattern)|\(categoryID.uuidString)"
      if groups[key] == nil {
        order.append(key)
        groups[key] = RuleSuggestion(
          id: key, pattern: pattern, derived: pattern, categoryID: categoryID, categoryName: categoryPath(categoryID),
          rowIDs: [], example: row.source.payee)
      }
      groups[key]?.rowIDs.append(id)
    }
    return order.compactMap { groups[$0] }
  }

  private func offerRules(forRows ids: [String]) {
    let suggestions = ruleSuggestions(forRows: ids)
    ruleSheet = suggestions.isEmpty ? nil : RuleSuggestionSheet(suggestions: suggestions)
  }

  /// Confirms the sheet: unticked (or invalid) patterns are not saved, edited ones replace the
  /// derived text; the rules are written on commit like the other learned rules.
  public func applyRuleSheet() {
    guard let sheet = ruleSheet else { return }
    ruleSheet = nil
    update(keepBulk: true) { preview in
      preview.batch { preview in
        for suggestion in sheet.suggestions {
          let save = suggestion.isOn && suggestion.isValid
          for id in suggestion.rowIDs {
            preview.setSavesRule(save, forRow: id)
            if save { preview.setRulePattern(suggestion.pattern, forRow: id) }
          }
        }
      }
    }
    for suggestion in sheet.suggestions {
      for id in suggestion.rowIDs {
        if suggestion.isOn && suggestion.isValid { noRuleRows.remove(id) } else { noRuleRows.insert(id) }
      }
    }
  }

  /// Closes the sheet without changing anything: the picks keep their default (saved as rules).
  public func dismissRuleSheet() {
    ruleSheet = nil
  }

  // MARK: New category

  /// Parent choices for a new category of `kind`: its active top-level categories.
  public func newCategoryParents(_ kind: CategoryKind) -> [AbacusDomain.Category] {
    categories.filter { $0.kind == kind && $0.parentID == nil && !$0.isArchived }.sorted(by: CategoryOrder.byName)
  }

  /// "+ New category…" in a row's picker: the kind follows the row.
  public func beginNewCategory(forRow id: String) {
    guard let kind = categoryKind(ofRow: id) else { return }
    newCategoryDraft = NewCategoryDraft(kind: kind, target: .row(id))
  }

  /// "+ New category…" in the bulk bar, for the selected rows of `kind`.
  public func beginNewCategoryForSelection(kind: CategoryKind) {
    newCategoryDraft = NewCategoryDraft(kind: kind, target: .selection)
  }

  public func cancelNewCategory() {
    newCategoryDraft = nil
  }

  /// Creates the category (an active one with the same name and parent is used instead), reads
  /// the categories again and picks it for the row, or for the selection.
  public func saveNewCategory(_ edited: NewCategoryDraft? = nil) async {
    guard let draft = edited ?? newCategoryDraft, draft.isValid else { return }
    newCategoryDraft = nil
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = categories.first {
      $0.kind == draft.kind && $0.parentID == draft.parentID && !$0.isArchived
        && $0.name.caseInsensitiveCompare(name) == .orderedSame
    }
    let id: AbacusDomain.Category.ID
    if let existing {
      id = existing.id
    } else {
      let all = (try? await pipeline.categories.categories(kind: nil, includeArchived: true)) ?? categories
      let created = AbacusDomain.Category(
        name: name, kind: draft.kind, parentID: draft.parentID, colorHex: ColorPalette.pick(avoiding: all.map(\.colorHex)),
        position: (all.map(\.position).max() ?? -1) + 1, createdAt: dependencies.pipeline.now())
      do {
        try await pipeline.categories.save(created)
      } catch {
        errorMessage = "The category couldn't be created: \(error.localizedDescription)"
        return
      }
      id = created.id
    }
    await reloadReference()
    switch draft.target {
    case .row(let rowID):
      if preview?.row(rowID)?.review != nil {
        selectReviewCategory(id, forRow: rowID)
      } else {
        setCategory(.existing(id), forRow: rowID)
      }
    case .selection:
      bulkSetCategory(id, kind: draft.kind)
    }
  }
}
