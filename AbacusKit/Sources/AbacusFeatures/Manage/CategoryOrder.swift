import AbacusDomain
import Foundation

/// How a list of categories is ordered (R-MGMT-8). Every category picker and menu in the app
/// uses `CategoryOrder.alphabetical` (parents A–Z, each followed by its subcategories A–Z); only
/// the Categories page offers the other orders through its sort selector.
public enum CategorySort: String, CaseIterable, Identifiable, Sendable {
  case nameAscending
  case nameDescending
  /// The order set by drag and drop (`position`).
  case custom
  case newestFirst
  case oldestFirst

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .nameAscending: "Name A–Z"
    case .nameDescending: "Name Z–A"
    case .custom: "Custom order"
    case .newestFirst: "Newest first"
    case .oldestFirst: "Oldest first"
    }
  }

  /// The Categories page starts in the order the user arranged.
  public static let `default`: CategorySort = .custom
}

public enum CategoryOrder {
  /// Names A–Z as people read them ("Eating out" before "eBay", "Item 2" before "Item 10"),
  /// then by id so equal names keep a stable order.
  public static func byName(_ a: AbacusDomain.Category, _ b: AbacusDomain.Category) -> Bool {
    switch a.name.localizedStandardCompare(b.name) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.id.uuidString < b.id.uuidString
    }
  }

  /// The comparison of one sort; ties fall back to the custom order, then the name.
  public static func comparator(_ sort: CategorySort) -> (AbacusDomain.Category, AbacusDomain.Category) -> Bool {
    func custom(_ a: AbacusDomain.Category, _ b: AbacusDomain.Category) -> Bool {
      a.position != b.position ? a.position < b.position : byName(a, b)
    }
    return switch sort {
    case .nameAscending: byName
    case .nameDescending: { byName($1, $0) }
    case .custom: custom
    case .newestFirst: { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : custom($1, $0) }
    case .oldestFirst: { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : custom($0, $1) }
    }
  }

  /// The one-level tree in `sort` order: top-level categories, each followed by its
  /// subcategories in the same order. A subcategory whose parent is not in `categories` is
  /// treated as top level.
  public static func tree(_ categories: [AbacusDomain.Category], by sort: CategorySort) -> [AbacusDomain.Category] {
    let order = comparator(sort)
    let ids = Set(categories.map(\.id))
    let children = Dictionary(grouping: categories.filter { $0.parentID.map(ids.contains) ?? false }) { $0.parentID! }
    return categories.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: order).flatMap { parent in
      [parent] + (children[parent.id] ?? []).sorted(by: order)
    }
  }

  /// Pickers and menus everywhere (R-MGMT-8): parents A–Z, each followed by its subcategories
  /// A–Z. Filter by kind or archive state before calling.
  public static func alphabetical(_ categories: [AbacusDomain.Category]) -> [AbacusDomain.Category] {
    tree(categories, by: .nameAscending)
  }
}
