import AbacusDomain
import Foundation
import SQLiteData

// MARK: - Move an import batch to another account (C44)

extension SQLiteImportStore {
  /// C44: stored fingerprints among `ids` with their transaction and the accounts it is on now.
  public func fingerprintOwners(_ ids: [String]) async throws -> [String: FingerprintOwner] {
    let unique = Array(Set(ids))
    guard !unique.isEmpty else { return [:] }
    return try await database.read { db in
      var found: [String: FingerprintOwner] = [:]
      for chunk in unique.chunked(500) {
        let keys = Array(chunk)
        let fingerprints = try ImportFingerprint.where { $0.id.in(keys) }.fetchAll(db)
        let txnIDs = Array(Set(fingerprints.map(\.txnID)))
        let txns = try Txn.where { $0.id.in(txnIDs) }.fetchAll(db)
        let accounts = Dictionary(
          txns.map { ($0.id, Set([$0.accountID] + ($0.toAccountID.map { [$0] } ?? []))) },
          uniquingKeysWith: { a, _ in a })
        for fingerprint in fingerprints {
          guard let ids = accounts[fingerprint.txnID] else { continue }
          found[fingerprint.id] = FingerprintOwner(txnID: fingerprint.txnID, accountIDs: ids)
        }
      }
      return found
    }
  }

  /// C44: what "Move to another account" offers for a PKO batch: its own transactions (each
  /// movable or with the reason it is not) and the existing transactions it linked or settled,
  /// which stay. Throws `ImportMoveError.notMovable` for undone and non-PKO batches.
  public func movePlan(_ batchID: ImportBatch.ID) async throws -> ImportMovePlan {
    try await database.read { db in
      guard let batch = try ImportBatch.find(batchID).fetchOne(db) else { throw RepositoryError.notFound }
      guard let source = Self.movableSource(batch) else { throw ImportMoveError.notMovable }
      return ImportMovePlan(batch: batch, sourceAccountID: source, candidates: try Self.candidates(batch, from: source, db))
    }
  }

  /// C44: moves the batch's transactions `txnIDs` from account `from` to `to` in one database
  /// transaction (all or nothing): the side on `from` changes, everything else (category, notes,
  /// event, attached records, refund links, the other side of a transfer, the batch id) stays.
  /// The batch's PKO fingerprints of the moved transactions get their moved keys
  /// (`ImportFingerprint.movedID`), so a re-import of the statement finds them as imported in the
  /// new account and a fresh import into the old account is not blocked. When nothing of the
  /// batch's own is left on `from`, the batch belongs to `to` (History, undo) and, if it was the
  /// latest statement in its currency, the remembered "Import into" account follows.
  ///
  /// Every transaction is checked again (`ImportMoveCandidate.refusal(movingTo:)`); one refusal
  /// refuses the whole move. Moving the result's `txnIDs` back from `to` to `from` undoes it.
  @discardableResult
  public func move(
    _ batchID: ImportBatch.ID, txnIDs: [Txn.ID], from: Account.ID? = nil, to target: Account.ID,
    at date: Date = Date()
  ) async throws -> ImportMoveResult {
    try await database.write { db in
      guard let batch = try ImportBatch.find(batchID).fetchOne(db) else { throw RepositoryError.notFound }
      guard let batchSource = Self.movableSource(batch) else { throw ImportMoveError.notMovable }
      let source = from ?? batchSource
      guard let sourceAccount = try Account.find(source).fetchOne(db),
        let targetAccount = try Account.find(target).fetchOne(db),
        target != source, targetAccount.currency == sourceAccount.currency, !targetAccount.isArchived,
        targetAccount.kind != .debt
      else { throw ImportMoveError.invalidTarget }
      let ids = Array(Set(txnIDs))
      guard !ids.isEmpty else { throw ImportMoveError.nothingToMove }

      let candidates = Dictionary(
        try Self.candidates(batch, from: source, db).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      let refused = ids.filter { id in candidates[id].map { $0.refusal(movingTo: target) != nil } ?? true }
      guard refused.isEmpty else { throw ImportMoveError.refused(count: refused.count) }

      // Fingerprints: the batch's own PKO keys of these transactions get their moved keys.
      let fingerprints = try ImportFingerprint.where { $0.txnID.in(ids) && $0.batchID.eq(batchID) }.fetchAll(db)
      let rekeyed = fingerprints.filter { ImportFingerprint.movedID($0.id) != $0.id }
      let newKeys = rekeyed.map { ImportFingerprint.movedID($0.id) }
      let taken = try ImportFingerprint.where { $0.id.in(newKeys) }.fetchCount(db)
      guard taken == 0 else { throw ImportMoveError.alreadyInTarget(count: taken) }
      if !rekeyed.isEmpty {
        let oldKeys = rekeyed.map(\.id)
        try ImportFingerprint.where { $0.id.in(oldKeys) }.delete().execute(db)
        let moved = rekeyed.map { ImportFingerprint(id: ImportFingerprint.movedID($0.id), txnID: $0.txnID, batchID: $0.batchID) }
        try ImportFingerprint.insert { moved }.execute(db)
      }

      for id in ids {
        guard var txn = candidates[id]?.txn else { continue }
        if txn.accountID == source { txn.accountID = target }
        if txn.toAccountID == source { txn.toAccountID = target }
        try Txn.upsert { Txn.Draft(txn) }.execute(db)
        try Self.trace(txn: id, batch: batchID, from: source, to: target, at: date, db)
      }

      // The batch follows its rows once none of its own is left on the old account.
      let left = try Txn.where {
        $0.importBatchID.eq(batchID) && ($0.accountID.eq(source) || $0.toAccountID.eq(source))
      }.fetchCount(db)
      let batchMoved = batch.accountID == source && left == 0
      if batchMoved {
        try ImportBatch.find(batchID).update { $0.accountID = #bind(target) }.execute(db)
        try Self.rememberTarget(after: batch, from: source, to: target, currency: sourceAccount.currency, db)
      }
      return ImportMoveResult(batchID: batchID, from: source, to: target, txnIDs: ids.sorted { $0.uuidString < $1.uuidString }, batchMoved: batchMoved)
    }
  }

  /// C48: records "moved from `from`" on the transaction. Moving it back to the account its latest
  /// trace says it came from drops that trace instead, so Undo move (and moving back by hand) leaves
  /// the transaction as if it had never moved.
  static func trace(txn: Txn.ID, batch: ImportBatch.ID, from: Account.ID, to: Account.ID, at date: Date, _ db: Database) throws {
    let latest = try TxnMove.where { $0.txnID.eq(txn) }.fetchAll(db).max { $0.movedAt < $1.movedAt }
    if let latest, latest.fromAccountID == to {
      try TxnMove.find(latest.id).delete().execute(db)
    } else {
      try TxnMove.insert {
        TxnMove(txnID: txn, batchID: batch, fromAccountID: from, toAccountID: to, movedAt: date)
      }.execute(db)
    }
  }

  /// The account a batch can be moved from: a PKO statement's account, not undone.
  static func movableSource(_ batch: ImportBatch) -> Account.ID? {
    guard batch.source == .pko, !batch.isUndone else { return nil }
    return batch.accountID
  }

  /// The batch's own transactions (movable or not, with the reason) and the existing ones it
  /// linked or settled, by date.
  static func candidates(_ batch: ImportBatch, from source: Account.ID, _ db: Database) throws -> [ImportMoveCandidate] {
    let batchID = batch.id
    let own = try Txn.where { $0.importBatchID.eq(batchID) }.order { ($0.occurredAt, $0.id) }.fetchAll(db)
    let ownIDs = own.map(\.id)
    let ownSet = Set(ownIDs)
    // Existing transactions this batch linked a row to or settled: they carry its fingerprints.
    let linkedIDs = Array(
      Set(try ImportFingerprint.where { $0.batchID.eq(batchID) }.fetchAll(db).map(\.txnID)).subtracting(ownSet))
    let linked = linkedIDs.isEmpty ? [] : try Txn.where { $0.id.in(linkedIDs) }.fetchAll(db)

    // Later imports that touched the batch's own transactions (fingerprints, C38 snapshots).
    var otherBatch: [Txn.ID: ImportBatch.ID?] = [:]
    for fingerprint in try ImportFingerprint.where({ $0.txnID.in(ownIDs) }).fetchAll(db) where fingerprint.batchID != batchID {
      otherBatch[fingerprint.txnID] = fingerprint.batchID
    }
    for snapshot in try ImportTxnSnapshot.where({ $0.txnID.in(ownIDs) }).fetchAll(db) where snapshot.batchID != batchID {
      otherBatch[snapshot.txnID] = snapshot.batchID
    }
    let otherIDs = Array(Set(otherBatch.values.compactMap { $0 }))
    let fileNames = Dictionary(
      try ImportBatch.where { $0.id.in(otherIDs) }.fetchAll(db).map { ($0.id, $0.fileName) }, uniquingKeysWith: { a, _ in a })

    let debtAccounts = Set(try Account.where { $0.kind.eq(AccountKind.debt) }.fetchAll(db).map(\.id))
    let refundOriginals = Set(
      try Txn.where { $0.refundOfID.in(ownIDs.map { Optional($0) }) }.fetchAll(db).compactMap(\.refundOfID))
    let categoryIDs = Array(Set((own + linked).compactMap(\.categoryID)))
    let categoryNames = Dictionary(
      try AbacusDomain.Category.where { $0.id.in(categoryIDs) }.fetchAll(db).map { ($0.id, $0.name) },
      uniquingKeysWith: { a, _ in a })

    var result: [ImportMoveCandidate] = []
    for txn in own {
      var notes: [ImportMoveNote] = []
      let other: Account.ID? = txn.type == .transfer ? (txn.accountID == source ? txn.toAccountID : txn.accountID) : nil
      if let other { notes.append(.transfer(otherAccountID: other)) }
      if txn.refundOfID != nil || refundOriginals.contains(txn.id) { notes.append(.refundLink) }
      if txn.isPendingAtBank { notes.append(.pending) }
      var refusal: ImportMoveRefusal?
      if txn.accountID != source, txn.toAccountID != source {
        refusal = .notOnSource(accountIDs: [txn.accountID] + (txn.toAccountID.map { [$0] } ?? []))
      } else if txn.debtRecordID != nil || other.map(debtAccounts.contains) == true {
        refusal = .debt
      } else if let later = otherBatch[txn.id] {
        refusal = .laterImport(fileName: later.flatMap { fileNames[$0] })
      }
      result.append(
        ImportMoveCandidate(
          txn: txn, refusal: refusal, notes: notes, categoryName: txn.categoryID.flatMap { categoryNames[$0] }))
    }
    for txn in linked {
      result.append(
        ImportMoveCandidate(txn: txn, refusal: .notOwn, categoryName: txn.categoryID.flatMap { categoryNames[$0] }))
    }
    return result.sorted { ($0.txn.occurredAt, $0.txn.id.uuidString) < ($1.txn.occurredAt, $1.txn.id.uuidString) }
  }

  /// When the moved batch is the latest PKO statement in its currency, the remembered "Import
  /// into" account of that currency (`statement|<currency>`, R-IMP-PKO-1; same key as
  /// `ImportPipeline.statementKey`) follows it, if it pointed at the old account.
  static func rememberTarget(after batch: ImportBatch, from: Account.ID, to: Account.ID, currency: Currency, _ db: Database)
    throws
  {
    let accounts = Dictionary(try Account.all.fetchAll(db).map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })
    let latest = try ImportBatch.where { $0.source.eq(ImportSource.pko) && !$0.isUndone }
      .order { ($0.importedAt.desc(), $0.id) }
      .fetchAll(db)
      .first { $0.accountID.flatMap { accounts[$0] } == currency || $0.id == batch.id }
    guard latest?.id == batch.id else { return }
    let key = "statement|\(currency.rawValue)"
    try ImportMapping
      .where { $0.source.eq(ImportSource.pko) && $0.kind.eq(MappingKind.account) && $0.externalKey.eq(key) && $0.targetID.eq(from) }
      .update { $0.targetID = #bind(to) }
      .execute(db)
  }
}

// MARK: - Trace of moves (C48)

extension SQLiteImportStore: TxnMoveReading {
  public func moves(for txnIDs: [Txn.ID]) async throws -> [Txn.ID: TxnMove] {
    let unique = Array(Set(txnIDs))
    guard !unique.isEmpty else { return [:] }
    return try await database.read { db in
      var latest: [Txn.ID: TxnMove] = [:]
      for chunk in unique.chunked(500) {
        let keys = Array(chunk)
        for move in try TxnMove.where({ $0.txnID.in(keys) }).fetchAll(db) {
          if let known = latest[move.txnID], known.movedAt >= move.movedAt { continue }
          latest[move.txnID] = move
        }
      }
      return latest
    }
  }
}
