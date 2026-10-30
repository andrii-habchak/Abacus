import AbacusDomain
import Foundation
import SQLiteData

/// Import persistence (R-IMP-3/6/7): fingerprint lookups, dedupe candidates, remembered
/// mappings, the all-or-nothing commit and undo by batch.
public struct SQLiteImportStore: ImportStore {
  public let database: any DatabaseWriter
  public let calendar: Calendar
  /// Converts what lands on debt-kind accounts into debt records after each commit (R-DEBT-8).
  /// Off only in tests that need the pre-v10 shape (the real-data migration check).
  public var convertsDebtAccounts: Bool

  public init(database: any DatabaseWriter, calendar: Calendar = .current, convertsDebtAccounts: Bool = true) {
    self.database = database
    self.calendar = calendar
    self.convertsDebtAccounts = convertsDebtAccounts
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
        // A converted transaction that became a debt record without a leg keeps its
        // fingerprint on the record (R-DEBT-8); the record's id stands in for the transaction.
        for record in try DebtRecord.where({ $0.fingerprint.in(keys.map { Optional($0) }) }).fetchAll(db) {
          if let fingerprint = record.fingerprint, found[fingerprint] == nil { found[fingerprint] = record.id }
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
              || ($0.toAccountID.eq(accountID) && $0.toAmountMinor.eq(amountMinor))
              // A transfer in one currency has no separate receiving amount.
              || ($0.toAccountID.eq(accountID) && $0.toAmountMinor.is(nil) && $0.amountMinor.eq(amountMinor)))
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
    let convertsDebtAccounts = self.convertsDebtAccounts
    let calendar = self.calendar
    try await database.write { db in
      let batchID = commit.batch.id
      try ImportBatch.insert { commit.batch }.execute(db)
      // Created records are tagged with the batch so undo can remove them (R-IMP-6).
      let accounts = commit.newAccounts.map { var a = $0; a.importBatchID = batchID; return a }
      if !accounts.isEmpty {
        try Account.insert { accounts }.execute(db)
      }
      // Parents first, so children's parentID resolves.
      let categories = commit.newCategories
        .map { var c = $0; c.importBatchID = batchID; return c }
        .sorted { ($0.parentID == nil ? 0 : 1) < ($1.parentID == nil ? 0 : 1) }
      if !categories.isEmpty {
        try AbacusDomain.Category.insert { categories }.execute(db)
      }
      let events = commit.newEvents.map { var e = $0; e.importBatchID = batchID; return e }
      if !events.isEmpty {
        try Event.insert { events }.execute(db)
      }
      // R-MGMT-7: created accounts, categories and events get palette colours.
      if !accounts.isEmpty || !categories.isEmpty || !events.isEmpty {
        try ColorFill.fillAll(db)
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
      // R-DEBT-10/12: rows recorded as debt records become their legs, oldest first (a
      // suggested kind sees the records of earlier rows).
      let dates = Dictionary(commit.txns.map { ($0.txn.id, $0.txn.occurredAt) }, uniquingKeysWith: { a, _ in a })
      let links = commit.debtLinks.enumerated().sorted {
        (dates[$0.element.txnID] ?? .distantPast, $0.offset) < (dates[$1.element.txnID] ?? .distantPast, $1.offset)
      }
      for (_, item) in links {
        try DebtLinking.transfer(item.txnID, to: item.link, db)
      }
      // R-DEBT-17: a debt-kind account an import created (Saldo LIABILITIES) gets its debt.
      if convertsDebtAccounts { try DebtConversion.convertDebtAccounts(db, calendar: calendar) }
    }
  }

  /// Debts and records with their legs (R-DEBT-10/12: whom a row can be recorded for).
  public func debtBook() async throws -> DebtBook {
    try await database.read { db in try SQLiteDebtRepository.book(db) }
  }

  /// Import history, newest first.
  public func batches() async throws -> [ImportBatch] {
    try await database.read { db in
      try ImportBatch.order { ($0.importedAt.desc(), $0.id) }.fetchAll(db)
    }
  }

  /// R-IMP-6: deletes the batch's debt records and transactions (their legs, attached records and
  /// fingerprints go with them) and the fingerprints it added to existing transactions (links, settled upgrades), then
  /// the accounts, categories and events the batch created that nothing else uses any more, and
  /// marks the batch undone. Field changes of upgraded transactions stay.
  public func undo(_ batchID: ImportBatch.ID) async throws {
    try await database.write { db in
      guard let batch = try ImportBatch.find(batchID).fetchOne(db) else { throw RepositoryError.notFound }
      guard !batch.isUndone else { return }
      // Manual debt records the batch carries go with it; its transactions (transfers to a debt
      // account included) go next; debts the batch created are removed below, once nothing is
      // left in them.
      try DebtRecord.where { $0.importBatchID.eq(batchID) }.delete().execute(db)
      try Txn.where { $0.importBatchID.eq(batchID) }.delete().execute(db)
      try ImportFingerprint.where { $0.batchID.eq(batchID) }.delete().execute(db)

      let events = try Event.where { $0.importBatchID.eq(batchID) }.fetchAll(db)
      for event in events where try Txn.where({ $0.eventID.eq(event.id) }).fetchCount(db) == 0 {
        try Event.find(event.id).delete().execute(db)
      }
      // Children before parents, so a parent is unused once its created children are gone.
      let categories = try AbacusDomain.Category.where { $0.importBatchID.eq(batchID) }.fetchAll(db)
        .sorted { ($0.parentID == nil ? 1 : 0) < ($1.parentID == nil ? 1 : 0) }
      var removedCategories: [AbacusDomain.Category.ID] = []
      for category in categories {
        let id = category.id
        let used =
          try Txn.where({ $0.categoryID.eq(id) }).fetchCount(db) > 0
          || AttachedRecord.where({ $0.categoryID.eq(id) }).fetchCount(db) > 0
          || BudgetAllocation.where({ $0.categoryID.eq(id) }).fetchCount(db) > 0
          || AbacusDomain.Category.where({ $0.parentID.eq(id) }).fetchCount(db) > 0
        if !used {
          try AbacusDomain.Category.find(id).delete().execute(db)
          removedCategories.append(id)
        }
      }
      let accounts = try Account.where { $0.importBatchID.eq(batchID) }.fetchAll(db)
      var removedAccounts: [Account.ID] = []
      for account in accounts {
        let id = account.id
        if try Txn.where({ $0.accountID.eq(id) || $0.toAccountID.eq(id) }).fetchCount(db) == 0 {
          try Account.find(id).delete().execute(db)
          removedAccounts.append(id)
        }
      }
      // Debts the batch created that keep no manual record and no linked account (the batch's
      // own accounts are gone by now; their links went with them).
      for debt in try Debt.where({ $0.importBatchID.eq(batchID) }).fetchAll(db) {
        let debtID = debt.id
        if try DebtRecord.where({ $0.debtID.eq(debtID) }).fetchCount(db) == 0,
          try DebtAccountLink.where({ $0.debtID.eq(debtID) }).fetchCount(db) == 0
        {
          try Debt.find(debtID).delete().execute(db)
        }
      }
      let removed = removedCategories + removedAccounts
      if !removed.isEmpty {
        try ImportMapping.where { $0.targetID.in(removed) }.delete().execute(db)
      }
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
