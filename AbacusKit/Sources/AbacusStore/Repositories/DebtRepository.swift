import AbacusDomain
import Foundation
import SQLiteData

/// Debts, records and their legs (R-DEBT; docs/status/C14.md).
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

  static func book(_ db: Database) throws -> DebtBook {
    let debts = try Debt.order { ($0.personName, $0.currency, $0.id) }.fetchAll(db)
    let records = try DebtRecord.order { ($0.day, $0.createdAt, $0.id) }.fetchAll(db)
    let legs = try Txn.where { $0.debtRecordID.isNot(nil) }.fetchAll(db)
    var legByRecord: [DebtRecord.ID: Txn] = [:]
    for leg in legs {
      if let id = leg.debtRecordID { legByRecord[id] = leg }
    }
    return DebtBook(debts: debts, entries: records.map { DebtRecordEntry(record: $0, leg: legByRecord[$0.id]) })
  }

  public func save(_ debt: Debt) async throws {
    try await database.write { db in
      if let existing = try Debt.find(debt.id).fetchOne(db), existing.currency != debt.currency {
        let debtID = debt.id
        if try DebtRecord.where({ $0.debtID.eq(debtID) }).fetchCount(db) > 0 {
          throw DebtRepositoryError.currencyLocked
        }
      }
      try Debt.upsert { Debt.Draft(debt) }.execute(db)
    }
  }

  public func delete(_ id: Debt.ID) async throws {
    try await database.write { db in
      guard try Debt.find(id).fetchCount(db) > 0 else { throw RepositoryError.notFound }
      // Records cascade from the debt, legs from the records.
      try Debt.find(id).delete().execute(db)
    }
  }

  public func save(_ record: DebtRecord, leg: DebtLegInput?) async throws {
    let calendar = self.calendar
    try await database.write { db in try Self.save(record, leg: leg, calendar: calendar, db) }
  }

  /// `save(_:leg:)` inside the caller's database transaction (sample data, tests).
  public static func save(_ record: DebtRecord, leg: DebtLegInput?, calendar: Calendar, _ db: Database) throws {
    guard let debt = try Debt.find(record.debtID).fetchOne(db) else { throw RepositoryError.notFound }
    guard record.amountMinor >= 0, Day(record.day) != nil else { throw DebtRepositoryError.invalidLeg }
    let previous = try DebtRecord.find(record.id).fetchOne(db)
    var record = record
    if let kind = record.reportKind, record.categoryID == nil {
      record.categoryID = try Self.debtsCategory(kind, db)
    }
    try DebtRecord.upsert { DebtRecord.Draft(record) }.execute(db)

    let recordID = record.id
    let existingLeg = try Txn.where { $0.debtRecordID.eq(recordID) }.fetchOne(db)
    guard let leg, record.kind.movesMoney else {
      if let existingLeg { try Txn.find(existingLeg.id).delete().execute(db) }
      return
    }
    guard leg.amountMinor >= 0, try Account.find(leg.accountID).fetchCount(db) > 0 else {
      throw DebtRepositoryError.invalidLeg
    }
    let txn = Self.leg(
      for: record, debt: debt, input: leg, existing: existingLeg, previous: previous, calendar: calendar)
    try Txn.upsert { Txn.Draft(txn) }.execute(db)
  }

  public func deleteRecord(_ id: DebtRecord.ID) async throws {
    try await database.write { db in
      try DebtRecord.find(id).delete().execute(db)
      guard db.changesCount > 0 else { throw RepositoryError.notFound }
    }
  }

  // MARK: Legs

  /// The leg as the record wants it: unflagged → a transfer without destination (out, or in
  /// with `isRefund`); flagged → an expense or income in the record's category. An existing leg
  /// keeps its id, time of day (when the day did not change), event, attached records,
  /// fingerprints and a description the user changed.
  static func leg(
    for record: DebtRecord, debt: Debt, input: DebtLegInput, existing: Txn?, previous: DebtRecord?,
    calendar: Calendar
  ) -> Txn {
    let day = Day(record.day)!
    let noon = calendar.date(byAdding: .hour, value: 12, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar)
    var txn = existing ?? Txn(type: .transfer, occurredAt: noon, accountID: input.accountID, amountMinor: input.amountMinor)
    if let existing, Day(existing.occurredAt, calendar: calendar) == day {
      txn.occurredAt = existing.occurredAt
    } else {
      txn.occurredAt = noon
    }
    txn.accountID = input.accountID
    txn.amountMinor = input.amountMinor
    txn.toAccountID = nil
    txn.toAmountMinor = nil
    txn.originalAmountMinor = nil
    txn.originalCurrencyCode = nil
    txn.debtRecordID = record.id
    let flagged: CategoryKind? =
      switch (record.reportKind, record.kind.isInflow) {
      case (.expense, false): .expense
      case (.income, true): .income
      default: nil
      }
    if let flagged {
      txn.type = flagged == .expense ? .expense : .income
      txn.categoryID = record.categoryID
      txn.isRefund = false
    } else {
      txn.type = .transfer
      txn.categoryID = nil
      txn.isRefund = record.kind.isInflow
    }
    let generated = DebtText.legDescription(record.kind, person: debt.personName)
    let previousGenerated = previous.map { DebtText.legDescription($0.kind, person: debt.personName) }
    if existing == nil || txn.payee.isEmpty || txn.payee == previousGenerated {
      txn.payee = generated
    }
    txn.note = record.note
    return txn
  }

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

/// Texts for debt legs (the description shown in the transaction list).
public enum DebtText {
  public static func legDescription(_ kind: DebtRecordKind, person: String) -> String {
    let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
    return switch kind {
    case .lent: "Lent to \(name)"
    case .theyRepaid: "Repaid by \(name)"
    case .borrowed: "Borrowed from \(name)"
    case .iRepaid: "Repaid to \(name)"
    case .paidOnTheirBehalf: "Paid for \(name)"
    case .forgaveThem: "Forgave \(name)"
    case .forgivenByThem: "Forgiven by \(name)"
    }
  }
}
