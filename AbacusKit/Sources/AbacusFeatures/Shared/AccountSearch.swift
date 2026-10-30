import AbacusDomain
import AbacusImport
import Foundation

/// One row of an account picker: what is chosen (`id`), how it reads ("Name · CUR"), the account
/// group heading it sits under (nil = ungrouped) and the fields the search looks at.
public struct AccountPickerItem: Identifiable, Hashable, Sendable {
  public var id: Account.ID
  public var name: String
  public var currencyCode: String
  /// The group name; nil = an account without a group (no heading).
  public var section: String?
  public var isArchived: Bool
  /// Overrides `title` (the import's pickers add "(archived)", for example).
  public var customTitle: String?

  public var title: String { customTitle ?? "\(name) · \(currencyCode)" }

  public init(
    id: Account.ID, name: String, currencyCode: String, section: String? = nil, isArchived: Bool = false,
    customTitle: String? = nil
  ) {
    self.id = id
    self.name = name
    self.currencyCode = currencyCode
    self.section = section
    self.isArchived = isArchived
    self.customTitle = customTitle
  }

  public init(_ account: Account, section: String?) {
    self.init(
      id: account.id, name: account.name, currencyCode: account.currency.rawValue, section: section,
      isArchived: account.isArchived)
  }

  /// Rows of picker sections (`AccountOrder.pickerSections`), in their order.
  public static func items(from sections: [AccountPickerSection]) -> [AccountPickerItem] {
    sections.flatMap { section in section.accounts.map { AccountPickerItem($0, section: section.title) } }
  }
}

/// Search for account pickers and the Transactions filter's Accounts list (C37; mirrors
/// `CategorySearch`). Pure; the controls in the app target only draw what this returns.
///
/// Rules, on the folded form (case, diacritics, runs of whitespace; `RulePattern.normalized`):
/// - an empty query returns every row;
/// - a row matches when its name, its currency code or its group name contains the query; a group
///   name that matches brings ALL accounts of the group;
/// - groups keep their order (and the ungrouped accounts stay last); a group without hits disappears;
/// - archived rows are left out unless `isSelected` says they are the current choice;
/// - `excluding` drops accounts altogether (e.g. the other side of a transfer).
public enum AccountSearch {
  public struct Group: Identifiable, Hashable, Sendable {
    public var heading: String?
    public var items: [AccountPickerItem]
    public var id: String { heading ?? "" }
  }

  public static func items(
    _ items: [AccountPickerItem], query: String, isSelected: (Account.ID) -> Bool = { _ in false },
    excluding: Set<Account.ID> = []
  ) -> [AccountPickerItem] {
    let needle = RulePattern.normalized(query)
    return items.filter { item in
      guard !excluding.contains(item.id), !item.isArchived || isSelected(item.id) else { return false }
      return matches(item, needle: needle)
    }
  }

  /// `items` split into groups by heading (order of first appearance kept).
  public static func groups(
    _ items: [AccountPickerItem], query: String, isSelected: (Account.ID) -> Bool = { _ in false },
    excluding: Set<Account.ID> = []
  ) -> [Group] {
    var groups: [Group] = []
    for item in Self.items(items, query: query, isSelected: isSelected, excluding: excluding) {
      if let index = groups.firstIndex(where: { $0.heading == item.section }) {
        groups[index].items.append(item)
      } else {
        groups.append(Group(heading: item.section, items: [item]))
      }
    }
    return groups
  }

  /// For a multi-select list: `sections` reduced to the accounts that match; accounts for which
  /// `isSelected` is true always stay (so a ticked account never disappears while searching).
  /// A section without accounts is dropped. An empty query returns `sections` unchanged.
  public static func sections(
    _ sections: [AccountPickerSection], query: String, isSelected: (Account.ID) -> Bool = { _ in false }
  ) -> [AccountPickerSection] {
    let needle = RulePattern.normalized(query)
    if needle.isEmpty { return sections }
    return sections.compactMap { section in
      let kept = section.accounts.filter { account in
        isSelected(account.id) || matches(AccountPickerItem(account, section: section.title), needle: needle)
      }
      return kept.isEmpty ? nil : AccountPickerSection(group: section.group, accounts: kept)
    }
  }

  private static func matches(_ item: AccountPickerItem, needle: String) -> Bool {
    if needle.isEmpty { return true }
    if RulePattern.normalized(item.name).contains(needle) { return true }
    if RulePattern.normalized(item.currencyCode).contains(needle) { return true }
    if let section = item.section, RulePattern.normalized(section).contains(needle) { return true }
    return false
  }
}
