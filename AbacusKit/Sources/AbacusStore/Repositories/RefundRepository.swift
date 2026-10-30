import AbacusDomain
import Foundation
import SQLiteData

/// Refund links (R-TX-4, C30): `txns.refundOfID` points a refund at the expense it returns money
/// for. The link carries no foreign key (CloudKit-safe); `RefundLinks.repair` keeps it valid.
public struct SQLiteRefundRepository: RefundRepository {
  public let database: any DatabaseWriter
  public let calendar: Calendar
  /// Rates for refunds in another currency than their original (at the refund's date). Read
  /// before each write; nil or a missing rate throws `rateUnavailable` for such a refund.
  let converter: @Sendable () async -> (any CurrencyConverter)?

  public init(
    database: any DatabaseWriter, calendar: Calendar = .current,
    converter: @escaping @Sendable () async -> (any CurrencyConverter)? = { nil }
  ) {
    self.database = database
    self.calendar = calendar
    self.converter = converter
  }

  // MARK: Link / unlink

  public func linkRefund(_ refundID: Txn.ID, to originalID: Txn.ID) async throws {
    let rates = await converter()
    let calendar = self.calendar
    try await database.write { db in
      guard var refund = try Txn.find(refundID).fetchOne(db), let original = try Txn.find(originalID).fetchOne(db)
      else { throw RefundError.notFound }
      guard refund.id != original.id, RefundRules.canBeRefund(refund) else { throw RefundError.notRefundable }
      guard RefundRules.canBeOriginal(original) else { throw RefundError.invalidOriginal }
      let currencies = try RefundRules.currencies(db)
      guard let originalCurrency = currencies[original.accountID] else { throw RefundError.notFound }
      _ = originalCurrency
      try RefundRules.checkCap(refund, against: original, currencies: currencies, rates: rates, calendar: calendar, db)
      refund.type = .expense
      refund.isRefund = true
      refund.categoryID = original.categoryID
      refund.refundOfID = original.id
      try Txn.upsert { Txn.Draft(refund) }.execute(db)
    }
  }

  public func unlinkRefund(_ refundID: Txn.ID) async throws {
    try await database.write { db in
      guard var refund = try Txn.find(refundID).fetchOne(db) else { throw RefundError.notFound }
      guard refund.refundOfID != nil else { return }
      refund.refundOfID = nil
      try Txn.upsert { Txn.Draft(refund) }.execute(db)
    }
  }

  // MARK: Candidates

  public func refundCandidates(for refundID: Txn.ID, matching search: String, limit: Int) async throws -> [RefundCandidate] {
    let refund = try await database.read { db in try Txn.find(refundID).fetchOne(db) }
    guard let refund else { throw RefundError.notFound }
    guard RefundRules.canBeRefund(refund) else { throw RefundError.notRefundable }
    return try await refundCandidates(probe: RefundProbe(refund), matching: search, limit: limit)
  }

  public func refundCandidates(probe refund: RefundProbe, matching search: String, limit: Int) async throws -> [RefundCandidate] {
    let rates = await converter()
    let calendar = self.calendar
    return try await database.read { db in
      let currencies = try RefundRules.currencies(db)
      guard let refundCurrency = currencies[refund.accountID] else { throw RefundError.notFound }
      let needle = RefundRules.fold(search)
      var condition: QueryFragment = """
        "txns"."type" = 'expense' AND NOT "txns"."isRefund" AND NOT "txns"."isBalanceCorrection" \
        AND "txns"."debtRecordID" IS NULL
        """
      if let ownID = refund.id { condition += #" AND "txns"."id" <> \#(ownID)"# }
      if needle.isEmpty {
        let from = calendar.date(byAdding: .day, value: -RefundRules.windowDays, to: refund.occurredAt) ?? refund.occurredAt
        condition += #" AND "txns"."occurredAt" >= \#(from) AND "txns"."occurredAt" <= \#(refund.occurredAt)"#
      }
      let expression = SQLQueryExpression(condition, as: Bool.self)
      let expenses = try Txn.where { _ in expression }.order { ($0.occurredAt.desc(), $0.id.desc()) }.fetchAll(db)
      let linked = try Dictionary(
        grouping: Txn.where { $0.refundOfID.isNot(nil) }.fetchAll(db), by: { $0.refundOfID! })
      var result: [RefundCandidate] = []
      for expense in expenses {
        guard let currency = currencies[expense.accountID] else { continue }
        if !needle.isEmpty,
          !RefundRules.fold(expense.payee).contains(needle), !RefundRules.fold(expense.note).contains(needle)
        { continue }
        var refunded: Int64 = 0
        for other in linked[expense.id] ?? [] where other.id != refund.id {
          refunded += (try? RefundRules.amount(other, in: currency, currencies: currencies, rates: rates, calendar: calendar)) ?? 0
        }
        let remaining = expense.amountMinor - refunded
        guard remaining > 0 else { continue }
        var score = 0
        var sameAmount = false
        let payee = RefundRules.fold(expense.payee)
        let refundPayee = RefundRules.fold(refund.payee)
        if !payee.isEmpty, !refundPayee.isEmpty {
          if payee == refundPayee {
            score += 40
          } else if payee.contains(refundPayee) || refundPayee.contains(payee) {
            score += 20
          }
        }
        if currency == refundCurrency {
          score += 10
          if remaining == refund.amountMinor {
            sameAmount = true
            score += 30
          } else if refund.amountMinor > remaining {
            continue  // the refund would exceed what remains
          } else {
            score += 5
          }
        }
        if expense.accountID == refund.accountID { score += 3 }
        result.append(RefundCandidate(
          txn: expense, currency: currency, refundedMinor: refunded, score: score, isSameAmount: sameAmount))
      }
      // Stable: the SQL order (newest first) breaks ties.
      let ranked = result.enumerated().sorted {
        ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset)
      }.map(\.element)
      return Array(ranked.prefix(max(0, limit)))
    }
  }

  public func refundTargets(for originalID: Txn.ID, matching search: String, limit: Int) async throws -> [RefundTargetCandidate] {
    let rates = await converter()
    let calendar = self.calendar
    return try await database.read { db in
      guard let original = try Txn.find(originalID).fetchOne(db) else { throw RefundError.notFound }
      guard RefundRules.canBeOriginal(original) else { throw RefundError.invalidOriginal }
      let currencies = try RefundRules.currencies(db)
      guard let currency = currencies[original.accountID] else { throw RefundError.notFound }
      let others = try Txn.where { $0.refundOfID.eq(originalID) }.fetchAll(db)
      var refunded: Int64 = 0
      for other in others {
        refunded += (try? RefundRules.amount(other, in: currency, currencies: currencies, rates: rates, calendar: calendar)) ?? 0
      }
      let remaining = original.amountMinor - refunded
      guard remaining > 0 else { return [] }
      let needle = RefundRules.fold(search)
      let accountID = original.accountID
      let expression = SQLQueryExpression(
        """
        "txns"."accountID" = \(accountID) AND NOT "txns"."isBalanceCorrection" AND "txns"."debtRecordID" IS NULL \
        AND "txns"."amountMinor" <= \(remaining) AND "txns"."refundOfID" IS NULL \
        AND (("txns"."type" = 'income' AND NOT "txns"."isRefund") OR ("txns"."type" = 'expense' AND "txns"."isRefund")) \
        AND "txns"."id" <> \(originalID)
        """ as QueryFragment, as: Bool.self)
      let incoming = try Txn.where { _ in expression }.order { ($0.occurredAt.desc(), $0.id.desc()) }.fetchAll(db)
      var result: [(candidate: RefundTargetCandidate, order: Int)] = []
      for txn in incoming {
        if !needle.isEmpty, !RefundRules.fold(txn.payee).contains(needle), !RefundRules.fold(txn.note).contains(needle) {
          continue
        }
        var score = txn.amountMinor == remaining ? 30 : 5
        let payee = RefundRules.fold(txn.payee)
        let originalPayee = RefundRules.fold(original.payee)
        if !payee.isEmpty, !originalPayee.isEmpty {
          if payee == originalPayee {
            score += 40
          } else if payee.contains(originalPayee) || originalPayee.contains(payee) {
            score += 20
          }
        }
        if txn.occurredAt >= original.occurredAt { score += 3 }
        result.append((RefundTargetCandidate(txn: txn, currency: currency, remainingMinor: remaining, score: score), result.count))
      }
      let ranked = result.sorted { ($0.candidate.score, -$0.order) > ($1.candidate.score, -$1.order) }.map(\.candidate)
      return Array(ranked.prefix(max(0, limit)))
    }
  }

  // MARK: List data

  public func refundLinks(for ids: [Txn.ID]) async throws -> RefundLinkSummary {
    guard !ids.isEmpty else { return RefundLinkSummary() }
    return try await database.read { db in
      let currencies = try RefundRules.currencies(db)
      var summary = RefundLinkSummary()
      var refunds: [Txn] = []
      var linkedRefunds: [Txn] = []
      for chunk in ids.chunked(500) {
        let part = Array(chunk).map(Optional.some)
        refunds += try Txn.where { $0.refundOfID.in(part) }.fetchAll(db)
        let own = Array(chunk)
        linkedRefunds += try Txn.where { $0.id.in(own) && $0.refundOfID.isNot(nil) }.fetchAll(db)
      }
      for refund in refunds {
        guard let originalID = refund.refundOfID, let currency = currencies[refund.accountID] else { continue }
        summary.refundsByOriginal[originalID, default: []].append(
          .init(refundID: refund.id, amountMinor: refund.amountMinor, currency: currency, occurredAt: refund.occurredAt))
      }
      let originalIDs = Array(Set(linkedRefunds.compactMap(\.refundOfID)))
      var originals: [Txn.ID: Txn] = [:]
      for chunk in originalIDs.chunked(500) {
        let part = Array(chunk)
        for txn in try Txn.where({ $0.id.in(part) }).fetchAll(db) { originals[txn.id] = txn }
      }
      for refund in linkedRefunds {
        guard let originalID = refund.refundOfID, let original = originals[originalID],
          let currency = currencies[original.accountID]
        else { continue }
        summary.originalByRefund[refund.id] = .init(
          originalID: original.id, payee: original.payee, occurredAt: original.occurredAt,
          amountMinor: original.amountMinor, currency: currency)
      }
      for key in summary.refundsByOriginal.keys {
        summary.refundsByOriginal[key]?.sort { ($0.occurredAt, $0.refundID.uuidString) < ($1.occurredAt, $1.refundID.uuidString) }
      }
      return summary
    }
  }
}

// MARK: - Rules shared by the repository, `TxnRepository` and the other write paths

enum RefundRules {
  /// Candidates are expenses up to this many days before the refund.
  static let windowDays = 60

  /// An expense marked as refund, or an income that may become one. Never a correction, a debt leg
  /// or a transfer.
  static func canBeRefund(_ txn: Txn) -> Bool {
    guard !txn.isBalanceCorrection, txn.debtRecordID == nil else { return false }
    return (txn.type == .expense && txn.isRefund) || (txn.type == .income && !txn.isRefund)
  }

  /// An expense that is not a refund (nor a correction or debt leg).
  static func canBeOriginal(_ txn: Txn) -> Bool {
    txn.type == .expense && !txn.isRefund && !txn.isBalanceCorrection && txn.debtRecordID == nil
  }

  static func currencies(_ db: Database) throws -> [Account.ID: Currency] {
    Dictionary(try Account.fetchAll(db).map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
  }

  /// `txn`'s amount in `currency` at the date of `txn` (the refund's date for a refund).
  static func amount(
    _ txn: Txn, in currency: Currency, currencies: [Account.ID: Currency], rates: (any CurrencyConverter)?,
    calendar: Calendar
  ) throws -> Int64 {
    guard let own = currencies[txn.accountID] else { throw RefundError.notFound }
    if own == currency { return txn.amountMinor }
    guard let rates,
      let money = rates.convert(
        Money(minorUnits: txn.amountMinor, currency: own), to: currency, on: Day(txn.occurredAt, calendar: calendar))
    else { throw RefundError.rateUnavailable }
    return money.minorUnits
  }

  /// The refunds linked to `original`, `refund` included (replacing its stored link), converted to
  /// the original's currency at each refund's date, may not exceed the original's amount.
  /// With `lenient`, a refund in another currency that has no rate is not checked (saving an edit
  /// must not fail because rates are missing).
  static func checkCap(
    _ refund: Txn, against original: Txn, currencies: [Account.ID: Currency], rates: (any CurrencyConverter)?,
    calendar: Calendar, lenient: Bool = false, _ db: Database
  ) throws {
    guard let currency = currencies[original.accountID] else { throw RefundError.notFound }
    let refundID = refund.id
    let originalID = original.id
    let others = try Txn.where { $0.refundOfID.eq(originalID) && $0.id.neq(refundID) }.fetchAll(db)
    do {
      var refunded: Int64 = 0
      for other in others {
        refunded += try amount(other, in: currency, currencies: currencies, rates: rates, calendar: calendar)
      }
      let incoming = try amount(refund, in: currency, currencies: currencies, rates: rates, calendar: calendar)
      guard refunded + incoming <= original.amountMinor else {
        throw RefundError.exceedsOriginal(remainingMinor: max(0, original.amountMinor - refunded), currency: currency)
      }
    } catch RefundError.rateUnavailable where lenient {
      return
    }
  }

  /// Case, diacritics and surrounding whitespace folded away.
  static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }
}

/// Keeps links valid after any write that can change a transaction (called by the transaction,
/// rule, import and debt write paths; the partial index makes it cheap).
enum RefundLinks {
  /// - a link on a row that is not an expense refund is cleared, and so is a link whose original
  ///   is gone or is no longer an expense that is not a refund (deleted, converted to a transfer
  ///   or a debt leg, marked as refund);
  /// - a linked refund takes its original's category (reports net it there).
  static func repair(_ db: Database) throws {
    try db.execute(
      sql: #"""
        UPDATE "txns" SET "refundOfID" = NULL WHERE "refundOfID" IS NOT NULL AND (
          "type" <> 'expense' OR NOT "isRefund" OR "isBalanceCorrection" OR "debtRecordID" IS NOT NULL
          OR NOT EXISTS (
            SELECT 1 FROM "txns" AS "o" WHERE "o"."id" = "txns"."refundOfID" AND "o"."type" = 'expense'
            AND NOT "o"."isRefund" AND NOT "o"."isBalanceCorrection" AND "o"."debtRecordID" IS NULL))
        """#)
    try db.execute(
      sql: #"""
        UPDATE "txns" SET "categoryID" = (SELECT "o"."categoryID" FROM "txns" AS "o" WHERE "o"."id" = "txns"."refundOfID")
        WHERE "refundOfID" IS NOT NULL AND "categoryID" IS NOT
          (SELECT "o"."categoryID" FROM "txns" AS "o" WHERE "o"."id" = "txns"."refundOfID")
        """#)
  }
}
