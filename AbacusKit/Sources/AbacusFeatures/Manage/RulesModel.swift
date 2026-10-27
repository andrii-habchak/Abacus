import AbacusDomain
import AbacusImport
import Foundation
import Observation

/// One rule row: enable toggle, the rule in words, origin, hit count.
public struct RuleRow: Identifiable, Equatable, Sendable {
  public let id: CategoryRule.ID
  /// The rule's short name: its text, or "amount > 100.00" for an amount-only rule.
  public let pattern: String
  /// "Description contains “lidl” and amount bigger than 100.00 on PKO Personal".
  public let condition: String
  /// "Food › Groceries" / "Transfer to/from Loan from friend".
  public let action: String
  /// "Learned from an import" / "Manual".
  public let origin: String
  public let hits: Int
  public let isEnabled: Bool
  /// The tester's description matches this rule first.
  public let isMatch: Bool

  /// "Description contains “lidl” → Food › Groceries".
  public var summary: String { "\(condition) → \(action)" }
}

/// The kind of a rule's first condition row (TA v1.6): a description or an amount condition.
public enum RuleFirstCondition: Hashable, Sendable, CaseIterable {
  case descriptionContains, descriptionExactly, amountBiggerThan, amountSmallerThan

  public var isDescription: Bool { self == .descriptionContains || self == .descriptionExactly }
}

/// The rule editor sheet (new or existing rule), laid out like Saldo's (D44): a condition card
/// (a description and/or an amount condition, optionally an account), an action card, "Update
/// existing transactions".
public struct RuleDraft: Equatable, Sendable {
  public let id: CategoryRule.ID
  public let isNew: Bool
  /// The description condition (TA v1.6: optional when there is an amount condition).
  public var hasDescriptionCondition: Bool
  public var matchKind: RuleMatchKind
  public var pattern: String
  public var hasAmountCondition: Bool
  public var amountComparison: RuleAmountComparison
  public var amountText: String
  /// "+ Add AND condition" → Account.
  public var hasAccountCondition: Bool
  public var accountID: Account.ID?
  public var action: RuleAction
  public var categoryID: AbacusDomain.Category.ID?
  public var transferAccountID: Account.ID?
  /// Apply the rule to matching existing transactions on save (R-MGMT-6).
  public var updateExisting: Bool

  public init(
    id: CategoryRule.ID = UUID(), isNew: Bool = true, hasDescriptionCondition: Bool = true,
    matchKind: RuleMatchKind = .contains, pattern: String = "",
    hasAmountCondition: Bool = false, amountComparison: RuleAmountComparison = .biggerThan, amountText: String = "",
    hasAccountCondition: Bool = false, accountID: Account.ID? = nil, action: RuleAction = .category,
    categoryID: AbacusDomain.Category.ID? = nil, transferAccountID: Account.ID? = nil, updateExisting: Bool = false
  ) {
    self.id = id
    self.isNew = isNew
    self.hasDescriptionCondition = hasDescriptionCondition
    self.matchKind = matchKind
    self.pattern = pattern
    self.hasAmountCondition = hasAmountCondition
    self.amountComparison = amountComparison
    self.amountText = amountText
    self.hasAccountCondition = hasAccountCondition
    self.accountID = accountID
    self.action = action
    self.categoryID = categoryID
    self.transferAccountID = transferAccountID
    self.updateExisting = updateExisting
  }

  /// "+ Add AND condition" has something left to add (at most one of each kind).
  public var canAddCondition: Bool { !hasDescriptionCondition || !hasAmountCondition || !hasAccountCondition }

  /// A description or amount condition can be removed only while the other one stays.
  public var canRemoveDescription: Bool { hasDescriptionCondition && hasAmountCondition }
  public var canRemoveAmount: Bool { hasDescriptionCondition && hasAmountCondition }

  /// The first condition row: the description condition when there is one, else the amount
  /// condition. Setting it switches that row's kind; with only one of the two conditions it can
  /// turn a description row into an amount row and back (the text / amount are kept).
  public var firstCondition: RuleFirstCondition {
    get {
      if hasDescriptionCondition { return matchKind == .exactly ? .descriptionExactly : .descriptionContains }
      return amountComparison == .smallerThan ? .amountSmallerThan : .amountBiggerThan
    }
    set {
      switch newValue {
      case .descriptionContains, .descriptionExactly:
        matchKind = newValue == .descriptionExactly ? .exactly : .contains
        if !hasDescriptionCondition {
          hasDescriptionCondition = true
          hasAmountCondition = false
        }
      case .amountBiggerThan, .amountSmallerThan:
        amountComparison = newValue == .amountSmallerThan ? .smallerThan : .biggerThan
        if hasDescriptionCondition, !hasAmountCondition {
          hasDescriptionCondition = false
          hasAmountCondition = true
        }
      }
    }
  }

  /// The kinds the first row may switch to: both kinds while it is the only description/amount
  /// condition, otherwise only its own kind.
  public var firstConditionChoices: [RuleFirstCondition] {
    if hasDescriptionCondition && hasAmountCondition { return [.descriptionContains, .descriptionExactly] }
    return RuleFirstCondition.allCases
  }
}

/// Saving with "Update existing transactions" waits for this confirmation.
public struct RuleApplyConfirmation: Equatable, Sendable {
  public let rule: CategoryRule
  /// What changes on each transaction (before/after), recorded for rollback.
  public let records: [RuleApplication]
  public let title: String
  public let message: String

  /// The transactions as the rule leaves them.
  public var changedCount: Int { records.count }
}

/// "Roll back" in the editor waits for this confirmation.
public struct RuleRollbackConfirmation: Equatable, Sendable {
  public let ruleID: CategoryRule.ID
  public let title: String
  public let message: String
}

/// The banner after "Save & apply" or "Roll back"; `rollbackRuleID` offers "Roll back" at once.
public struct RuleApplyNotice: Equatable, Sendable {
  public let message: String
  /// Set after an apply: the banner's "Roll back" rolls that rule back.
  public let rollbackRuleID: CategoryRule.ID?

  public init(message: String, rollbackRuleID: CategoryRule.ID?) {
    self.message = message
    self.rollbackRuleID = rollbackRuleID
  }
}

/// The Rules screen (approved prototype group 4, R-MGMT-6, R-MGMT-11, R-IMP-8, D44): page
/// search and a category filter, a tester highlighting the first matching rule, the rules in
/// evaluation order and in words with enable toggles, origin and hit counts; create, edit
/// (Saldo-like editor), reorder, delete; "Update existing transactions" with a confirmation
/// showing how many change, recorded so the rule can be rolled back later (TA v1.6).
@MainActor
@Observable
public final class RulesModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var rules: [CategoryRule] = []
  public private(set) var accounts: [Account] = []
  public private(set) var categories: [AbacusDomain.Category] = []
  /// Page search (R-MGMT-11): the rule in words (condition and action).
  public var searchText = ""
  /// Only rules assigning this category or one of its subcategories (R-MGMT-11); nil = all.
  public var categoryFilter: AbacusDomain.Category.ID?
  /// "Try a description".
  public var probe = ""
  /// The tester's account; nil = any account.
  public var probeAccountID: Account.ID?
  /// The tester's amount (optional; amount conditions fail without one).
  public var probeAmountText = ""
  public var selection: CategoryRule.ID?
  /// The editor sheet; nil when closed.
  public var editor: RuleDraft?
  /// Every transaction, loaded when the editor opens (the "will change" count).
  public private(set) var editorTransactions: [TxnWithLines]?
  /// What the edited rule changed on existing transactions and can roll back (newest first).
  public private(set) var editorApplications: [RuleApplication] = []
  /// "Save & apply" waiting for confirmation (shown over the editor).
  public private(set) var confirmation: RuleApplyConfirmation?
  /// "Roll back" waiting for confirmation (shown over the editor).
  public private(set) var rollbackConfirmation: RuleRollbackConfirmation?
  public private(set) var notice: RuleApplyNotice?
  public private(set) var dialog: ManageDialog?
  public private(set) var errorMessage: String?

  /// Transactions changed (apply, roll back): the list, dashboard and balances re-read.
  @ObservationIgnored public var onTransactionsChange: (@MainActor () async -> Void)?
  @ObservationIgnored public let dependencies: ManageDependencies

  public init(dependencies: ManageDependencies, probe: String = "") {
    self.dependencies = dependencies
    self.probe = probe
  }

  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      rules = try await dependencies.rules.rules()
      accounts = try await dependencies.accounts.accounts(includeArchived: true)
      categories = try await dependencies.categories.categories(kind: nil, includeArchived: true)
      if let selection, !rules.contains(where: { $0.id == selection }) { self.selection = nil }
      if let categoryFilter, !categories.contains(where: { $0.id == categoryFilter }) { self.categoryFilter = nil }
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load rules: \(error.localizedDescription)")
    }
  }

  // MARK: Tester

  public var probeAmountMinor: Int64? {
    dependencies.format.parseAmount(probeAmountText).map(abs)
  }

  public var match: CategoryRule? {
    // Same matching as imports and the editor (AbacusImport.RuleMatcher), in rule order.
    rules.first {
      RuleMatcher.matches(
        $0, description: probe, accountID: probeAccountID, amountMinor: probeAmountMinor, categories: categories,
        accounts: accounts)
    }
  }

  /// "Matches “biedronka” → Food › Groceries" / "No rule matches; the category stays empty for
  /// you to pick." / "" without a description or amount.
  public var probeResult: String {
    if let match { return "Matches “\(match.label)” → \(actionText(match))" }
    return probe.trimmingCharacters(in: .whitespaces).isEmpty && probeAmountMinor == nil
      ? "" : "No rule matches; the category stays empty for you to pick."
  }

  // MARK: Rows

  private var tree: CategoryTree { CategoryTree(categories) }

  private func accountName(_ id: Account.ID?) -> String {
    id.map { id in accounts.first { $0.id == id }?.name ?? "Unknown account" } ?? "Any account"
  }

  /// "Description contains “lidl” and amount bigger than 100.00 on PKO Personal" /
  /// "Amount bigger than 500.00" (amount-only).
  public func conditionText(_ rule: CategoryRule) -> String {
    var parts: [String] = []
    if rule.hasDescriptionCondition {
      parts.append(
        rule.matchKind == .exactly ? "Description is exactly “\(rule.pattern)”" : "Description contains “\(rule.pattern)”")
    }
    if let comparison = rule.amountComparison, let amount = rule.amountMinor {
      let word = comparison == .biggerThan ? "bigger" : "smaller"
      parts.append("\(parts.isEmpty ? "Amount" : "amount") \(word) than \(dependencies.format.amountInput(amount))")
    }
    var text = parts.joined(separator: " and ")
    if let accountID = rule.accountID { text += " on \(accountName(accountID))" }
    return text
  }

  /// "Food › Groceries" / "Transfer to/from Loan from friend".
  public func actionText(_ rule: CategoryRule) -> String {
    switch rule.action {
    case .category:
      return rule.categoryID.map { ManageText.categoryPath($0, tree: tree) } ?? "No category"
    case .transfer:
      return "Transfer to/from \(rule.transferAccountID.map(accountName) ?? "no account")"
    }
  }

  /// Search or category filter on: the list shows a subset, so dragging is off.
  public var isFiltered: Bool {
    !searchText.trimmingCharacters(in: .whitespaces).isEmpty || categoryFilter != nil
  }

  /// The rules the search and the category filter leave, in evaluation order.
  public var visibleRules: [CategoryRule] {
    let query = RulePattern.normalized(searchText)
    let filterIDs: Set<AbacusDomain.Category.ID>? = categoryFilter.map { id in
      Set([id] + tree.children(of: id).map(\.id))
    }
    return rules.filter { rule in
      if let filterIDs {
        guard rule.action == .category, let id = rule.categoryID, filterIDs.contains(id) else { return false }
      }
      guard !query.isEmpty else { return true }
      return RulePattern.normalized("\(conditionText(rule)) \(actionText(rule))").contains(query)
    }
  }

  public var rows: [RuleRow] {
    let matchID = match?.id
    return visibleRules.map { rule in
      RuleRow(
        id: rule.id, pattern: rule.label, condition: conditionText(rule), action: actionText(rule),
        origin: rule.origin == .imported ? "Learned from an import" : "Manual", hits: rule.hitCount,
        isEnabled: rule.isEnabled, isMatch: rule.id == matchID)
    }
  }

  /// "No rules match the search." when the filters hide every rule.
  public var emptyText: String {
    if rules.isEmpty { return "No rules yet. Choices you make during an import are saved here." }
    return "No rules match the search or the category."
  }

  public func setEnabled(_ id: CategoryRule.ID, _ enabled: Bool) async {
    guard var rule = rules.first(where: { $0.id == id }), rule.isEnabled != enabled else { return }
    rule.isEnabled = enabled
    await persist([rule], doing: enabled ? "enable the rule" : "disable the rule")
  }

  /// Drag to change the order (first match wins): positions are renumbered. Offsets are in the
  /// full list; the view only allows dragging while no filter is on.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
    guard !isFiltered else { return }
    var ordered = rules
    ordered.move(fromOffsets: source, toOffset: destination)
    var changed: [CategoryRule] = []
    for (position, rule) in ordered.enumerated() where rule.position != position {
      var updated = rule
      updated.position = position
      changed.append(updated)
    }
    rules = ordered.enumerated().map { position, rule in
      var rule = rule
      rule.position = position
      return rule
    }
    await persist(changed, doing: "move the rule")
  }

  private func persist(_ changed: [CategoryRule], doing action: String) async {
    notice = nil
    do {
      for rule in changed { try await dependencies.rules.save(rule) }
      errorMessage = nil
    } catch {
      errorMessage = ManageFailure.message(error, doing: action)
    }
    await load()
  }

  // MARK: Pickers

  /// Categories A–Z (TA v1.6): expense then income, top-level categories A–Z, each followed by
  /// its subcategories A–Z; archived ones only when `including` names them.
  private func categoriesAZ(including kept: Set<AbacusDomain.Category.ID> = []) -> [AbacusDomain.Category] {
    let byName: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return CategoryKind.allCases.flatMap { kind -> [AbacusDomain.Category] in
      let ofKind = categories.filter { $0.kind == kind && (!$0.isArchived || kept.contains($0.id)) }
      let ids = Set(ofKind.map(\.id))
      return ofKind.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: byName).flatMap { parent in
        [parent] + ofKind.filter { $0.parentID == parent.id }.sorted(by: byName)
      }
    }
  }

  /// The editor's category choices: non-archived categories A–Z.
  public var categoryOptions: [AbacusDomain.Category] { categoriesAZ() }

  /// The page's category filter: categories A–Z, archived ones too when a rule uses them.
  public var categoryFilterOptions: [AbacusDomain.Category] {
    categoriesAZ(including: Set(rules.compactMap(\.categoryID)))
  }

  public var accountOptions: [Account] {
    accounts.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // MARK: Editor

  /// "New rule": the tester's text as the pattern when no rule matches it.
  public func newRule() {
    let text = match == nil ? probe.trimmingCharacters(in: .whitespaces).lowercased() : ""
    open(RuleDraft(pattern: text))
  }

  public func edit(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    selection = id
    let hasAmount = rule.hasAmountCondition
    open(RuleDraft(
      id: rule.id, isNew: false, hasDescriptionCondition: rule.hasDescriptionCondition || !hasAmount,
      matchKind: rule.matchKind, pattern: rule.pattern, hasAmountCondition: hasAmount,
      amountComparison: rule.amountComparison ?? .biggerThan,
      amountText: hasAmount ? rule.amountMinor.map(dependencies.format.amountInput) ?? "" : "",
      hasAccountCondition: rule.accountID != nil, accountID: rule.accountID, action: rule.action,
      categoryID: rule.categoryID, transferAccountID: rule.transferAccountID))
  }

  private func open(_ draft: RuleDraft) {
    editor = draft
    confirmation = nil
    rollbackConfirmation = nil
    editorTransactions = nil
    editorApplications = []
    Task {
      await loadEditorTransactions()
      if !draft.isNew { await loadEditorApplications() }
    }
  }

  /// Loads every transaction for the "will change" count (each time the editor opens). Debt
  /// legs are left out: rules never change them (R-DEBT-3, they follow their record).
  public func loadEditorTransactions() async {
    editorTransactions = try? await dependencies.allTransactions().filter { $0.txn.debtRecordID == nil }
  }

  /// Loads what the edited rule changed before (the editor's "Roll back").
  public func loadEditorApplications() async {
    guard let editor, !editor.isNew else {
      editorApplications = []
      return
    }
    editorApplications = (try? await dependencies.rules.applications(of: editor.id)) ?? []
  }

  /// "Add AND condition" items.
  public func addDescriptionCondition() {
    editor?.hasDescriptionCondition = true
  }

  public func addAmountCondition() {
    editor?.hasAmountCondition = true
  }

  public func addAccountCondition() {
    editor?.hasAccountCondition = true
  }

  /// Removing keeps at least one description or amount condition.
  public func removeDescriptionCondition() {
    guard editor?.canRemoveDescription == true else { return }
    editor?.hasDescriptionCondition = false
  }

  public func removeAmountCondition() {
    guard editor?.canRemoveAmount == true else { return }
    editor?.hasAmountCondition = false
  }

  public func removeAccountCondition() {
    editor?.hasAccountCondition = false
    editor?.accountID = nil
  }

  public var editorValidation: String? {
    guard let editor else { return nil }
    if !editor.hasDescriptionCondition && !editor.hasAmountCondition {
      return "Add a description or an amount condition."
    }
    if editor.hasDescriptionCondition, editor.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
      return "Enter the description text."
    }
    if editor.hasAmountCondition, editorAmountMinor == nil { return "Enter the amount." }
    if editor.hasAccountCondition, editor.accountID == nil { return "Choose the account." }
    switch editor.action {
    case .category:
      if editor.categoryID == nil { return "Choose a category." }
    case .transfer:
      guard let target = editor.transferAccountID else { return "Choose the account to transfer to or from." }
      if editor.hasAccountCondition, editor.accountID == target {
        return "The transfer account must differ from the account in the condition."
      }
    }
    return nil
  }

  private var editorAmountMinor: Int64? {
    guard let editor, let amount = dependencies.format.parseAmount(editor.amountText) else { return nil }
    return amount > 0 ? amount : nil
  }

  /// The rule the editor would save (nil while invalid): a new rule goes last as a manual rule;
  /// an edit keeps origin, hits, position and enabled state. No description condition = empty
  /// pattern.
  public var editorRule: CategoryRule? {
    guard let editor, editorValidation == nil else { return nil }
    var rule =
      rules.first { $0.id == editor.id }
      ?? CategoryRule(id: editor.id, pattern: "", origin: .manual, position: (rules.map(\.position).max() ?? -1) + 1)
    rule.pattern = editor.hasDescriptionCondition ? editor.pattern.trimmingCharacters(in: .whitespaces) : ""
    rule.matchKind = editor.hasDescriptionCondition ? editor.matchKind : .contains
    rule.amountComparison = editor.hasAmountCondition ? editor.amountComparison : nil
    rule.amountMinor = editor.hasAmountCondition ? editorAmountMinor : nil
    rule.accountID = editor.hasAccountCondition ? editor.accountID : nil
    rule.action = editor.action
    rule.categoryID = editor.action == .category ? editor.categoryID : nil
    rule.transferAccountID = editor.action == .transfer ? editor.transferAccountID : nil
    return rule
  }

  /// The existing transactions the editor's rule would change (nil while loading or invalid).
  public var editorChanges: [Txn]? {
    guard let rule = editorRule, let editorTransactions else { return nil }
    return RuleEffect.changes(rule, in: editorTransactions, accounts: accounts, categories: categories)
  }

  /// "Update existing transactions" caption: "3 transactions will change" / "No existing
  /// transactions match".
  public var editorChangesText: String? {
    guard let changes = editorChanges else { return nil }
    return changes.isEmpty ? "No existing transaction would change" : "\(ManageText.transactions(changes.count)) will change"
  }

  /// "Changed 3 transactions (last on 27 Oct 2026)." while the rule can be rolled back.
  public var editorRollbackText: String? {
    guard let latest = editorApplications.first else { return nil }
    let count = Set(editorApplications.map(\.txnID)).count
    let day = dependencies.format.day(Day(latest.appliedAt, calendar: dependencies.format.calendar))
    return "Applied to \(ManageText.transactions(count)) (last on \(day))."
  }

  public func cancelEditor() {
    editor = nil
    confirmation = nil
    rollbackConfirmation = nil
  }

  /// Saves the editor. With "Update existing transactions" and something to change it asks for
  /// confirmation first (`confirmation`), the save then happens in `confirmApply(_:)`.
  public func saveEditor() async {
    guard let editor, let rule = editorRule else { return }
    if editor.updateExisting {
      if editorTransactions == nil { await loadEditorTransactions() }
      let changes = editorChanges ?? []
      if !changes.isEmpty {
        let records = RuleApplication.records(
          ruleID: rule.id, originals: (editorTransactions ?? []).map(\.txn), changes: changes)
        let them = changes.count == 1 ? "It" : "They"
        var message = "\(ManageText.transactions(changes.count)) \(changes.count == 1 ? "matches" : "match") “\(conditionText(rule))”. "
        switch rule.action {
        case .category: message += "\(them) will be categorised as \(actionText(rule)). "
        case .transfer:
          let name = rule.transferAccountID.map(accountName) ?? ""
          message += "\(them) will become \(changes.count == 1 ? "a transfer" : "transfers") to or from \(name). "
        }
        message += "Transfers are never changed. You can roll this back later in the rule's editor."
        confirmation = RuleApplyConfirmation(
          rule: rule, records: records, title: "Update \(ManageText.transactions(changes.count))?", message: message)
        return
      }
    }
    self.editor = nil
    selection = rule.id
    await persist([rule], doing: "save the rule")
  }

  /// The alert closed without applying (Cancel, Esc, or SwiftUI clearing its binding).
  public func cancelConfirmation() { confirmation = nil }

  /// The confirmation's "Save & apply": saves the rule and the changed transactions and records
  /// the change for rollback, in one database transaction. Takes the confirmation the alert
  /// showed: SwiftUI clears the alert's binding (→ `cancelConfirmation()`) before a `Task`
  /// started by the button runs, so reading `confirmation` here would find nil (C9 bug: "Save &
  /// apply" did nothing).
  public func confirmApply(_ confirmation: RuleApplyConfirmation) async {
    if self.confirmation == confirmation { self.confirmation = nil }
    editor = nil
    selection = confirmation.rule.id
    do {
      try await dependencies.rules.apply(confirmation.rule, records: confirmation.records)
      errorMessage = nil
      notice = RuleApplyNotice(
        message: "\(ManageText.transactions(confirmation.changedCount)) updated by the rule “\(confirmation.rule.label)”.",
        rollbackRuleID: confirmation.rule.id)
    } catch {
      errorMessage = ManageFailure.message(error, doing: "apply the rule")
    }
    editorTransactions = nil
    await load()
    await onTransactionsChange?()
  }

  // MARK: Roll back

  /// The editor's "Roll back…": asks first.
  public func requestRollback() {
    guard let editor, !editor.isNew, !editorApplications.isEmpty else { return }
    let count = Set(editorApplications.map(\.txnID)).count
    rollbackConfirmation = RuleRollbackConfirmation(
      ruleID: editor.id, title: "Roll back \(ManageText.transactions(count))?",
      message: "They get back the category, type and accounts they had before this rule changed them. "
        + "Transactions you have edited since stay as they are. The rule itself is kept.")
  }

  public func cancelRollback() { rollbackConfirmation = nil }

  /// Rolls the rule back (the editor's confirmation or the banner after an apply) and closes
  /// the editor.
  public func rollBack(_ ruleID: CategoryRule.ID) async {
    rollbackConfirmation = nil
    if editor?.id == ruleID { editor = nil }
    do {
      let result = try await dependencies.rules.rollBack(ruleID)
      errorMessage = nil
      var message = "\(ManageText.transactions(result.restored)) restored."
      if result.skipped > 0 {
        message += " \(ManageText.transactions(result.skipped)) edited since \(result.skipped == 1 ? "was" : "were") left as \(result.skipped == 1 ? "it is" : "they are")."
      }
      notice = RuleApplyNotice(message: message, rollbackRuleID: nil)
    } catch {
      errorMessage = ManageFailure.message(error, doing: "roll back the rule")
    }
    editorTransactions = nil
    editorApplications = []
    await load()
    await onTransactionsChange?()
  }

  public func dismissNotice() { notice = nil }

  // MARK: Delete

  public func requestDelete(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    dialog = ManageDialog(
      action: .deleteRule(id), title: "Delete the rule “\(rule.label)”?",
      message: "“\(conditionText(rule)) → \(actionText(rule))” no longer applies to new transactions. Transactions it changed stay as they are and can no longer be rolled back.",
      confirmTitle: "Delete", isDestructive: true)
  }

  /// "Delete" in the editor's header (after the editor's own confirmation).
  public func deleteEditorRule() async {
    guard let editor, !editor.isNew else { return }
    cancelEditor()
    await delete(editor.id)
  }

  public func cancelDialog() { dialog = nil }

  public func confirmDialog() async {
    guard let dialog, case .deleteRule(let id) = dialog.action else { return }
    self.dialog = nil
    await delete(id)
  }

  private func delete(_ id: CategoryRule.ID) async {
    notice = nil
    do {
      try await dependencies.rules.delete(id)
      if selection == id { selection = nil }
      errorMessage = nil
    } catch {
      errorMessage = ManageFailure.message(error, doing: "delete the rule")
    }
    await load()
  }
}
