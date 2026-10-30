import AbacusDomain
import Foundation

/// `TxnQuery` evaluated in memory, with the store's semantics (R-LIST-1…3, R-LIST-6):
/// - dates `fromDay`…`toDay` inclusive, as calendar days;
/// - categories: a parent matches its children; a transaction also matches through one of its
///   attached records; `includeUncategorised` adds expenses and incomes without a category of
///   their own (never transfers), "uncategorised OR one of these";
/// - import batches: only transactions created by one of `importBatchIDs`;
/// - accounts: either side of a transfer;
/// - search: case-insensitive substring of the description (payee) or note, or of an attached
///   record's note;
/// - sorted by `occurredAt`, then creation time, then id, as `newestFirst` says.
public struct TransactionQueryMatcher: Sendable {
  public var query: TxnQuery
  public var categories: [AbacusDomain.Category]
  public var calendar: Calendar

  public init(query: TxnQuery, categories: [AbacusDomain.Category], calendar: Calendar = .current) {
    self.query = query
    self.categories = categories
    self.calendar = calendar
  }

  public func apply(_ rows: [TxnWithLines]) -> [TxnWithLines] {
    let categoryIDs: Set<AbacusDomain.Category.ID>? =
      query.categoryIDs.isEmpty
      ? nil
      : query.categoryIDs.union(
        categories.filter { $0.parentID.map(query.categoryIDs.contains) ?? false }.map(\.id))
    let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let matching = rows.filter { row in
      let txn = row.txn
      let day = Day(txn.occurredAt, calendar: calendar)
      if let from = query.fromDay, day < from { return false }
      if let to = query.toDay, day > to { return false }
      if !query.types.isEmpty, !query.types.contains(txn.type) { return false }
      if !query.accountIDs.isEmpty, !query.accountIDs.contains(txn.accountID),
        !(txn.toAccountID.map(query.accountIDs.contains) ?? false)
      {
        return false
      }
      if !query.eventIDs.isEmpty, !(txn.eventID.map(query.eventIDs.contains) ?? false) { return false }
      if !query.importBatchIDs.isEmpty, !(txn.importBatchID.map(query.importBatchIDs.contains) ?? false) {
        return false
      }
      if categoryIDs != nil || query.includeUncategorised {
        let uncategorised =
          query.includeUncategorised && (txn.type != .transfer || query.uncategorisedIncludesTransfers) && txn.categoryID == nil
        let ids = [txn.categoryID] + row.lines.map(\.categoryID)
        let inCategories = categoryIDs.map { set in ids.contains { $0.map(set.contains) ?? false } } ?? false
        if !uncategorised && !inCategories { return false }
      }
      if !needle.isEmpty {
        let texts = [txn.payee, txn.note] + row.lines.map(\.note)
        if !texts.contains(where: { $0.lowercased().contains(needle) }) { return false }
      }
      return true
    }
    return matching.sorted { a, b in
      let left = (a.txn.occurredAt, a.txn.createdAt, a.txn.id.uuidString)
      let right = (b.txn.occurredAt, b.txn.createdAt, b.txn.id.uuidString)
      return query.newestFirst ? left > right : left < right
    }
  }
}
