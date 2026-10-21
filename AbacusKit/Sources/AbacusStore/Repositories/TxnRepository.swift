import AbacusDomain
import Foundation
import SQLiteData

/// Transactions with their attached records (R-TX) and the transaction list query (R-LIST).
public struct SQLiteTxnRepository: TxnRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  /// R-LIST-1…6: every `TxnQuery` filter, combined with AND:
  /// - dates: `fromDay`/`toDay` inclusive, as calendar days of `calendar`;
  /// - categories: a parent matches its children; a transaction also matches when one of its
  ///   attached records has a matching category;
  /// - accounts: either side of a transfer;
  /// - search: case-insensitive substring of the payee or note, or of an attached record's note.
  /// Sorted by `occurredAt` (then creation time) as `newestFirst` says.
  public func transactions(matching query: TxnQuery) async throws -> [TxnWithLines] {
    let filter = TxnFilter(query: query, bounds: DayBounds(calendar: calendar))
    return try await database.read { db in try filter.fetch(db) }
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
      let totals = try TxnTotals(
        rows, currencies: currencies, categoryIDs: filter.categoryIDs(db),
        refundsReduceSpending: reduce, calendar: calendar)
      return (rows, totals)
    }
  }

  /// Saves the transaction and replaces its attached records with `lines` (R-TX-6).
  public func save(_ txn: Txn, lines: [AttachedRecord]) async throws {
    try await database.write { db in try Self.save(txn, lines: lines, db) }
  }

  /// Deletes the transaction; attached records and fingerprints go with it (R-TX-6).
  public func delete(_ id: Txn.ID) async throws {
    try await database.write { db in
      try Txn.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  static func save(_ txn: Txn, lines: [AttachedRecord], _ db: Database) throws {
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
    let txnID = txn.id
    try AttachedRecord.where { $0.txnID.eq(txnID) }.delete().execute(db)
    try insertLines(lines, txnID: txnID, db)
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
  func categoryIDs(_ db: Database) throws -> Set<AbacusDomain.Category.ID>? {
    guard !query.categoryIDs.isEmpty else { return nil }
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
    if let categories = try categoryIDs(db) {
      let ids = sqlList(categories.sorted())
      parts.append(
        #"""
        ("txns"."categoryID" IN \#(ids) OR "txns"."id" IN (SELECT "r"."txnID" \#
        FROM "attachedRecords" AS "r" WHERE "r"."categoryID" IN \#(ids)))
        """#)
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

  func fetch(_ db: Database) throws -> [TxnWithLines] {
    let condition = SQLQueryExpression(try whereClause(db), as: Bool.self)
    let newestFirst = query.newestFirst
    let txns = try Txn
      .where { _ in condition }
      .order {
        if newestFirst {
          ($0.occurredAt.desc(), $0.createdAt.desc(), $0.id.desc())
        } else {
          ($0.occurredAt.asc(), $0.createdAt.asc(), $0.id.asc())
        }
      }
      .fetchAll(db)
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
}

// MARK: - Totals

/// R-LIST-5: income and expense of a filtered list, per currency and day (convert each bucket at
/// its day's rate, R-FX-3). Transfers count as neither (R-TX-5); attached records count by their
/// own kind (R-TX-6). With a category filter only the matching parts count (the main amount
/// when its category matches, each attached record whose category matches).
/// Refunds (R-TX-4, R-SET-3): an expense refund is income unless refunds reduce spending, then it
/// subtracts from expense; an income reversal subtracts from income.
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
    categoryIDs: Set<AbacusDomain.Category.ID>?, refundsReduceSpending: Bool, calendar: Calendar
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
    for row in rows {
      guard let currency = currencies[row.txn.accountID] else { continue }
      let key = Key(currency: currency, day: Day(row.txn.occurredAt, calendar: calendar))
      var income: Int64 = 0
      var expense: Int64 = 0
      let txn = row.txn
      if matches(txn.categoryID) {
        switch (txn.type, txn.isRefund) {
        case (.expense, false): expense += txn.amountMinor
        case (.expense, true):
          if refundsReduceSpending { expense -= txn.amountMinor } else { income += txn.amountMinor }
        case (.income, false): income += txn.amountMinor
        case (.income, true): income -= txn.amountMinor
        case (.transfer, _): break
        }
      }
      for line in row.lines where matches(line.categoryID) {
        switch line.kind {
        case .expense: expense += line.amountMinor
        case .income: income += line.amountMinor
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
