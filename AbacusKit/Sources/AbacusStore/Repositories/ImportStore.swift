import AbacusDomain
import Foundation
import SQLiteData

/// Import persistence (R-IMP-3/6/7): fingerprint lookups, dedupe candidates, remembered
/// mappings, the all-or-nothing commit and undo by batch.
public struct SQLiteImportStore: ImportStore {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  var bounds: DayBounds { DayBounds(calendar: calendar) }

  /// R-IMP-3: fingerprint → transaction for the ones already stored.
  public func existingFingerprints(_ ids: [String]) async throws -> [String: Txn.ID] {
    let unique = Array(Set(ids))
    return try await database.read { db in
      var found: [String: Txn.ID] = [:]
      for chunk in unique.chunked(500) {
        let keys = Array(chunk)
        for fingerprint in try ImportFingerprint.where({ $0.id.in(keys) }).fetchAll(db) {
          found[fingerprint.id] = fingerprint.txnID
        }
      }
      return found
    }
  }

  /// R-IMP-4: transactions of the account with the same amount, `from…to` inclusive. Matches the
  /// sending side (`amountMinor`) and the receiving side of transfers (`toAmountMinor`).
  public func candidates(accountID: Account.ID, amountMinor: Int64, from: Day, to: Day) async throws -> [Txn] {
    let start = bounds.start(from)
    let end = bounds.end(to)
    return try await database.read { db in
      try Txn
        .where {
          $0.occurredAt >= start && $0.occurredAt < end
            && (($0.accountID.eq(accountID) && $0.amountMinor.eq(amountMinor))
              || ($0.toAccountID.eq(accountID) && $0.toAmountMinor.eq(amountMinor)))
        }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(db)
    }
  }

  /// R-IMP-PKO-2: pending holds of the account, `from…to` inclusive.
  public func pendingTxns(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn] {
    let start = bounds.start(from)
    let end = bounds.end(to)
    return try await database.read { db in
      try Txn
        .where {
          $0.accountID.eq(accountID) && $0.isPendingAtBank && $0.occurredAt >= start && $0.occurredAt < end
        }
        .order { ($0.occurredAt, $0.id) }
        .fetchAll(db)
    }
  }

  /// R-IMP-2: remembered mappings of a source.
  public func mappings(source: ImportSource) async throws -> [ImportMapping] {
    try await database.read { db in
      try ImportMapping
        .where { $0.source.eq(source) }
        .order { ($0.kind, $0.externalKey) }
        .fetchAll(db)
    }
  }

  /// R-IMP-6: writes everything in one database transaction — any failure (e.g. a fingerprint
  /// already stored, R-IMP-3) rolls the whole import back.
  ///
  /// R-IMP-7: new accounts, categories, events and transactions are inserted, never upserted, so
  /// an import cannot overwrite existing rows (opening balances included); only `updatedTxns`
  /// (links and pending→settled upgrades) change existing transactions. New transactions and
  /// fingerprints are tagged with the batch. Mappings replace the previous mapping of the same
  /// (source, kind, external key); rules are upserted.
  public func commit(_ commit: ImportCommit) async throws {
    try await database.write { db in
      let batchID = commit.batch.id
      try ImportBatch.insert { commit.batch }.execute(db)
      if !commit.newAccounts.isEmpty {
        try Account.insert { commit.newAccounts }.execute(db)
      }
      // Parents first, so children's parentID resolves.
      let categories = commit.newCategories.sorted { ($0.parentID == nil ? 0 : 1) < ($1.parentID == nil ? 0 : 1) }
      if !categories.isEmpty {
        try AbacusDomain.Category.insert { categories }.execute(db)
      }
      if !commit.newEvents.isEmpty {
        try Event.insert { commit.newEvents }.execute(db)
      }
      for chunk in commit.txns.chunked(200) {
        let txns = chunk.map { item in
          var txn = item.txn
          txn.importBatchID = batchID
          return txn
        }
        try Txn.insert { txns }.execute(db)
        var lines: [AttachedRecord] = []
        for item in chunk {
          for (index, line) in item.lines.enumerated() {
            var line = line
            line.txnID = item.txn.id
            if line.position == 0 { line.position = index }
            lines.append(line)
          }
        }
        if !lines.isEmpty {
          try AttachedRecord.insert { lines }.execute(db)
        }
      }
      for txn in commit.updatedTxns {
        guard try Txn.find(txn.id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
      }
      for chunk in commit.fingerprints.chunked(500) {
        let fingerprints = chunk.map { item in
          var fingerprint = item
          fingerprint.batchID = batchID
          return fingerprint
        }
        try ImportFingerprint.insert { fingerprints }.execute(db)
      }
      for mapping in commit.mappings {
        try ImportMapping
          .where {
            $0.source.eq(mapping.source) && $0.kind.eq(mapping.kind)
              && $0.externalKey.eq(mapping.externalKey) && $0.id.neq(mapping.id)
          }
          .delete().execute(db)
        try ImportMapping.upsert { ImportMapping.Draft(mapping) }.execute(db)
      }
      for rule in commit.rules {
        try CategoryRule.upsert { CategoryRule.Draft(rule) }.execute(db)
      }
    }
  }

  /// Import history, newest first.
  public func batches() async throws -> [ImportBatch] {
    try await database.read { db in
      try ImportBatch.order { ($0.importedAt.desc(), $0.id) }.fetchAll(db)
    }
  }

  /// R-IMP-6: deletes the batch's transactions (their attached records and fingerprints go with
  /// them) and the fingerprints it added to existing transactions (links, settled upgrades), then
  /// marks the batch undone. Accounts, categories and events it created, and the field changes of
  /// upgraded transactions, stay.
  public func undo(_ batchID: ImportBatch.ID) async throws {
    try await database.write { db in
      guard let batch = try ImportBatch.find(batchID).fetchOne(db) else { throw RepositoryError.notFound }
      guard !batch.isUndone else { return }
      try Txn.where { $0.importBatchID.eq(batchID) }.delete().execute(db)
      try ImportFingerprint.where { $0.batchID.eq(batchID) }.delete().execute(db)
      try ImportBatch.find(batchID).update { $0.isUndone = true }.execute(db)
    }
  }

  /// Number of transactions still linked to each batch (import history counts).
  public func transactionCounts() async throws -> [ImportBatch.ID: Int] {
    try await database.read { db in
      let rows = try Txn
        .where { $0.importBatchID.isNot(nil) }
        .group(by: \.importBatchID)
        .select { ($0.importBatchID, $0.id.count()) }
        .fetchAll(db)
      var counts: [ImportBatch.ID: Int] = [:]
      for (id, count) in rows {
        if let id { counts[id] = count }
      }
      return counts
    }
  }
}
