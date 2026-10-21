import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// The editable category set a new database starts with (R-CAT-4): expense parents with a few
/// subcategories, and income categories. Seeded at launch when the database has no category
/// at all; afterwards they are ordinary categories (rename, recolour, archive, delete).
public enum DefaultCategories {
  struct Group {
    var name: String
    var kind: CategoryKind
    var color: String
    var children: [String] = []
  }

  static let groups: [Group] = [
    Group(name: "Food", kind: .expense, color: "#E07B14", children: ["Groceries", "Eating out"]),
    Group(name: "Housing", kind: .expense, color: "#0A64D6", children: ["Rent", "Utilities"]),
    Group(name: "Transport", kind: .expense, color: "#7B4FCF", children: ["Fuel", "Taxi", "Public transport"]),
    Group(name: "Health", kind: .expense, color: "#C93B6E"),
    Group(name: "Bills", kind: .expense, color: "#5C7B99", children: ["Mobile", "Internet"]),
    Group(name: "Shopping", kind: .expense, color: "#A35A2A"),
    Group(name: "Travel", kind: .expense, color: "#C9A100"),
    Group(name: "Fees", kind: .expense, color: "#8E8E93"),
    Group(name: "Gifts", kind: .expense, color: "#D1495B"),
    Group(name: "Salary", kind: .income, color: "#1B8A4A"),
    Group(name: "Cashback", kind: .income, color: "#2E9E6A"),
    Group(name: "Refunds", kind: .income, color: "#3FA7A0"),
    Group(name: "Other income", kind: .income, color: "#6B8E23"),
  ]

  /// The default set with fresh ids; children take their parent's colour.
  public static func make() -> [AbacusDomain.Category] {
    var categories: [AbacusDomain.Category] = []
    var position: [CategoryKind: Int] = [:]
    for group in groups {
      let parent = AbacusDomain.Category(
        name: group.name, kind: group.kind, colorHex: group.color, position: position[group.kind, default: 0])
      position[group.kind, default: 0] += 1
      categories.append(parent)
      for (index, child) in group.children.enumerated() {
        categories.append(
          AbacusDomain.Category(
            name: child, kind: group.kind, parentID: parent.id, colorHex: group.color, position: index))
      }
    }
    return categories
  }

  /// Seeds the default set when the database has no category (first launch); returns whether
  /// it did. A database with any category, archived ones included, is left alone.
  @discardableResult
  public static func seedIfEmpty(_ database: any DatabaseWriter) async throws -> Bool {
    try await database.write { db in
      guard try AbacusDomain.Category.fetchCount(db) == 0 else { return false }
      try db.seed {
        for category in make() { category }
      }
      return true
    }
  }
}
