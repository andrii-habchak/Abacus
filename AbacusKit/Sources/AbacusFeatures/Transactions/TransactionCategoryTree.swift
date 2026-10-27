import AbacusDomain
import Foundation

/// Categories as the transaction list shows and filters them: "Parent › Child" paths and the
/// multi-select where a parent "(all)" covers its children (R-LIST-2, R-CAT-2).
public struct TransactionCategoryTree: Equatable, Sendable {
  public typealias ID = AbacusDomain.Category.ID

  /// One line of the categories menu: parents first, each followed by its children.
  public struct Option: Identifiable, Hashable, Sendable {
    public var id: ID
    public var name: String
    public var kind: CategoryKind
    public var colorHex: String?
    public var parentID: ID?
    public var hasChildren: Bool

    /// "Food (all)" for a parent with children, else the name.
    public var label: String { hasChildren ? "\(name) (all)" : name }
    public var isChild: Bool { parentID != nil }
  }

  public private(set) var byID: [ID: AbacusDomain.Category]
  /// Menu order: expense parents, then income parents (A–Z, R-MGMT-8), each followed by its
  /// children A–Z. Archived categories are left out.
  public private(set) var options: [Option]
  private var childrenByParent: [ID: [ID]]

  public init(_ categories: [AbacusDomain.Category]) {
    byID = Dictionary(categories.map { ($0.id, $0) }) { first, _ in first }
    let order: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = {
      $0.kind != $1.kind ? $0.kind == .expense : CategoryOrder.byName($0, $1)
    }
    let live = categories.filter { !$0.isArchived }
    var children: [ID: [AbacusDomain.Category]] = [:]
    for category in live {
      if let parent = category.parentID { children[parent, default: []].append(category) }
    }
    childrenByParent = Dictionary(grouping: categories.filter { $0.parentID != nil }) { $0.parentID! }
      .mapValues { $0.map(\.id) }
    var options: [Option] = []
    for parent in live.filter({ $0.parentID == nil }).sorted(by: order) {
      let kids = (children[parent.id] ?? []).sorted(by: order)
      options.append(
        Option(
          id: parent.id, name: parent.name, kind: parent.kind, colorHex: parent.colorHex,
          parentID: nil, hasChildren: !kids.isEmpty))
      for kid in kids {
        options.append(
          Option(
            id: kid.id, name: kid.name, kind: kid.kind, colorHex: kid.colorHex, parentID: parent.id,
            hasChildren: false))
      }
    }
    self.options = options
  }

  public func category(_ id: ID?) -> AbacusDomain.Category? { id.flatMap { byID[$0] } }

  /// The category's colour, else its parent's (R-MGMT-7); nil without a category.
  public func color(_ id: ID?) -> String? {
    guard let category = category(id) else { return nil }
    return category.colorHex ?? self.category(category.parentID)?.colorHex
  }

  /// "Parent › Child", or the name of a top-level category.
  public func path(_ id: ID?) -> String? {
    guard let category = category(id) else { return nil }
    guard let parent = category.parentID.flatMap({ byID[$0] }) else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  public func children(of id: ID) -> [ID] { childrenByParent[id] ?? [] }

  /// The selection plus the children of every selected parent: the categories a transaction
  /// may have to match (R-LIST-2).
  public func expanded(_ selection: Set<ID>) -> Set<ID> {
    selection.union(selection.flatMap { children(of: $0) })
  }

  /// Ticked in the menu: selected itself or through its parent.
  public func isChecked(_ id: ID, in selection: Set<ID>) -> Bool {
    if selection.contains(id) { return true }
    return category(id)?.parentID.map(selection.contains) ?? false
  }

  /// The selection after clicking `id` in the menu:
  /// - a parent: on (replacing any of its children, it covers them) or off with its children;
  /// - a child of a selected parent: the parent gives way to its other children;
  /// - any other child: toggled.
  public func toggled(_ id: ID, in selection: Set<ID>) -> Set<ID> {
    var result = selection
    if let parent = category(id)?.parentID {
      if result.contains(parent) {
        result.remove(parent)
        result.formUnion(children(of: parent).filter { $0 != id && !(byID[$0]?.isArchived ?? false) })
      } else if result.contains(id) {
        result.remove(id)
      } else {
        result.insert(id)
      }
    } else if result.contains(id) {
      result.remove(id)
      result.subtract(children(of: id))
    } else {
      result.insert(id)
      result.subtract(children(of: id))
    }
    return result
  }

  /// Chip label: "All categories", the one category's path, or "N categories".
  public func label(for selection: Set<ID>) -> String {
    switch selection.count {
    case 0: "All categories"
    case 1: path(selection.first) ?? "1 category"
    default: "\(selection.count) categories"
    }
  }
}
