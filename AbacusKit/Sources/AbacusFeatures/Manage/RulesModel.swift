import AbacusDomain
import AbacusImport
import Foundation
import Observation

/// One rule row: enable toggle, the rule in words, origin, hit count.
public struct RuleRow: Identifiable, Equatable, Sendable {
  public let id: CategoryRule.ID
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

/// The rule editor sheet (new or existing rule), laid out like Saldo's (D44): a condition card
/// (description condition, then optional AND conditions), an action card, "Update existing
/// transactions".
public struct RuleDraft: Equatable, Sendable {
  public let id: CategoryRule.ID
  public let isNew: Bool
  public var matchKind: RuleMatchKind
  public var pattern: String
  /// "+ Add AND condition" → Amount.
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
    id: CategoryRule.ID = UUID(), isNew: Bool = true, matchKind: RuleMatchKind = .contains, pattern: String = "",
    hasAmountCondition: Bool = false, amountComparison: RuleAmountComparison = .biggerThan, amountText: String = "",
    hasAccountCondition: Bool = false, accountID: Account.ID? = nil, action: RuleAction = .category,
    categoryID: AbacusDomain.Category.ID? = nil, transferAccountID: Account.ID? = nil, updateExisting: Bool = false
  ) {
    self.id = id
    self.isNew = isNew
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

  public var canAddCondition: Bool { !hasAmountCondition || !hasAccountCondition }
}

/// Saving with "Update existing transactions" waits for this confirmation.
public struct RuleApplyConfirmation: Equatable, Sendable {
  public let rule: CategoryRule
  /// The transactions as the rule leaves them.
  public let changes: [Txn]
  /// The same transactions as they are now (undo).
  public let originals: [Txn]
  public let title: String
  public let message: String
}

/// The last "Save & apply", until another change: "Undo" restores the transactions and the rule.
public struct RuleApplyUndo: Equatable, Sendable {
  public let ruleID: CategoryRule.ID
  /// The rule before the save; nil when it was new (undo deletes it).
  public let previousRule: CategoryRule?
  public let originals: [Txn]
  /// "12 transactions updated by the rule."
  public let message: String
}

/// The Rules screen (approved prototype group 4, R-MGMT-6, R-IMP-8, D44): a tester highlighting
/// the first matching rule, the rules in evaluation order and in words with enable toggles,
/// origin and hit counts; create, edit (Saldo-like editor), reorder, delete; "Update existing
/// transactions" with a confirmation showing how many change, and Undo afterwards.
@MainActor
@Observable
public final class RulesModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var rules: [CategoryRule] = []
  public private(set) var accounts: [Account] = []
  public private(set) var categories: [AbacusDomain.Category] = []
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
  /// "Save & apply" waiting for confirmation (shown over the editor).
  public private(set) var confirmation: RuleApplyConfirmation?
  public private(set) var lastApply: RuleApplyUndo?
  public private(set) var dialog: ManageDialog?
  public private(set) var errorMessage: String?

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
  /// you to pick." / "" without a description.
  public var probeResult: String {
    if let match { return "Matches “\(match.pattern)” → \(actionText(match))" }
    return probe.trimmingCharacters(in: .whitespaces).isEmpty
      ? "" : "No rule matches; the category stays empty for you to pick."
  }

  // MARK: Rows

  private var tree: CategoryTree { CategoryTree(categories) }

  private func accountName(_ id: Account.ID?) -> String {
    id.map { id in accounts.first { $0.id == id }?.name ?? "Unknown account" } ?? "Any account"
  }

  /// "Description contains “lidl” and amount bigger than 100.00 on PKO Personal".
  public func conditionText(_ rule: CategoryRule) -> String {
    var text = rule.matchKind == .exactly
      ? "Description is exactly “\(rule.pattern)”" : "Description contains “\(rule.pattern)”"
    if let comparison = rule.amountComparison, let amount = rule.amountMinor {
      let word = comparison == .biggerThan ? "bigger" : "smaller"
      text += " and amount \(word) than \(dependencies.format.amountInput(amount))"
    }
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

  public var rows: [RuleRow] {
    let matchID = match?.id
    return rules.map { rule in
      RuleRow(
        id: rule.id, pattern: rule.pattern, condition: conditionText(rule), action: actionText(rule),
        origin: rule.origin == .imported ? "Learned from an import" : "Manual", hits: rule.hitCount,
        isEnabled: rule.isEnabled, isMatch: rule.id == matchID)
    }
  }

  public func setEnabled(_ id: CategoryRule.ID, _ enabled: Bool) async {
    guard var rule = rules.first(where: { $0.id == id }), rule.isEnabled != enabled else { return }
    rule.isEnabled = enabled
    await persist([rule], doing: enabled ? "enable the rule" : "disable the rule")
  }

  /// Drag to change the order (first match wins): positions are renumbered.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
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
    lastApply = nil
    do {
      for rule in changed { try await dependencies.rules.save(rule) }
      errorMessage = nil
    } catch {
      errorMessage = ManageFailure.message(error, doing: action)
    }
    await load()
  }

  // MARK: Editor

  /// Category choices: non-archived categories in tree order, expense first.
  public var categoryOptions: [AbacusDomain.Category] {
    CategoryKind.allCases.flatMap { kind -> [AbacusDomain.Category] in
      let ofKind = categories.filter { $0.kind == kind && !$0.isArchived }
      let ids = Set(ofKind.map(\.id))
      let byOrder: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = { ($0.position, $0.name) < ($1.position, $1.name) }
      return ofKind.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: byOrder).flatMap { parent in
        [parent] + ofKind.filter { $0.parentID == parent.id }.sorted(by: byOrder)
      }
    }
  }

  public var accountOptions: [Account] { accounts.filter { !$0.isArchived } }

  /// "New rule": the tester's text as the pattern when no rule matches it.
  public func newRule() {
    let text = match == nil ? probe.trimmingCharacters(in: .whitespaces).lowercased() : ""
    open(RuleDraft(pattern: text))
  }

  public func edit(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    selection = id
    let hasAmount = rule.amountComparison != nil && rule.amountMinor != nil
    open(RuleDraft(
      id: rule.id, isNew: false, matchKind: rule.matchKind, pattern: rule.pattern, hasAmountCondition: hasAmount,
      amountComparison: rule.amountComparison ?? .biggerThan,
      amountText: hasAmount ? rule.amountMinor.map(dependencies.format.amountInput) ?? "" : "",
      hasAccountCondition: rule.accountID != nil, accountID: rule.accountID, action: rule.action,
      categoryID: rule.categoryID, transferAccountID: rule.transferAccountID))
  }

  private func open(_ draft: RuleDraft) {
    editor = draft
    confirmation = nil
    editorTransactions = nil
    Task { await loadEditorTransactions() }
  }

  /// Loads every transaction for the "will change" count (each time the editor opens).
  public func loadEditorTransactions() async {
    editorTransactions = try? await dependencies.allTransactions()
  }

  public var editorValidation: String? {
    guard let editor else { return nil }
    if editor.pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the description text." }
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
  /// an edit keeps origin, hits, position and enabled state.
  public var editorRule: CategoryRule? {
    guard let editor, editorValidation == nil else { return nil }
    var rule =
      rules.first { $0.id == editor.id }
      ?? CategoryRule(id: editor.id, pattern: "", origin: .manual, position: (rules.map(\.position).max() ?? -1) + 1)
    rule.pattern = editor.pattern.trimmingCharacters(in: .whitespaces)
    rule.matchKind = editor.matchKind
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

  public func cancelEditor() {
    editor = nil
    confirmation = nil
  }

  /// Saves the editor. With "Update existing transactions" and something to change it asks for
  /// confirmation first (`confirmation`), the save then happens in `confirmApply()`.
  public func saveEditor() async {
    guard let editor, let rule = editorRule else { return }
    if editor.updateExisting {
      if editorTransactions == nil { await loadEditorTransactions() }
      let changes = editorChanges ?? []
      if !changes.isEmpty {
        let originalsByID = Dictionary(
          (editorTransactions ?? []).map { ($0.txn.id, $0.txn) }, uniquingKeysWith: { first, _ in first })
        let them = changes.count == 1 ? "It" : "They"
        var message = "\(ManageText.transactions(changes.count)) \(changes.count == 1 ? "matches" : "match") “\(conditionText(rule))”. "
        switch rule.action {
        case .category: message += "\(them) will be categorised as \(actionText(rule)). "
        case .transfer:
          let name = rule.transferAccountID.map(accountName) ?? ""
          message += "\(them) will become \(changes.count == 1 ? "a transfer" : "transfers") to or from \(name). "
        }
        message += "Transfers are never changed. You can undo this right after."
        confirmation = RuleApplyConfirmation(
          rule: rule, changes: changes, originals: changes.compactMap { originalsByID[$0.id] },
          title: "Update \(ManageText.transactions(changes.count))?", message: message)
        return
      }
    }
    self.editor = nil
    selection = rule.id
    await persist([rule], doing: "save the rule")
  }

  public func cancelConfirmation() { confirmation = nil }

  /// Saves the rule and the changed transactions in one database transaction; keeps Undo.
  public func confirmApply() async {
    guard let confirmation else { return }
    let previous = rules.first { $0.id == confirmation.rule.id }
    self.confirmation = nil
    editor = nil
    selection = confirmation.rule.id
    do {
      try await dependencies.rules.save(confirmation.rule, updating: confirmation.changes)
      errorMessage = nil
      lastApply = RuleApplyUndo(
        ruleID: confirmation.rule.id, previousRule: previous, originals: confirmation.originals,
        message: "\(ManageText.transactions(confirmation.changes.count)) updated by the rule.")
    } catch {
      errorMessage = ManageFailure.message(error, doing: "apply the rule")
    }
    editorTransactions = nil
    await load()
  }

  /// Restores the transactions and the rule of the last "Save & apply".
  public func undoLastApply() async {
    guard let undo = lastApply else { return }
    lastApply = nil
    do {
      try await dependencies.rules.save(undo.previousRule, updating: undo.originals)
      if undo.previousRule == nil { try await dependencies.rules.delete(undo.ruleID) }
      errorMessage = nil
    } catch {
      errorMessage = ManageFailure.message(error, doing: "undo")
    }
    editorTransactions = nil
    await load()
  }

  public func dismissUndo() { lastApply = nil }

  // MARK: Delete

  public func requestDelete(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    dialog = ManageDialog(
      action: .deleteRule(id), title: "Delete the rule “\(rule.pattern)”?",
      message: "“\(conditionText(rule)) → \(actionText(rule))” no longer applies to new transactions. Transactions it changed stay as they are.",
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
    lastApply = nil
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
