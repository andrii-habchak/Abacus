import AbacusDomain
import Foundation
import SQLiteData

/// Transactions with their attached records (R-TX) and the transaction list query (R-LIST).
public struct SQLiteTxnRepository: TxnRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar
  /// Rates for checking a refund in another currency than its original on save (C30); without
  /// them only same-currency refunds are checked.
  let converter: @Sendable () async -> (any CurrencyConverter)?

  public init(
    database: any DatabaseWriter, calendar: Calendar = .current,
    converter: @escaping @Sendable () async -> (any CurrencyConverter)? = { nil }
  ) {
    self.database = database
    self.calendar = calendar
    self.converter = converter
  }

  /// R-LIST-1…6: every `TxnQuery` filter, combined with AND:
  /// - dates: `fromDay`/`toDay` inclusive, as calendar days of `calendar`;
  /// - categories: a parent matches its children; a transaction also matches when one of its
  ///   attached records has a matching category; `includeUncategorised` adds expenses and
  ///   incomes without a category of their own (transfers never match it);
  /// - import batches: only transactions created by one of `importBatchIDs`;
  /// - accounts: either side of a transfer;
  /// - search: case-insensitive substring of the payee or note, or of an attached record's note.
  /// Sorted by `occurredAt` (then creation time) as `newestFirst` says.
  public func transactions(matching query: TxnQuery) async throws -> [TxnWithLines] {
    let filter = TxnFilter(query: query, bounds: DayBounds(calendar: calendar))
    return try await database.read { db in try filter.fetch(db) }
  }

  /// C28: one page of `transactions(matching:)` (same order); an offset past the end gives [].
  public func page(matching query: TxnQuery, offset: Int, limit: Int) async throws -> [TxnWithLines] {
    let filter = TxnFilter(query: query, bounds: DayBounds(calendar: calendar))
    return try await database.read { db in try filter.fetch(db, offset: offset, limit: limit) }
  }

  /// C28: count and amounts of the whole filtered set by aggregate queries (no rows decoded).
  public func summary(matching query: TxnQuery) async throws -> TxnListSummary {
    let filter = TxnFilter(query: query, bounds: DayBounds(calendar: calendar))
    return try await database.read { db in try filter.summary(db) }
  }

  /// C28: per-value counts of one dimension under the other filters (GROUP BY queries).
  public func facets(matching query: TxnQuery, dimension: TxnFacetDimension) async throws -> TxnFacetCounts {
    let filter = TxnFilter(query: query.dropping(dimension), bounds: DayBounds(calendar: calendar))
    return try await database.read { db in try filter.facets(db, dimension: dimension) }
  }

  /// One transaction with its attached records.
  public func transaction(_ id: Txn.ID) async throws -> TxnWithLines? {
    try await database.read { db in
      guard let txn = try Txn.find(id).fetchOne(db) else { return nil }
      let lines = try AttachedRecord
        .where { $0.txnID.eq(id) }
        .order { ($0.position, $0.id) }
        .fetchAll(db)
      return TxnWithLines(txn: txn, lines: lines)
    }
  }

  /// R-LIST-5: the list and its income / expense totals, bucketed by currency and day so the
  /// caller converts each at its date's rate (R-FX-3). Refunds follow R-SET-3 unless given.
  public func list(
    matching query: TxnQuery, refundsReduceSpending: Bool? = nil
  ) async throws -> (rows: [TxnWithLines], totals: TxnTotals) {
    let filter = TxnFilter(query: query, bounds: DayBounds(calendar: calendar))
    let calendar = self.calendar
    return try await database.read { db in
      let rows = try filter.fetch(db)
      let currencies = try Dictionary(
        uniqueKeysWithValues: Account.fetchAll(db).map { ($0.id, $0.currency) })
      let reduce = try refundsReduceSpending ?? SQLiteSettingsRepository.refundsReduceSpending(db)
      let expenseCategories = try Set(
        AbacusDomain.Category.where { $0.kind.eq(CategoryKind.expense) }.select(\.id).fetchAll(db))
      let totals = try TxnTotals(
        rows, currencies: currencies, categoryIDs: filter.categoryIDs(db),
        includeUncategorised: filter.query.includeUncategorised, refundsReduceSpending: reduce, expenseCategoryIDs: expenseCategories, calendar: calendar)
      return (rows, totals)
    }
  }

  /// Saves the transaction and replaces its attached records with `lines` (R-TX-6).
  /// A refund link it carries must keep the original valid and within its amount (C30):
  /// `RefundError.invalidOriginal` / `exceedsOriginal`.
  public func save(_ txn: Txn, lines: [AttachedRecord]) async throws {
    let rates = txn.refundOfID == nil ? nil : await converter()
    let calendar = self.calendar
    try await database.write { db in
      if txn.isLinkedRefund, let originalID = txn.refundOfID {
        guard let original = try Txn.find(originalID).fetchOne(db), RefundRules.canBeOriginal(original),
          original.id != txn.id
        else { throw RefundError.invalidOriginal }
        try RefundRules.checkCap(
          txn, against: original, currencies: try RefundRules.currencies(db), rates: rates, calendar: calendar,
          lenient: true, db)
      }
      try Self.save(txn, lines: lines, db)
    }
  }

  /// Deletes the transaction; attached records and fingerprints go with it (R-TX-6). A debt
  /// record's leg takes its record with it (R-DEBT-3), so no record is left without its money.
  public func delete(_ id: Txn.ID) async throws {
    try await database.write { db in
      if let recordID = try Txn.find(id).fetchOne(db)?.debtRecordID {
        try DebtRecord.find(recordID).delete().execute(db)
        try RefundLinks.repair(db)
        return
      }
      try Txn.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
      // C30: refunds linked to the deleted expense become unlinked and keep their own category.
      try RefundLinks.repair(db)
    }
  }

  static func save(_ txn: Txn, lines: [AttachedRecord], _ db: Database) throws {
    var txn = txn
    // A link only lives on an expense refund (C30); the original's category follows it below.
    if !(txn.type == .expense && txn.isRefund) { txn.refundOfID = nil }
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
    let txnID = txn.id
    try AttachedRecord.where { $0.txnID.eq(txnID) }.delete().execute(db)
    try insertLines(lines, txnID: txnID, db)
    try RefundLinks.repair(db)
  }

  static func insertLines(_ lines: [AttachedRecord], txnID: Txn.ID, _ db: Database) throws {
    guard !lines.isEmpty else { return }
    let rows = lines.enumerated().map { index, line in
      var line = line
      line.txnID = txnID
      if line.position == 0 { line.position = index }
      return line
    }
    try AttachedRecord.insert { rows }.execute(db)
  }
}

// MARK: - Filter

/// `TxnQuery` as SQL over `"txns"`.
struct TxnFilter: Sendable {
  var query: TxnQuery
  var bounds: DayBounds

  /// Selected categories plus the children of selected parents (R-LIST-2), or nil for "any".
  /// Only "Uncategorised" selected: an empty set (no category matches, see `includeUncategorised`).
  func categoryIDs(_ db: Database) throws -> Set<AbacusDomain.Category.ID>? {
    guard !query.categoryIDs.isEmpty else { return query.includeUncategorised ? [] : nil }
    let selected = Array(query.categoryIDs)
    let children = try AbacusDomain.Category
      .where { $0.parentID.in(selected.map(Optional.some)) }
      .select(\.id)
      .fetchAll(db)
    return query.categoryIDs.union(children)
  }

  func whereClause(_ db: Database) throws -> QueryFragment {
    var parts: [QueryFragment] = []
    if let from = query.fromDay {
      parts.append(#""txns"."occurredAt" >= \#(bounds.start(from))"#)
    }
    if let to = query.toDay {
      parts.append(#""txns"."occurredAt" < \#(bounds.end(to))"#)
    }
    if !query.types.isEmpty {
      parts.append(#""txns"."type" IN \#(sqlList(query.types.sorted { $0.rawValue < $1.rawValue }))"#)
    }
    if !query.accountIDs.isEmpty {
      let ids = sqlList(query.accountIDs.sorted())
      parts.append(#"("txns"."accountID" IN \#(ids) OR "txns"."toAccountID" IN \#(ids))"#)
    }
    if !query.eventIDs.isEmpty {
      parts.append(#""txns"."eventID" IN \#(sqlList(query.eventIDs.sorted()))"#)
    }
    if !query.importBatchIDs.isEmpty {
      parts.append(#""txns"."importBatchID" IN \#(sqlList(query.importBatchIDs.sorted()))"#)
    }
    if let categories = try categoryIDs(db) {
      var alternatives: [QueryFragment] = []
      if query.includeUncategorised {
        if query.uncategorisedIncludesTransfers {
          alternatives.append(#"("txns"."categoryID" IS NULL)"#)
        } else {
          let kinds = sqlList([TxnType.expense, TxnType.income])
          alternatives.append(#"("txns"."type" IN \#(kinds) AND "txns"."categoryID" IS NULL)"#)
        }
      }
      if !categories.isEmpty {
        let ids = sqlList(categories.sorted())
        alternatives.append(
          #"""
          "txns"."categoryID" IN \#(ids) OR "txns"."id" IN (SELECT "r"."txnID" \#
          FROM "attachedRecords" AS "r" WHERE "r"."categoryID" IN \#(ids))
          """#)
      }
      parts.append("(" + alternatives.joined(separator: " OR ") + ")")
    }
    let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !needle.isEmpty {
      parts.append(
        #"""
        (instr(swiftLowercaseString("txns"."payee"), \#(bind: needle)) > 0 \#
        OR instr(swiftLowercaseString("txns"."note"), \#(bind: needle)) > 0 \#
        OR EXISTS (SELECT 1 FROM "attachedRecords" AS "r" WHERE "r"."txnID" = "txns"."id" \#
        AND instr(swiftLowercaseString("r"."note"), \#(bind: needle)) > 0))
        """#)
    }
    return parts.isEmpty ? "1" : parts.joined(separator: " AND ")
  }

  func fetch(_ db: Database, offset: Int = 0, limit: Int? = nil) throws -> [TxnWithLines] {
    let condition = SQLQueryExpression(try whereClause(db), as: Bool.self)
    let newestFirst = query.newestFirst
    let ordered = Txn
      .where { _ in condition }
      .order {
        if newestFirst {
          ($0.occurredAt.desc(), $0.createdAt.desc(), $0.id.desc())
        } else {
          ($0.occurredAt.asc(), $0.createdAt.asc(), $0.id.asc())
        }
      }
    let txns: [Txn]
    if let limit {
      txns = try ordered.limit(limit, offset: offset).fetchAll(db)
    } else {
      txns = try ordered.fetchAll(db)
    }
    guard !txns.isEmpty else { return [] }
    // Lines of the fetched transactions, by id in chunks (an index lookup per id).
    var lines: [AttachedRecord] = []
    for chunk in txns.map(\.id).chunked(500) {
      let ids = Array(chunk)
      lines += try AttachedRecord
        .where { $0.txnID.in(ids) }
        .order { ($0.txnID, $0.position, $0.id) }
        .fetchAll(db)
    }
    let linesByTxn = Dictionary(grouping: lines, by: \.txnID)
    return txns.map { TxnWithLines(txn: $0, lines: linesByTxn[$0.id] ?? []) }
  }

  // MARK: Aggregates (C28)

  /// The filtered set's count and amounts, grouped by minute / account / type / refund flag /
  /// category in SQL. A minute never straddles two calendar days (every UTC offset is a whole
  /// number of minutes), so the caller buckets each group by its local day.
  func summary(_ db: Database) throws -> TxnListSummary {
    let condition = try whereClause(db)
    let count = try SQLQueryExpression(
      #"SELECT count(*) FROM "txns" WHERE \#(condition)"# as QueryFragment, as: Int.self
    ).fetchOne(db) ?? 0
    let mains = try SQLQueryExpression(
      #"""
      SELECT MIN("txns"."occurredAt"), "txns"."accountID", "txns"."type", "txns"."isRefund", \#
      "txns"."categoryID", SUM("txns"."amountMinor"), ("txns"."refundOfID" IS NOT NULL)
      FROM "txns" WHERE NOT "txns"."isBalanceCorrection" AND \#(condition)
      GROUP BY substr("txns"."occurredAt", 1, 16), "txns"."accountID", "txns"."type", "txns"."isRefund", \#
      "txns"."categoryID", ("txns"."refundOfID" IS NOT NULL)
      """# as QueryFragment, as: MainFlowRow.self
    ).fetchAll(db)
    let lines = try SQLQueryExpression(
      #"""
      SELECT MIN("txns"."occurredAt"), "txns"."accountID", "ln"."kind", "ln"."categoryID", \#
      SUM("ln"."amountMinor")
      FROM "attachedRecords" AS "ln" JOIN "txns" ON "txns"."id" = "ln"."txnID" \#
      WHERE NOT "txns"."isBalanceCorrection" AND \#(condition)
      GROUP BY substr("txns"."occurredAt", 1, 16), "txns"."accountID", "ln"."kind", "ln"."categoryID"
      """# as QueryFragment, as: LineFlowRow.self
    ).fetchAll(db)
    return TxnListSummary(
      count: count,
      mains: mains.map {
        .init(
          occurredAt: $0.occurredAt, accountID: $0.accountID, type: $0.type, isRefund: $0.isRefund,
          categoryID: $0.categoryID, amountMinor: $0.amountMinor, isLinkedRefund: $0.isLinked)
      },
      lines: lines.map {
        .init(
          occurredAt: $0.occurredAt, accountID: $0.accountID, kind: $0.kind, categoryID: $0.categoryID,
          amountMinor: $0.amountMinor)
      })
  }

  /// Row counts per value of `dimension` (this filter already has the dimension's own part
  /// dropped).
  func facets(_ db: Database, dimension: TxnFacetDimension) throws -> TxnFacetCounts {
    let condition = try whereClause(db)
    var counts = TxnFacetCounts()
    switch dimension {
    case .accounts:
      let rows = try SQLQueryExpression(
        #"""
        SELECT "a", count(*) FROM (
          SELECT "accountID" AS "a" FROM "txns" WHERE \#(condition)
          UNION ALL
          SELECT "toAccountID" FROM "txns"
          WHERE "toAccountID" IS NOT NULL AND "toAccountID" <> "accountID" AND \#(condition)
        ) GROUP BY "a"
        """# as QueryFragment, as: FacetRow.self
      ).fetchAll(db)
      for row in rows { counts.accounts[row.key] = row.n }
    case .categories:
      let own = try SQLQueryExpression(
        #"""
        SELECT "categoryID", count(*) FROM "txns" WHERE "categoryID" IS NOT NULL AND \#(condition)
        GROUP BY "categoryID"
        """# as QueryFragment, as: FacetRow.self
      ).fetchAll(db)
      for row in own { counts.categories[row.key, default: 0] += row.n }
      let attached = try SQLQueryExpression(
        #"""
        SELECT "ln"."categoryID", count(DISTINCT "ln"."txnID")
        FROM "attachedRecords" AS "ln" JOIN "txns" ON "txns"."id" = "ln"."txnID"
        WHERE "ln"."categoryID" IS NOT NULL AND \#(condition)
        GROUP BY "ln"."categoryID"
        """# as QueryFragment, as: FacetRow.self
      ).fetchAll(db)
      for row in attached { counts.categories[row.key, default: 0] += row.n }
      let kinds = sqlList([TxnType.expense, TxnType.income])
      let typeClause: QueryFragment =
        query.uncategorisedIncludesTransfers ? "1" : #""type" IN \#(kinds)"#
      counts.uncategorised =
        try SQLQueryExpression(
          #"""
          SELECT count(*) FROM "txns" WHERE "categoryID" IS NULL AND \#(typeClause) AND \#(condition)
          """# as QueryFragment, as: Int.self
        ).fetchOne(db) ?? 0
    case .events:
      let rows = try SQLQueryExpression(
        #"""
        SELECT "eventID", count(*) FROM "txns" WHERE "eventID" IS NOT NULL AND \#(condition)
        GROUP BY "eventID"
        """# as QueryFragment, as: FacetRow.self
      ).fetchAll(db)
      for row in rows { counts.events[row.key] = row.n }
    case .types:
      let rows = try SQLQueryExpression(
        #"""
        SELECT "type", count(*) FROM "txns" WHERE \#(condition) GROUP BY "type"
        """# as QueryFragment, as: TypeFacetRow.self
      ).fetchAll(db)
      for row in rows { counts.types[row.type] = row.n }
    }
    return counts
  }
}

@Selection
struct MainFlowRow: Sendable {
  var occurredAt: Date
  var accountID: UUID
  var type: TxnType
  var isRefund: Bool
  var categoryID: UUID?
  var amountMinor: Int64
  var isLinked: Bool
}

@Selection
struct LineFlowRow: Sendable {
  var occurredAt: Date
  var accountID: UUID
  var kind: CategoryKind
  var categoryID: UUID?
  var amountMinor: Int64
}

@Selection
struct FacetRow: Sendable {
  var key: UUID
  var n: Int
}

@Selection
struct TypeFacetRow: Sendable {
  var type: TxnType
  var n: Int
}

// MARK: - Totals

/// R-LIST-5: income and expense of a filtered list, per currency and day (convert each bucket at
/// its day's rate, R-FX-3). Transfers count as neither (R-TX-5); attached records count by their
/// own kind (R-TX-6). With a category filter only the matching parts count (the main amount
/// when its category matches, each attached record whose category matches); with
/// `includeUncategorised` the main amount of an expense or income without a category matches
/// too (attached records without a category do not).
/// Refunds (R-TX-4, R-SET-3): an expense refund is income unless refunds reduce spending, then it
/// subtracts from expense (a refund linked to its original, C30, always does); an income reversal subtracts from income. An income attached record
/// in an expense category is a refund line (D22) and counts the same way.
public struct TxnTotals: Hashable, Sendable {
  public struct Bucket: Hashable, Sendable {
    public var currency: Currency
    public var day: Day
    public var incomeMinor: Int64
    public var expenseMinor: Int64
  }

  public var buckets: [Bucket]

  public init(buckets: [Bucket]) {
    self.buckets = buckets
  }

  public init(
    _ rows: [TxnWithLines], currencies: [Account.ID: Currency],
    categoryIDs: Set<AbacusDomain.Category.ID>?, includeUncategorised: Bool = false,
    refundsReduceSpending: Bool,
    expenseCategoryIDs: Set<AbacusDomain.Category.ID> = [], calendar: Calendar
  ) {
    struct Key: Hashable {
      var currency: Currency
      var day: Day
    }
    var sums: [Key: (income: Int64, expense: Int64)] = [:]
    func matches(_ id: AbacusDomain.Category.ID?) -> Bool {
      guard let categoryIDs else { return true }
      return id.map(categoryIDs.contains) ?? false
    }
    func mainMatches(_ id: AbacusDomain.Category.ID?) -> Bool {
      if id == nil, categoryIDs != nil, includeUncategorised { return true }
      return matches(id)
    }
    for row in rows {
      guard let currency = currencies[row.txn.accountID] else { continue }
      let key = Key(currency: currency, day: Day(row.txn.occurredAt, calendar: calendar))
      var income: Int64 = 0
      var expense: Int64 = 0
      let txn = row.txn
      if mainMatches(txn.categoryID) {
        switch (txn.type, txn.isRefund) {
        case (.expense, false): expense += txn.amountMinor
        case (.expense, true):
          // C30: a linked refund always nets its category's spending.
          if refundsReduceSpending || txn.refundOfID != nil { expense -= txn.amountMinor } else { income += txn.amountMinor }
        case (.income, false): income += txn.amountMinor
        case (.income, true): income -= txn.amountMinor
        case (.transfer, _): break
        }
      }
      for line in row.lines where matches(line.categoryID) {
        switch line.kind {
        case .expense: expense += line.amountMinor
        case .income:
          let isRefundLine = line.categoryID.map(expenseCategoryIDs.contains) ?? false
          if isRefundLine && refundsReduceSpending {
            expense -= line.amountMinor
          } else {
            income += line.amountMinor
          }
        }
      }
      guard income != 0 || expense != 0 else { continue }
      sums[key, default: (0, 0)].income += income
      sums[key, default: (0, 0)].expense += expense
    }
    buckets = sums
      .map { Bucket(currency: $0.key.currency, day: $0.key.day, incomeMinor: $0.value.income, expenseMinor: $0.value.expense) }
      .sorted { ($0.day, $0.currency.rawValue) < ($1.day, $1.currency.rawValue) }
  }

  /// Income, expense and net in `currency`, each bucket at its day's rate. `unconverted` counts
  /// buckets without a known rate (left out of the sums).
  public func converted(
    to currency: Currency, using converter: any CurrencyConverter
  ) -> (income: Money, expense: Money, net: Money, unconverted: Int) {
    var income = Money.zero(currency)
    var expense = Money.zero(currency)
    var unconverted = 0
    for bucket in buckets {
      guard
        let i = converter.convert(Money(minorUnits: bucket.incomeMinor, currency: bucket.currency), to: currency, on: bucket.day),
        let e = converter.convert(Money(minorUnits: bucket.expenseMinor, currency: bucket.currency), to: currency, on: bucket.day)
      else {
        unconverted += 1
        continue
      }
      income = income + i
      expense = expense + e
    }
    return (income, expense, income - expense, unconverted)
  }
}
