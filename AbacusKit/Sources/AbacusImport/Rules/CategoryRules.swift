import AbacusDomain
import Foundation

/// What a rule is tested against (R-IMP-8).
public struct RuleSubject: Hashable, Sendable {
  public var description: String
  /// The transaction's own account; nil = not known yet (an account an import creates), which
  /// per-account rules do not match.
  public var accountID: Account.ID?
  /// Absolute amount in the account's currency; nil = unknown (amount conditions fail).
  public var amountMinor: Int64?
  /// The transaction's kind; a category rule only applies to a category of the same kind.
  /// nil = any kind (the rules tester).
  public var kind: CategoryKind?

  public init(description: String, accountID: Account.ID? = nil, amountMinor: Int64? = nil, kind: CategoryKind? = nil) {
    self.description = description
    self.accountID = accountID
    self.amountMinor = amountMinor
    self.kind = kind
  }
}

/// Applies rules (R-IMP-8, R-EDIT-3, D44, C15): description *contains* / *starts with* /
/// *equals* (folded
/// for case, diacritics and whitespace) and/or amount bigger / smaller than, optionally
/// only on one account → assign a category or turn into a transfer. Rules are tried in the given
/// order (`RuleRepository.rules()` returns them in evaluation order); the first one that matches
/// and can act on the transaction wins.
public struct RuleMatcher: Sendable {
  public let rules: [CategoryRule]
  private let kinds: [AbacusDomain.Category.ID: CategoryKind]
  /// Active accounts a transfer rule may point at; nil = not checked.
  private let activeAccounts: Set<Account.ID>?

  /// `categories` lets the matcher skip category rules whose category is missing, archived or of
  /// the wrong kind; `accounts` (when given) skips transfer rules to a missing or archived account.
  public init(rules: [CategoryRule], categories: [AbacusDomain.Category], accounts: [Account]? = nil) {
    self.rules = rules.filter { $0.isEnabled && $0.hasCondition }
    self.kinds = Dictionary(
      categories.filter { !$0.isArchived }.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
    self.activeAccounts = accounts.map { Set($0.filter { !$0.isArchived }.map(\.id)) }
  }

  /// Whether the rule's conditions (text, amount, account) hold, whatever its action. A rule
  /// without a description condition (empty pattern) is decided by its amount condition; a rule
  /// with neither never matches (TA v1.6).
  public static func conditionsHold(_ rule: CategoryRule, for subject: RuleSubject) -> Bool {
    guard rule.hasCondition else { return false }
    if let scope = rule.accountID, scope != subject.accountID { return false }
    let pattern = RulePattern.normalized(rule.pattern)
    if !pattern.isEmpty {
      let text = RulePattern.normalized(subject.description)
      guard !text.isEmpty else { return false }
      switch rule.matchKind {
      case .contains: guard text.contains(pattern) else { return false }
      case .startsWith: guard text.hasPrefix(pattern) else { return false }
      case .exactly: guard text == pattern else { return false }
      }
    }
    if let comparison = rule.amountComparison, let limit = rule.amountMinor {
      guard let amount = subject.amountMinor.map(abs) else { return false }
      switch comparison {
      case .biggerThan: guard amount > limit else { return false }
      case .smallerThan: guard amount < limit else { return false }
      }
    }
    return true
  }

  /// Whether the rule's action can apply: an active category of the subject's kind, or an
  /// active transfer account other than the subject's own.
  private func actionApplies(_ rule: CategoryRule, for subject: RuleSubject) -> Bool {
    switch rule.action {
    case .category:
      guard let id = rule.categoryID, let kind = kinds[id] else { return false }
      return subject.kind.map { $0 == kind } ?? true
    case .transfer:
      guard let target = rule.transferAccountID else { return false }
      if let own = subject.accountID, own == target { return false }
      return activeAccounts.map { $0.contains(target) } ?? true
    case .debt:
      return rule.debtPerson != nil
    }
  }

  /// Every rule that matches and can act, in evaluation order (callers that cannot use the
  /// first one — a transfer whose amount in the other currency is unknown — take the next).
  public func candidates(for subject: RuleSubject) -> [CategoryRule] {
    rules.filter { Self.conditionsHold($0, for: subject) && actionApplies($0, for: subject) }
  }

  /// The first rule that matches and can act.
  public func match(_ subject: RuleSubject) -> CategoryRule? {
    rules.first { Self.conditionsHold($0, for: subject) && actionApplies($0, for: subject) }
  }

  /// The first *category* rule matching a transaction of `kind` (transfer and debt rules are skipped):
  /// the editor's suggestion (R-EDIT-3).
  public func categoryMatch(_ subject: RuleSubject) -> CategoryRule? {
    rules.first { $0.action == .category && Self.conditionsHold($0, for: subject) && actionApplies($0, for: subject) }
  }

  /// The first category rule for `description` on `accountID` for a transaction of `kind`.
  public func match(description: String, accountID: Account.ID?, kind: CategoryKind, amountMinor: Int64? = nil) -> CategoryRule? {
    categoryMatch(RuleSubject(description: description, accountID: accountID, amountMinor: amountMinor, kind: kind))
  }

  /// Whether `rule` alone matches (enabled, its category or account active); `accountID == nil`
  /// lets a per-account rule match too (the rules tester's "any account"), `kind == nil` any kind.
  public static func matches(
    _ rule: CategoryRule, description: String, accountID: Account.ID?, amountMinor: Int64? = nil,
    kind: CategoryKind? = nil, categories: [AbacusDomain.Category], accounts: [Account]? = nil
  ) -> Bool {
    RuleMatcher(rules: [rule], categories: categories, accounts: accounts)
      .match(RuleSubject(description: description, accountID: accountID ?? rule.accountID, amountMinor: amountMinor, kind: kind)) != nil
  }
}

/// Patterns learned from the user's choices (R-IMP-8).
public enum RulePattern {
  /// Case- and diacritic-folded with runs of whitespace collapsed to one space: what patterns
  /// and descriptions are compared as ("Żabka" matches "zabka").
  public static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

extension CategoryRule {
  /// A short name for the rule in messages: its text, or its amount condition for an
  /// amount-only rule ("amount > 100.00").
  public var label: String {
    if hasDescriptionCondition { return pattern }
    guard let comparison = amountComparison, let amount = amountMinor else { return "" }
    let sign = comparison == .biggerThan ? ">" : "<"
    return "amount \(sign) \(amount / 100).\(String(format: "%02d", Int(amount % 100)))"
  }
}
