import AbacusDomain
import Foundation

/// What the pipeline knows about the Abacus side when it builds a preview.
public struct ImportContext: Sendable {
  public var accounts: [Account]
  public var categories: [AbacusDomain.Category]
  public var events: [Event]
  public var rules: [CategoryRule]
  public var mappings: [ImportMapping]
  /// Debts and records before the import (R-DEBT-10/12).
  public var debts: DebtBook

  public init(
    accounts: [Account] = [], categories: [AbacusDomain.Category] = [], events: [Event] = [],
    rules: [CategoryRule] = [], mappings: [ImportMapping] = [], debts: DebtBook = .empty
  ) {
    self.debts = debts
    self.accounts = accounts
    self.categories = categories
    self.events = events
    self.rules = rules
    self.mappings = mappings
  }

  func account(_ id: Account.ID) -> Account? { accounts.first { $0.id == id } }
  func category(_ id: AbacusDomain.Category.ID) -> AbacusDomain.Category? { categories.first { $0.id == id } }

  func remembered(_ kind: MappingKind, _ key: String) -> ImportMapping? {
    mappings.first { $0.kind == kind && $0.externalKey == key }
  }
}

/// An account a preview row refers to: an existing one, or one this import creates (by the
/// source account's `ExternalAccount.key`).
public enum AccountRef: Hashable, Sendable {
  case existing(Account.ID)
  case new(key: String)
}

/// A category a preview row refers to: existing, or created by this import (`ExternalCategory.key`).
public enum CategoryRef: Hashable, Sendable {
  case existing(AbacusDomain.Category.ID)
  case new(key: String)
}

/// Source account → Abacus account (R-IMP-2, R-ACC-2, R-ACC-4).
public struct AccountMapping: Identifiable, Hashable, Sendable {
  public enum Target: Hashable, Sendable {
    case existing(Account.ID)
    case create
  }

  public enum Origin: Hashable, Sendable {
    /// Mapped the same way in an earlier import of this source.
    case remembered
    /// An existing account with the same name and currency.
    case sameName
    /// PKO ATM withdrawals: the existing cash account in that currency.
    case cashAccount
    /// Nothing matched: a new account.
    case new
    /// Chosen in the preview.
    case user
  }

  public var id: String { external.key }
  public let external: ExternalAccount
  public internal(set) var target: Target
  public internal(set) var origin: Origin
  /// Rows of the file that use this account.
  public internal(set) var rowCount: Int
  /// Name, kind and archived flag of the account `create` makes.
  public let newName: String
  public let newKind: AccountKind
  public let newIsArchived: Bool
}

/// Source category → Abacus category (R-IMP-2, R-CAT-2).
public struct CategoryMapping: Identifiable, Hashable, Sendable {
  public enum Target: Hashable, Sendable {
    case existing(AbacusDomain.Category.ID)
    case create
  }

  public enum Origin: Hashable, Sendable {
    case remembered, sameName, new, user
  }

  public var id: String { external.key }
  public let external: ExternalCategory
  public internal(set) var target: Target
  public internal(set) var origin: Origin
  /// Rows and attached records of the file that use this category.
  public internal(set) var rowCount: Int
}

enum MappingResolver {
  static func same(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
  }

  /// R-IMP-2: remembered mapping first, then an account with the same name and currency; PKO's
  /// ATM "Cash" goes to the existing cash account in its currency; otherwise create.
  static func accounts(
    rows: [NormalizedRow], source: ImportSource, context: ImportContext
  ) -> [AccountMapping] {
    var order: [String] = []
    var externals: [String: ExternalAccount] = [:]
    var counts: [String: Int] = [:]
    for row in rows {
      for account in [row.account] + (row.counterAccount.map { [$0] } ?? []) where account.resolvedID == nil {
        if externals[account.key] == nil {
          externals[account.key] = account
          order.append(account.key)
        } else if account.isArchived {
          externals[account.key]?.isArchived = true
        }
        counts[account.key, default: 0] += 1
      }
    }
    return order.map { key in
      let external = externals[key]!
      let isCash = source == .pko && external.name == PKOParser.cashAccountName
      let newName = isCash ? "\(PKOParser.cashAccountName) \(external.currency.rawValue)" : external.name
      let newKind = external.kind ?? (isCash ? .cash : .bank)
      var mapping = AccountMapping(
        external: external, target: .create, origin: .new, rowCount: counts[key] ?? 0,
        newName: newName, newKind: newKind, newIsArchived: external.isArchived)
      let usable = context.accounts.filter { $0.currency == external.currency }
      if let remembered = context.remembered(.account, key), let account = context.account(remembered.targetID),
        account.currency == external.currency
      {
        mapping.target = .existing(account.id)
        mapping.origin = .remembered
      } else if let account = usable.first(where: { same($0.name, external.name) || same($0.name, newName) }) {
        mapping.target = .existing(account.id)
        mapping.origin = .sameName
      } else if isCash, let account = usable.first(where: { $0.kind == .cash && !$0.isArchived }) {
        mapping.target = .existing(account.id)
        mapping.origin = .cashAccount
      }
      return mapping
    }
  }

  /// R-IMP-2, R-CAT-2: remembered first, then same name and kind (same parent when the source
  /// names one); otherwise create.
  static func categories(rows: [NormalizedRow], context: ImportContext) -> [CategoryMapping] {
    var order: [String] = []
    var externals: [String: ExternalCategory] = [:]
    var counts: [String: Int] = [:]
    func add(_ category: ExternalCategory?) {
      guard let category else { return }
      if externals[category.key] == nil {
        externals[category.key] = category
        order.append(category.key)
      }
      counts[category.key, default: 0] += 1
    }
    for row in rows {
      add(row.category)
      row.lines.forEach { add($0.category) }
    }
    return order.map { category(externals[$0]!, rowCount: counts[$0] ?? 0, context: context) }
  }

  static func category(_ external: ExternalCategory, rowCount: Int, context: ImportContext) -> CategoryMapping {
    var mapping = CategoryMapping(external: external, target: .create, origin: .new, rowCount: rowCount)
    let sameKind = context.categories.filter { $0.kind == external.kind }
    if let remembered = context.remembered(.category, external.key),
      let category = context.category(remembered.targetID), category.kind == external.kind
    {
      mapping.target = .existing(category.id)
      mapping.origin = .remembered
    } else if let category = bestNameMatch(external, in: sameKind) {
      mapping.target = .existing(category.id)
      mapping.origin = .sameName
    }
    return mapping
  }

  private static func bestNameMatch(_ external: ExternalCategory, in categories: [AbacusDomain.Category]) -> AbacusDomain.Category? {
    let named = categories.filter { same($0.name, external.name) }
    guard !named.isEmpty else { return nil }
    let parents = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    if let parentName = external.parentName,
      let match = named.first(where: { $0.parentID.flatMap { parents[$0] }.map { same($0.name, parentName) } ?? false })
    {
      return match
    }
    return named.sorted { ($0.isArchived ? 1 : 0, $0.position) < ($1.isArchived ? 1 : 0, $1.position) }.first
  }
}
