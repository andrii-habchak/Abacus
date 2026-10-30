import AbacusDomain
import Foundation
import SQLiteData

/// Categories (R-CAT): one level of subcategories, archive, delete with reassignment.
public struct SQLiteCategoryRepository: CategoryRepository {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  public func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [AbacusDomain.Category] {
    try await database.read { db in
      try AbacusDomain.Category
        .where { if let kind { $0.kind.eq(kind) } }
        .where { if !includeArchived { !$0.isArchived } }
        .order { ($0.position, $0.name) }
        .fetchAll(db)
    }
  }

  /// Inserts or updates, keeping the tree one level deep and of one kind (R-CAT-2): a parent must
  /// be a top-level category of the same kind, and a category with children stays top level.
  public func save(_ category: AbacusDomain.Category) async throws {
    try await database.write { db in
      let children = try AbacusDomain.Category.where { $0.parentID.eq(category.id) }.fetchAll(db)
      if let parentID = category.parentID {
        guard parentID != category.id, children.isEmpty,
          let parent = try AbacusDomain.Category.find(parentID).fetchOne(db),
          parent.parentID == nil
        else { throw StoreError.invalidParent }
        guard parent.kind == category.kind else { throw RepositoryError.kindMismatch }
      }
      guard children.allSatisfy({ $0.kind == category.kind }) else {
        throw RepositoryError.kindMismatch
      }
      try AbacusDomain.Category.upsert { AbacusDomain.Category.Draft(category) }.execute(db)
      // R-MGMT-7: a category saved without a colour gets a palette colour apart from its siblings.
      if ColorPalette.rgb(category.colorHex) == nil { try ColorFill.fillCategories(db) }
    }
  }

  /// Archiving a parent archives its children; unarchiving a child unarchives its parent, so a
  /// visible child never hangs under a hidden parent.
  public func setArchived(_ id: AbacusDomain.Category.ID, _ isArchived: Bool) async throws {
    try await database.write { db in
      guard let category = try AbacusDomain.Category.find(id).fetchOne(db) else {
        throw RepositoryError.notFound
      }
      try AbacusDomain.Category.find(id).update { $0.isArchived = isArchived }.execute(db)
      if isArchived {
        try AbacusDomain.Category
          .where { $0.parentID.eq(id) }
          .update { $0.isArchived = true }
          .execute(db)
      } else if let parentID = category.parentID {
        try AbacusDomain.Category.find(parentID).update { $0.isArchived = false }.execute(db)
      }
    }
  }

  /// R-CAT-3. A category is in use when transactions, attached records or budget allocations
  /// point at it. In use → `reassignTo` is required and must be of the same kind; transactions,
  /// attached records, budget allocations (merged into the target's), rules and import mappings
  /// move there. Children move up to top level. Unused categories are deleted outright (their
  /// rules go with them).
  public func delete(_ id: AbacusDomain.Category.ID, reassignTo: AbacusDomain.Category.ID?) async throws {
    try await database.write { db in
      guard let category = try AbacusDomain.Category.find(id).fetchOne(db) else {
        throw RepositoryError.notFound
      }
      let target = reassignTo == id ? nil : reassignTo
      let inUse =
        try Txn.where { $0.categoryID.eq(id) }.fetchCount(db) > 0
        || AttachedRecord.where { $0.categoryID.eq(id) }.fetchCount(db) > 0
        || BudgetAllocation.where { $0.categoryID.eq(id) }.fetchCount(db) > 0

      // Children move up first, so a child may also be the reassignment target.
      try AbacusDomain.Category
        .where { $0.parentID.eq(id) }
        .update { $0.parentID = #bind(nil) }
        .execute(db)

      if let target {
        guard let targetCategory = try AbacusDomain.Category.find(target).fetchOne(db) else {
          throw RepositoryError.notFound
        }
        guard targetCategory.kind == category.kind else { throw RepositoryError.kindMismatch }
        try Self.reassign(from: id, to: target, db)
      } else if inUse {
        throw RepositoryError.categoryInUse
      } else {
        try ImportMapping
          .where { $0.kind.eq(MappingKind.category) && $0.targetID.eq(id) }
          .delete().execute(db)
      }
      try AbacusDomain.Category.find(id).delete().execute(db)
    }
  }

  /// The category and, for a parent, its subcategories: the rows "Re-assign…" moves (C33).
  private static func sourceIDs(of id: AbacusDomain.Category.ID, _ db: Database) throws -> [AbacusDomain.Category.ID] {
    [id] + (try AbacusDomain.Category.where { $0.parentID.eq(id) }.fetchAll(db).map(\.id))
  }

  private static func impact(of ids: [AbacusDomain.Category.ID], _ db: Database) throws -> CategoryReassignImpact {
    let set = Set(ids)
    let optional = set.map(Optional.some)
    return CategoryReassignImpact(
      transactions: try Txn.where { $0.categoryID.in(optional) }.fetchCount(db),
      attachedRecords: try AttachedRecord.where { $0.categoryID.in(optional) }.fetchCount(db),
      rules: try CategoryRule.where { $0.categoryID.in(optional) }.fetchCount(db),
      importMappings: try ImportMapping.where { $0.kind.eq(MappingKind.category) && $0.targetID.in(set) }.fetchCount(db),
      budgetLimits: try BudgetAllocation.where { $0.categoryID.in(set) }.fetchCount(db))
  }

  public func reassignImpact(of id: AbacusDomain.Category.ID) async throws -> CategoryReassignImpact {
    try await database.read { db in
      guard try AbacusDomain.Category.find(id).fetchOne(db) != nil else { throw RepositoryError.notFound }
      return try Self.impact(of: try Self.sourceIDs(of: id, db), db)
    }
  }

  @discardableResult
  public func reassign(
    from id: AbacusDomain.Category.ID, to target: AbacusDomain.Category.ID?, repointRules: Bool, archiveAfterwards: Bool
  ) async throws -> CategoryReassignImpact {
    try await database.write { db in
      guard let source = try AbacusDomain.Category.find(id).fetchOne(db) else { throw RepositoryError.notFound }
      if let target {
        guard let targetCategory = try AbacusDomain.Category.find(target).fetchOne(db) else { throw RepositoryError.notFound }
        guard targetCategory.kind == source.kind else { throw RepositoryError.kindMismatch }
      }
      let ids = try Self.sourceIDs(of: id, db)
      if let target { guard !ids.contains(target) else { throw RepositoryError.invalidReassignTarget } }
      let set = Set(ids)
      let optional = set.map(Optional.some)
      var moved = try Self.impact(of: ids, db)
      try Txn.where { $0.categoryID.in(optional) }.update { $0.categoryID = #bind(target) }.execute(db)
      try AttachedRecord.where { $0.categoryID.in(optional) }.update { $0.categoryID = #bind(target) }.execute(db)
      // The built-in Uncategorised (nil) cannot be a rule's or a mapping's category: they stay.
      if let target, repointRules {
        try CategoryRule.where { $0.categoryID.in(optional) }.update { $0.categoryID = #bind(target) }.execute(db)
        try ImportMapping
          .where { $0.kind.eq(MappingKind.category) && $0.targetID.in(set) }
          .update { $0.targetID = target }
          .execute(db)
      } else {
        moved.rules = 0
        moved.importMappings = 0
      }
      if archiveAfterwards {
        try AbacusDomain.Category.find(id).update { $0.isArchived = true }.execute(db)
        try AbacusDomain.Category.where { $0.parentID.eq(id) }.update { $0.isArchived = true }.execute(db)
      }
      return moved
    }
  }

  private static func reassign(
    from id: AbacusDomain.Category.ID, to target: AbacusDomain.Category.ID, _ db: Database
  ) throws {
    try Txn.where { $0.categoryID.eq(id) }.update { $0.categoryID = #bind(Optional(target)) }.execute(db)
    try AttachedRecord.where { $0.categoryID.eq(id) }.update { $0.categoryID = #bind(Optional(target)) }.execute(db)
    try CategoryRule.where { $0.categoryID.eq(id) }.update { $0.categoryID = #bind(target) }.execute(db)
    try ImportMapping
      .where { $0.kind.eq(MappingKind.category) && $0.targetID.eq(id) }
      .update { $0.targetID = target }
      .execute(db)
    // A plan holds at most one allocation per category: add the limits up when they share a
    // currency. In different currencies the target keeps its own limit (there is no rate here
    // to add them up with; D43).
    let moving = try BudgetAllocation.where { $0.categoryID.eq(id) }.fetchAll(db)
    for allocation in moving {
      let planID = allocation.planID
      if let existing = try BudgetAllocation
        .where({ $0.planID.eq(planID) && $0.categoryID.eq(target) })
        .fetchOne(db)
      {
        if existing.currency == allocation.currency {
          let limit = existing.limitMinor + allocation.limitMinor
          try BudgetAllocation.find(existing.id).update { $0.limitMinor = limit }.execute(db)
        }
        try BudgetAllocation.find(allocation.id).delete().execute(db)
      } else {
        try BudgetAllocation.find(allocation.id).update { $0.categoryID = #bind(target) }.execute(db)
      }
    }
  }
}
