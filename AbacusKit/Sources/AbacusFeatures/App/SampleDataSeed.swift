import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

extension SampleData {
  /// Inserts the sample set into a database without accounts. A sample category whose name
  /// (and kind, and parent) matches one already there — the default set seeded on first launch
  /// (R-CAT-4) — is reused instead of duplicated; transactions, lines and budget limits follow.
  static func seed(_ db: Database) throws {
    let existing = try AbacusDomain.Category.fetchAll(db)
    let (categories, mapping) = categoriesToInsert(PreviewData.categories, existing: existing)
    func mapped(_ id: AbacusDomain.Category.ID?) -> AbacusDomain.Category.ID? {
      id.map { mapping[$0] ?? $0 }
    }
    let txns = PreviewData.txns.map { txn in
      var txn = txn
      txn.categoryID = mapped(txn.categoryID)
      return txn
    }
    let records = PreviewData.attachedRecords.map { record in
      var record = record
      record.categoryID = mapped(record.categoryID)
      return record
    }
    let allocations = PreviewData.budgetAllocations.map { allocation in
      var allocation = allocation
      allocation.categoryID = mapped(allocation.categoryID) ?? allocation.categoryID
      return allocation
    }
    try db.seed {
      for account in PreviewData.accounts { account }
      for category in categories { category }
      for event in PreviewData.events { event }
      for txn in txns { txn }
      for record in records { record }
      PreviewData.budgetPlan
      for allocation in allocations { allocation }
    }
    try ColorFill.fillAll(db)
  }

  /// The sample categories still to insert, and every sample id → the id used in the database.
  /// Parents are matched first so a subcategory is looked up under its (mapped) parent; an
  /// active match wins over an archived one; names compare case-insensitively.
  public static func categoriesToInsert(
    _ sample: [AbacusDomain.Category], existing: [AbacusDomain.Category]
  ) -> ([AbacusDomain.Category], [AbacusDomain.Category.ID: AbacusDomain.Category.ID]) {
    var mapping: [AbacusDomain.Category.ID: AbacusDomain.Category.ID] = [:]
    var inserts: [AbacusDomain.Category] = []
    let takenIDs = Set(existing.map(\.id))
    let ordered = sample.filter { $0.parentID == nil } + sample.filter { $0.parentID != nil }
    for category in ordered {
      let parentID = category.parentID.map { mapping[$0] ?? $0 }
      let matches = existing.filter {
        $0.kind == category.kind && $0.parentID == parentID
          && $0.name.compare(category.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }
      if let match = matches.first(where: { !$0.isArchived }) ?? matches.first {
        mapping[category.id] = match.id
        continue
      }
      let insert = AbacusDomain.Category(
        id: takenIDs.contains(category.id) ? UUID() : category.id, name: category.name, kind: category.kind,
        parentID: parentID, icon: category.icon, colorHex: category.colorHex, position: category.position,
        isArchived: category.isArchived)
      mapping[category.id] = insert.id
      inserts.append(insert)
    }
    return (inserts, mapping)
  }
}
