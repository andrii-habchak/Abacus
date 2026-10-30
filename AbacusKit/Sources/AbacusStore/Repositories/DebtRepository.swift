import AbacusDomain
import Foundation
import SQLiteData

/// Debts, their linked accounts and manual records (R-DEBT-16…20; docs/status/C19.md).
public struct SQLiteDebtRepository: DebtRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar

  public init(database: any DatabaseWriter, calendar: Calendar = .current) {
    self.database = database
    self.calendar = calendar
  }

  /// The name of the category flagged records are reported under (R-DEBT-4).
  public static let categoryName = "Debts"

  public func book() async throws -> DebtBook {
    try await database.read { db in try Self.book(db) }
  }

  /// The book inside the caller's database transaction: debts, links, linked accounts, every
  /// transaction touching them (with attached records) and the manual records.
  static func book(_ db: Database) throws -> DebtBook {
    let debts = try Debt.order { ($0.personName, $0.id) }.fetchAll(db)
    let links = try DebtAccountLink.order { ($0.createdAt, $0.accountID) }.fetchAll(db)
    let records = try DebtRecord.order { ($0.day, $0.createdAt, $0.id) }.fetchAll(db)
    guard !links.isEmpty else { return DebtBook(debts: debts, records: records) }
    let ids = links.map(\.accountID)
    var accounts: [Account] = []
    var txns: [Txn] = []
    var seen: Set<Txn.ID> = []
    for chunk in ids.chunked(400) {
      let part = Array(chunk)
      accounts += try Account.where { $0.id.in(part) }.fetchAll(db)
      let optional = part.map(Optional.some)
      for txn in try Txn.where({ $0.accountID.in(part) || $0.toAccountID.in(optional) }).fetchAll(db)
      where seen.insert(txn.id).inserted {
        txns.append(txn)
      }
    }
    accounts.sort { ($0.position, $0.name, $0.id.uuidString) < ($1.position, $1.name, $1.id.uuidString) }
    txns.sort { ($0.occurredAt, $0.createdAt, $0.id.uuidString) < ($1.occurredAt, $1.createdAt, $1.id.uuidString) }
    var lines: [Txn.ID: [AttachedRecord]] = [:]
    for chunk in txns.map(\.id).chunked(400) {
      let part = Array(chunk)
      for line in try AttachedRecord.where { $0.txnID.in(part) }.order { ($0.position, $0.id) }.fetchAll(db) {
        lines[line.txnID, default: []].append(line)
      }
    }
    return DebtBook(
      debts: debts, links: links, accounts: accounts,
      txns: txns.map { TxnWithLines(txn: $0, lines: lines[$0.id] ?? []) }, records: records)
  }

  // MARK: Debts

  public func save(_ debt: Debt) async throws {
    try await database.write { db in try Self.save(debt, db) }
  }

  static func save(_ debt: Debt, _ db: Database) throws {
    let key = debt.personKey
    let others = try Debt.fetchAll(db).filter { $0.id != debt.id && $0.personKey == key }
    if let other = others.first { throw DebtRepositoryError.personExists(other.id) }
    try Debt.upsert { Debt.Draft(debt) }.execute(db)
  }

  public func delete(_ id: Debt.ID) async throws {
    try await database.write { db in
      guard try Debt.find(id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
      // Records and links cascade from the debt; accounts and their transactions stay.
      try Debt.find(id).delete().execute(db)
    }
  }

  // MARK: Manual records

  public func save(_ record: DebtRecord) async throws {
    try await database.write { db in try Self.save(record, db) }
  }

  /// `save(_:)` inside the caller's database transaction (sample data, tests).
  public static func save(_ record: DebtRecord, _ db: Database) throws {
    guard try Debt.find(record.debtID).fetchCount(db) > 0 else { throw RepositoryError.notFound }
    guard record.amountMinor >= 0, Day(record.day) != nil else { throw DebtRepositoryError.invalidRecord }
    var record = record
    if let kind = record.reportKind, record.categoryID == nil {
      record.categoryID = try Self.debtsCategory(kind, db)
    }
    try DebtRecord.upsert { DebtRecord.Draft(record) }.execute(db)
  }

  public func deleteRecord(_ id: DebtRecord.ID) async throws {
    try await database.write { db in
      try DebtRecord.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  // MARK: Linked accounts (R-DEBT-17)

  public func link(_ accountID: Account.ID, to debtID: Debt.ID, role: DebtAccountRole) async throws {
    try await database.write { db in try Self.link(accountID, to: debtID, role: role, db) }
  }

  static func link(_ accountID: Account.ID, to debtID: Debt.ID, role: DebtAccountRole, _ db: Database) throws {
    guard try Debt.find(debtID).fetchCount(db) > 0, try Account.find(accountID).fetchCount(db) > 0 else {
      throw RepositoryError.notFound
    }
    if let existing = try DebtAccountLink.find(accountID).fetchOne(db) {
      guard existing.debtID == debtID else { throw DebtRepositoryError.accountLinkedElsewhere(existing.debtID) }
      var updated = existing
      updated.role = role
      try DebtAccountLink.upsert { DebtAccountLink.Draft(updated) }.execute(db)
      return
    }
    try DebtAccountLink.insert { DebtAccountLink(accountID: accountID, debtID: debtID, role: role) }.execute(db)
  }

  public func unlink(_ accountID: Account.ID) async throws {
    try await database.write { db in try DebtAccountLink.find(accountID).delete().execute(db) }
  }

  @discardableResult
  public func createVirtualAccount(
    for debtID: Debt.ID, currency: Currency, name: String?, openingBalanceMinor: Int64
  ) async throws -> Account {
    try await database.write { db in
      try Self.createVirtualAccount(
        for: debtID, currency: currency, name: name, openingBalanceMinor: openingBalanceMinor, importBatchID: nil, db)
    }
  }

  public static func createVirtualAccount(
    for debtID: Debt.ID, currency: Currency, name: String?, openingBalanceMinor: Int64 = 0,
    importBatchID: ImportBatch.ID?, _ db: Database
  ) throws -> Account {
    guard let debt = try Debt.find(debtID).fetchOne(db) else { throw RepositoryError.notFound }
    let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = given.isEmpty ? "\(debt.personName.trimmingCharacters(in: .whitespacesAndNewlines)) (\(currency.rawValue))" : given
    let position = (try Account.fetchAll(db).map(\.position).max() ?? 0) + 1
    let account = Account(
      name: title, currency: currency, kind: .debt, openingBalanceMinor: openingBalanceMinor, openingDate: Date(),
      position: position, importBatchID: importBatchID)
    try Account.insert { account }.execute(db)
    try ColorFill.fillAccounts(db)
    try DebtAccountLink.insert { DebtAccountLink(accountID: account.id, debtID: debtID, role: .virtual) }.execute(db)
    return try Account.find(account.id).fetchOne(db) ?? account
  }

  // MARK: Names (R-DEBT-16)

  public func personNames(matching text: String) async throws -> [String] {
    let debts = try await database.read { db in try Debt.fetchAll(db) }
    return DebtBook(debts: debts).personNames(matching: text)
  }

  // MARK: Reports

  /// The top-level, non-archived "Debts" category of `kind`, created when missing (R-DEBT-4).
  static func debtsCategory(_ kind: CategoryKind, _ db: Database) throws -> AbacusDomain.Category.ID {
    let name = categoryName
    let found = try AbacusDomain.Category
      .where { $0.name.eq(name) && $0.kind.eq(kind) && $0.parentID.is(nil) && !$0.isArchived }
      .order { $0.position }
      .fetchOne(db)
    if let found { return found.id }
    let tops = try AbacusDomain.Category.where { $0.kind.eq(kind) && $0.parentID.is(nil) }.fetchAll(db)
    let category = AbacusDomain.Category(name: name, kind: kind, position: (tops.map(\.position).max() ?? 0) + 1)
    try AbacusDomain.Category.insert { category }.execute(db)
    try ColorFill.fillCategories(db)
    return category.id
  }
}
