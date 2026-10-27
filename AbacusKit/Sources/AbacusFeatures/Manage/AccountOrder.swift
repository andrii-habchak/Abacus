import AbacusDomain
import Foundation

/// How the Accounts page orders its list (R-MGMT-9). Pickers always use
/// `AccountOrder.pickerSections` (A–Z under their groups).
public enum AccountSort: String, CaseIterable, Identifiable, Sendable {
  case nameAscending
  case nameDescending
  /// The order set by drag and drop (`position`).
  case custom

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .nameAscending: "Name A–Z"
    case .nameDescending: "Name Z–A"
    case .custom: "Custom order"
    }
  }

  /// The Accounts page starts in the order the user arranged.
  public static let `default`: AccountSort = .custom
}

/// Accounts of one group in a picker, or the ungrouped accounts (`group` nil, listed last).
public struct AccountPickerSection: Identifiable, Equatable, Sendable {
  public let group: AccountGroup?
  public let accounts: [Account]

  /// The group's id; ungrouped accounts use a fixed id.
  public var id: UUID { group?.id ?? AccountOrder.ungroupedID }
  /// The section header: the group name; nil for the ungrouped accounts.
  public var title: String? { group?.name }
}

/// One row of the account tree: a group (folder) or an account.
public enum AccountTreeItem: Hashable, Sendable {
  case group(AccountGroup)
  case account(Account)

  public var id: UUID {
    switch self {
    case .group(let group): group.id
    case .account(let account): account.id
    }
  }
}

/// Ordering shared by every account list and picker (R-MGMT-8, R-MGMT-9, D48).
///
/// **Pickers** (transaction editor, transactions filter, import target, rules): groups A–Z,
/// each with its accounts A–Z; accounts without a group come **after** the groups, A–Z,
/// without a header — so a database without groups shows one plain A–Z list.
public enum AccountOrder {
  static let ungroupedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

  /// Names A–Z as people read them ("Item 2" before "Item 10"), then by id.
  public static func byName(_ a: Account, _ b: Account) -> Bool {
    compare(a.name, a.id, b.name, b.id)
  }

  public static func byName(_ a: AccountGroup, _ b: AccountGroup) -> Bool {
    compare(a.name, a.id, b.name, b.id)
  }

  static func compare(_ a: String, _ aID: UUID, _ b: String, _ bID: UUID) -> Bool {
    switch a.localizedStandardCompare(b) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: aID.uuidString < bID.uuidString
    }
  }

  /// Picker sections: groups A–Z (only those with an account in `accounts`), then the accounts
  /// without a group (or whose group is unknown). Filter archived accounts before calling.
  public static func pickerSections(_ accounts: [Account], groups: [AccountGroup]) -> [AccountPickerSection] {
    let known = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var members: [AccountGroup.ID: [Account]] = [:]
    var ungrouped: [Account] = []
    for account in accounts {
      if let id = account.groupID, known[id] != nil {
        members[id, default: []].append(account)
      } else {
        ungrouped.append(account)
      }
    }
    var sections = known.values.filter { members[$0.id] != nil }.sorted(by: byName).map { group in
      AccountPickerSection(group: group, accounts: (members[group.id] ?? []).sorted(by: byName))
    }
    if !ungrouped.isEmpty { sections.append(AccountPickerSection(group: nil, accounts: ungrouped.sorted(by: byName))) }
    return sections
  }

  /// The accounts in picker order (flattened `pickerSections`).
  public static func alphabetical(_ accounts: [Account], groups: [AccountGroup]) -> [Account] {
    pickerSections(accounts, groups: groups).flatMap(\.accounts)
  }

  /// "Monobank › Monobank Black"; just the name without a group.
  public static func label(_ account: Account, groups: [AccountGroup]) -> String {
    guard let id = account.groupID, let group = groups.first(where: { $0.id == id }) else { return account.name }
    return "\(group.name) › \(account.name)"
  }

  /// The one-level tree in `sort` order: top-level items (groups and accounts without a group)
  /// with each group followed by its accounts. Custom order compares `position` (groups and
  /// top-level accounts share one position space), then the name. Name sorts put groups and
  /// top-level accounts together by name. Empty groups are kept.
  public static func tree(_ accounts: [Account], groups: [AccountGroup], by sort: AccountSort) -> [AccountTreeItem] {
    let known = Set(groups.map(\.id))
    func topLevel(_ account: Account) -> Bool { account.groupID.map { !known.contains($0) } ?? true }
    func order(_ a: (String, UUID, Int), _ b: (String, UUID, Int)) -> Bool {
      switch sort {
      case .nameAscending: compare(a.0, a.1, b.0, b.1)
      case .nameDescending: compare(b.0, b.1, a.0, a.1)
      case .custom: a.2 != b.2 ? a.2 < b.2 : compare(a.0, a.1, b.0, b.1)
      }
    }
    func key(_ item: AccountTreeItem) -> (String, UUID, Int) {
      switch item {
      case .group(let group): (group.name, group.id, group.position)
      case .account(let account): (account.name, account.id, account.position)
      }
    }
    let top = (groups.map(AccountTreeItem.group) + accounts.filter(topLevel).map(AccountTreeItem.account))
      .sorted { order(key($0), key($1)) }
    var members: [AccountGroup.ID: [Account]] = [:]
    for account in accounts where !topLevel(account) { members[account.groupID!, default: []].append(account) }
    return top.flatMap { item -> [AccountTreeItem] in
      guard case .group(let group) = item else { return [item] }
      let children = (members[group.id] ?? []).map(AccountTreeItem.account).sorted { order(key($0), key($1)) }
      return [item] + children
    }
  }
}
