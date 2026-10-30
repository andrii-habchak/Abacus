import AbacusDomain
import AbacusImport
import Foundation

/// One row of a category picker: what is chosen (`value`), how it reads in the list (`title`),
/// whether it hangs under the parent above it, and the group heading it sits under.
public struct CategoryPickerItem<Value: Hashable & Sendable>: Identifiable, Hashable, Sendable {
  public var value: Value
  /// The row text; for a child it may be the bare name or the "Parent › Child" path.
  public var title: String
  /// The text of the picker button when this row is chosen; the title when nil.
  public var buttonTitle: String?
  /// Indented under the closest parent row above it.
  public var isChild: Bool
  /// The heading of its group ("Expense", "Income"); nil = a group without a heading.
  public var section: String?
  public var isArchived: Bool

  public var id: Value { value }

  public init(
    value: Value, title: String, buttonTitle: String? = nil, isChild: Bool = false,
    section: String? = nil, isArchived: Bool = false
  ) {
    self.value = value
    self.title = title
    self.buttonTitle = buttonTitle
    self.isChild = isChild
    self.section = section
    self.isArchived = isArchived
  }
}

extension CategoryPickerItem where Value == AbacusDomain.Category.ID {
  /// Rows for `categories` (already in picker order: parents A–Z, each followed by its
  /// children). Only `kinds` are offered; a category whose parent is not offered is a
  /// top-level row. Group headings are the kind names (the control shows them when both
  /// kinds are offered).
  public static func items(
    from categories: [AbacusDomain.Category], kinds: Set<CategoryKind> = Set(CategoryKind.allCases)
  ) -> [CategoryPickerItem] {
    let offered = categories.filter { kinds.contains($0.kind) }
    let ids = Set(offered.map(\.id))
    return offered.map { category in
      CategoryPickerItem(
        value: category.id, title: category.name,
        isChild: category.parentID.map(ids.contains) ?? false,
        section: category.kind == .expense ? "Expense" : "Income",
        isArchived: category.isArchived)
    }
  }
}

extension ImportCategoryOption {
  /// The picker row of this option (the import's "(new)" rows and existing categories; the
  /// `.none` option is the picker's own none row, not an item).
  public var pickerItem: CategoryPickerItem<ImportCategoryChoice> {
    CategoryPickerItem(value: choice, title: label, isChild: isChild)
  }
}

extension EditorReference.CategoryOption {
  /// The picker row of this option; `section` is a group heading ("Refund to ..."), nil for none.
  public func pickerItem(section: String? = nil) -> CategoryPickerItem<AbacusDomain.Category.ID> {
    CategoryPickerItem(value: id, title: name, isChild: isChild, section: section)
  }
}

/// Search for category pickers (owner: "parent category should include children as search
/// results"). Pure; the picker control in the app target only draws what this returns.
///
/// Rules, on the folded form (case, diacritics, runs of whitespace; `RulePattern.normalized`):
/// - an empty query returns every row;
/// - a row matches when its title contains the query;
/// - a parent that matches brings ALL its children, matching or not;
/// - a child that matches alone is returned under its parent, which is added as a context row
///   (`isContext`, still selectable, drawn dimmed);
/// - groups keep their order and A–Z order is kept; a group without hits disappears;
/// - archived rows are left out unless `isSelected` says they are the current choice.
public enum CategorySearch {
  public struct Hit<Value: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public var item: CategoryPickerItem<Value>
    /// A parent shown only to give a matching child its place.
    public var isContext: Bool
    public var id: Value { item.value }
  }

  public struct Group<Value: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public var heading: String?
    public var hits: [Hit<Value>]
    public var id: String { heading ?? "" }
  }

  public static func hits<Value>(
    _ items: [CategoryPickerItem<Value>], query: String, isSelected: (Value) -> Bool = { _ in false }
  ) -> [Hit<Value>] {
    let live = items.filter { !$0.isArchived || isSelected($0.value) }
    let needle = RulePattern.normalized(query)
    if needle.isEmpty { return live.map { Hit(item: $0, isContext: false) } }
    var result: [Hit<Value>] = []
    var parentMatched = false
    var contextAdded = false
    var parent: CategoryPickerItem<Value>?
    for item in live {
      let matches = RulePattern.normalized(item.title).contains(needle)
      if !item.isChild {
        parent = item
        parentMatched = matches
        contextAdded = false
        if matches { result.append(Hit(item: item, isContext: false)) }
        continue
      }
      guard parentMatched || matches else { continue }
      if !parentMatched, !contextAdded, let parent, parent.section == item.section {
        result.append(Hit(item: parent, isContext: true))
        contextAdded = true
      }
      result.append(Hit(item: item, isContext: false))
    }
    return result
  }

  /// `hits` split into groups by section heading (order of first appearance kept).
  public static func groups<Value>(
    _ items: [CategoryPickerItem<Value>], query: String, isSelected: (Value) -> Bool = { _ in false }
  ) -> [Group<Value>] {
    var groups: [Group<Value>] = []
    for hit in hits(items, query: query, isSelected: isSelected) {
      if let index = groups.firstIndex(where: { $0.heading == hit.item.section }) {
        groups[index].hits.append(hit)
      } else {
        groups.append(Group(heading: hit.item.section, hits: [hit]))
      }
    }
    return groups
  }
}
