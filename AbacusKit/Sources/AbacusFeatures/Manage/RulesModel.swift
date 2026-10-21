import AbacusDomain
import AbacusImport
import Foundation
import Observation

/// One rule row: enable toggle, pattern, account, category, origin, hit count.
public struct RuleRow: Identifiable, Equatable, Sendable {
  public let id: CategoryRule.ID
  public let pattern: String
  /// "Any account" or the account's name.
  public let account: String
  /// "Food › Groceries".
  public let category: String
  /// "Learned from an import" / "Manual".
  public let origin: String
  public let hits: Int
  public let isEnabled: Bool
  /// The tester's description matches this rule first.
  public let isMatch: Bool
}

/// The rule editor sheet (new or existing rule).
public struct RuleDraft: Equatable, Sendable {
  public let id: CategoryRule.ID
  public let isNew: Bool
  public var pattern: String
  public var accountID: Account.ID?
  public var categoryID: AbacusDomain.Category.ID?
}

/// The Rules screen (approved prototype group 4, R-MGMT-6, R-IMP-8): a "Try a description"
/// tester highlighting the first matching rule, the rules in evaluation order with enable
/// toggles, origin and hit counts; create, edit, reorder and delete.
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
  public var selection: CategoryRule.ID?
  /// The editor sheet; nil when closed.
  public var editor: RuleDraft?
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

  public var match: CategoryRule? {
    // Same matching as imports and the editor (AbacusImport.RuleMatcher), in rule order.
    rules.first { RuleMatcher.matches($0, description: probe, accountID: probeAccountID, categories: categories) }
  }

  /// "Matches “biedronka” → Food › Groceries" / "No rule matches; the category stays empty for
  /// you to pick." / "" without a description.
  public var probeResult: String {
    if let match { return "Matches “\(match.pattern)” → \(categoryText(match.categoryID))" }
    return probe.trimmingCharacters(in: .whitespaces).isEmpty
      ? "" : "No rule matches; the category stays empty for you to pick."
  }

  // MARK: Rows

  private var tree: CategoryTree { CategoryTree(categories) }

  private func categoryText(_ id: AbacusDomain.Category.ID) -> String {
    ManageText.categoryPath(id, tree: tree)
  }

  public var rows: [RuleRow] {
    let matchID = match?.id
    return rules.map { rule in
      RuleRow(
        id: rule.id, pattern: rule.pattern,
        account: rule.accountID.map { id in accounts.first { $0.id == id }?.name ?? "Unknown account" } ?? "Any account",
        category: categoryText(rule.categoryID),
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
    editor = RuleDraft(id: UUID(), isNew: true, pattern: text, accountID: nil, categoryID: nil)
  }

  public func edit(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    selection = id
    editor = RuleDraft(id: rule.id, isNew: false, pattern: rule.pattern, accountID: rule.accountID, categoryID: rule.categoryID)
  }

  public var editorValidation: String? {
    guard let editor else { return nil }
    if editor.pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the text the description contains." }
    if editor.categoryID == nil { return "Choose a category." }
    return nil
  }

  public func cancelEditor() { editor = nil }

  /// Saves the editor: a new rule goes last as a manual rule; an edit keeps origin and hits.
  public func saveEditor() async {
    guard let editor, editorValidation == nil, let categoryID = editor.categoryID else { return }
    var rule =
      rules.first { $0.id == editor.id }
      ?? CategoryRule(
        id: editor.id, pattern: "", categoryID: categoryID, origin: .manual,
        position: (rules.map(\.position).max() ?? -1) + 1)
    rule.pattern = editor.pattern.trimmingCharacters(in: .whitespaces)
    rule.accountID = editor.accountID
    rule.categoryID = categoryID
    self.editor = nil
    selection = rule.id
    await persist([rule], doing: "save the rule")
  }

  // MARK: Delete

  public func requestDelete(_ id: CategoryRule.ID) {
    guard let rule = rules.first(where: { $0.id == id }) else { return }
    dialog = ManageDialog(
      action: .deleteRule(id), title: "Delete the rule “\(rule.pattern)”?",
      message: "Descriptions containing “\(rule.pattern)” are no longer given \(categoryText(rule.categoryID)) automatically.",
      confirmTitle: "Delete", isDestructive: true)
  }

  public func cancelDialog() { dialog = nil }

  public func confirmDialog() async {
    guard let dialog, case .deleteRule(let id) = dialog.action else { return }
    self.dialog = nil
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
