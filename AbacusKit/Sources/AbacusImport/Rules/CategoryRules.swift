import AbacusDomain
import Foundation

/// Applies categorisation rules (R-IMP-8, R-EDIT-3): "description contains `pattern` →
/// category", case-insensitive, optionally limited to one account. The first matching rule in
/// the given order wins (`RuleRepository.rules()` returns them in evaluation order).
public struct RuleMatcher: Sendable {
  public let rules: [CategoryRule]
  private let kinds: [AbacusDomain.Category.ID: CategoryKind]

  /// `categories` lets the matcher skip rules whose category is missing, archived or of the
  /// wrong kind for the transaction.
  public init(rules: [CategoryRule], categories: [AbacusDomain.Category]) {
    self.rules = rules.filter { $0.isEnabled && !RulePattern.normalized($0.pattern).isEmpty }
    self.kinds = Dictionary(
      categories.filter { !$0.isArchived }.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
  }

  /// The first rule matching `description` for a transaction of `kind` on `accountID`.
  public func match(description: String, accountID: Account.ID?, kind: CategoryKind) -> CategoryRule? {
    let text = RulePattern.normalized(description)
    guard !text.isEmpty else { return nil }
    return rules.first { rule in
      if let scope = rule.accountID, scope != accountID { return false }
      guard kinds[rule.categoryID] == kind else { return false }
      return text.contains(RulePattern.normalized(rule.pattern))
    }
  }
}

/// Patterns learned from the user's choices (R-IMP-8).
public enum RulePattern {
  /// Lowercased with runs of whitespace collapsed to one space: what patterns and descriptions
  /// are compared as.
  public static func normalized(_ text: String) -> String {
    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// A pattern for a description: its first run of up to three words without digits
  /// ("GROCERY  STORE 0042 WARSZAWA" → "grocery store"), so card-terminal numbers and
  /// references do not end up in the rule. Empty when the description has no such word.
  public static func derive(from description: String) -> String {
    let words = normalized(description).split(separator: " ").map(String.init)
    var run: [String] = []
    for word in words {
      let usable = !word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
      if usable {
        run.append(word)
        if run.count == 3 { break }
      } else if !run.isEmpty {
        break
      }
    }
    let pattern = run.joined(separator: " ")
    return pattern.count >= 3 ? pattern : ""
  }
}
