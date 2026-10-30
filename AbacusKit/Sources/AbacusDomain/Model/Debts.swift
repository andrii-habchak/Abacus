import Foundation
import SQLiteData

// MARK: - Debts (R-DEBT, TA v1.7, D51; design in docs/status/C14.md)

/// Money between me and one person in one currency (R-DEBT-1). Not an account: its balance is
/// the sum of its records' effects; positive = they owe me, negative = I owe them (R-DEBT-2).
/// One person (`personName`) can have one debt per currency; balances are never netted across
/// currencies.
@Table("debts")
public struct Debt: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var personName: String
  public var currency: Currency
  /// `YYYY-MM-DD` (see `Day`); optional.
  public var dueDay: String?
  public var note: String
  /// R-DEBT-7: the balance counts in net worth (owed to me = asset, I owe = liability).
  public var countsInNetWorth: Bool
  /// R-DEBT-5: moved to Settled, off the dashboard widget.
  public var isSettled: Bool
  /// The debt-kind account this debt was converted from (migration v10 / imports, R-DEBT-8);
  /// later imports that still map to that account add their records here.
  public var sourceAccountID: Account.ID?
  /// The import that created this debt; undoing it removes the debt when it has no records left.
  public var importBatchID: ImportBatch.ID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), personName: String, currency: Currency, dueDay: String? = nil, note: String = "",
    countsInNetWorth: Bool = true, isSettled: Bool = false, sourceAccountID: Account.ID? = nil,
    importBatchID: ImportBatch.ID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.personName = personName
    self.currency = currency
    self.dueDay = dueDay
    self.note = note
    self.countsInNetWorth = countsInNetWorth
    self.isSettled = isSettled
    self.sourceAccountID = sourceAccountID
    self.importBatchID = importBatchID
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
  }

  /// The name people are grouped by: trimmed, case- and diacritic-insensitive.
  public var personKey: String {
    personName.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

/// What a debt record is (R-DEBT-3). "Forgive" is stored in two directions so its effect never
/// depends on the order of records.
public enum DebtRecordKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  /// Money from my account to them.
  case lent
  /// Money from them to my account.
  case theyRepaid
  /// Money from them to my account; I owe them.
  case borrowed
  /// Money from my account to them, paying back what I owe.
  case iRepaid
  /// I paid a bill for them from my account; they owe me.
  case paidOnTheirBehalf
  /// I forgive (part of) what they owe me. No money moves.
  case forgaveThem
  /// They forgive (part of) what I owe them. No money moves.
  case forgivenByThem

  /// +1: the balance goes up (they owe me more / I owe less); −1: it goes down.
  public var balanceSign: Int64 {
    switch self {
    case .lent, .iRepaid, .paidOnTheirBehalf, .forgivenByThem: 1
    case .theyRepaid, .borrowed, .forgaveThem: -1
    }
  }

  /// Whether money passes through one of my accounts (forgive never does).
  public var movesMoney: Bool {
    switch self {
    case .forgaveThem, .forgivenByThem: false
    default: true
    }
  }

  /// Money comes into my account (They repaid, I borrowed); otherwise it goes out.
  public var isInflow: Bool { self == .theyRepaid || self == .borrowed }

  /// The report flag the form offers (R-DEBT-4): "Count as expense" on I lent, Paid on their
  /// behalf and Forgive (they owed me); "Count as income" on They repaid; none otherwise.
  public var offeredReportKind: CategoryKind? {
    switch self {
    case .lent, .paidOnTheirBehalf, .forgaveThem: .expense
    case .theyRepaid: .income
    case .borrowed, .iRepaid, .forgivenByThem: nil
    }
  }

  /// The flag's default: only a forgiven debt owed to me counts as an expense by default.
  public var reportsByDefault: Bool { self == .forgaveThem }

  public var title: String {
    switch self {
    case .lent: "I lent"
    case .theyRepaid: "They repaid"
    case .borrowed: "I borrowed"
    case .iRepaid: "I repaid"
    case .paidOnTheirBehalf: "Paid on their behalf"
    case .forgaveThem: "Forgave (they owed me)"
    case .forgivenByThem: "Forgiven (I owed them)"
    }
  }
}

/// One event of a debt (R-DEBT-3): day, amount in the debt's currency, optional note. A record
/// that moves money owns a leg: the `Txn` whose `debtRecordID` is this record (on my account, in
/// the account's currency). `reportKind` = the expense/income flag (R-DEBT-4); a record with a
/// leg reports through its leg (an expense/income in `categoryID`), one without a leg through
/// `DebtBook.reportLedger()`.
@Table("debtRecords")
public struct DebtRecord: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var debtID: Debt.ID
  public var kind: DebtRecordKind
  /// `YYYY-MM-DD`.
  public var day: String
  /// Positive, in the debt's currency.
  public var amountMinor: Int64
  public var note: String
  /// Counted as an expense or income (R-DEBT-4); nil = never in reports or budgets.
  public var reportKind: CategoryKind?
  /// Where a flagged record is reported: the "Debts" category (or, for a converted record, the
  /// category its transaction had).
  public var categoryID: Category.ID?
  /// The import fingerprint of a converted transaction that has no leg (re-import dedupe).
  public var fingerprint: String?
  public var importBatchID: ImportBatch.ID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), debtID: Debt.ID, kind: DebtRecordKind, day: String, amountMinor: Int64, note: String = "",
    reportKind: CategoryKind? = nil, categoryID: Category.ID? = nil, fingerprint: String? = nil,
    importBatchID: ImportBatch.ID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.debtID = debtID
    self.kind = kind
    self.day = day
    self.amountMinor = amountMinor
    self.note = note
    self.reportKind = reportKind
    self.categoryID = categoryID
    self.fingerprint = fingerprint
    self.importBatchID = importBatchID
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
  }

  /// The signed change of the debt's balance (positive = they owe me more).
  public var balanceEffect: Int64 { kind.balanceSign * amountMinor }
}

/// A record with its leg (the transaction on my account), as the repository reads them.
public struct DebtRecordEntry: Hashable, Sendable, Identifiable {
  public var record: DebtRecord
  /// nil when no money moved through my accounts.
  public var leg: Txn?

  public init(record: DebtRecord, leg: Txn? = nil) {
    self.record = record
    self.leg = leg
  }

  public var id: DebtRecord.ID { record.id }
}

/// Every debt with its records: the input of the debt calculators (balances, net worth term,
/// reports, widget).
public struct DebtBook: Hashable, Sendable {
  public var debts: [Debt]
  public var entries: [DebtRecordEntry]

  public init(debts: [Debt] = [], entries: [DebtRecordEntry] = []) {
    self.debts = debts
    self.entries = entries
  }

  public static let empty = DebtBook()

  public var isEmpty: Bool { debts.isEmpty }

  public func entries(of debtID: Debt.ID) -> [DebtRecordEntry] {
    entries.filter { $0.record.debtID == debtID }
  }
}

// MARK: - Linking transactions to debts (R-DEBT-9…13, TA v1.8, docs/status/C17.md)

extension Debt {
  /// The grouping key of a person name (see `personKey`).
  public static func personKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

extension DebtRecordKind {
  /// The kinds a transaction moving money in (`inflow`) or out can become (R-DEBT-10/11):
  /// out → I lent, I repaid, Paid on their behalf; in → They repaid, I borrowed.
  public static func linkable(inflow: Bool) -> [DebtRecordKind] {
    inflow ? [.theyRepaid, .borrowed] : [.lent, .iRepaid, .paidOnTheirBehalf]
  }

  /// The kind suggested for money moving in or out with the debt at `balance` (positive = they
  /// owe me): out → I repaid while I owe them, else I lent; in → They repaid while they owe me,
  /// else I borrowed.
  public static func suggested(inflow: Bool, balance: Int64) -> DebtRecordKind {
    if inflow { return balance > 0 ? .theyRepaid : .borrowed }
    return balance < 0 ? .iRepaid : .lent
  }
}

extension DebtBook {
  /// The person's debt in `currency` (person key match): an unsettled one first.
  public func debt(person: String, currency: Currency) -> Debt? {
    let key = Debt.personKey(person)
    let matching = debts.filter { $0.personKey == key && $0.currency == currency }
    return matching.first { !$0.isSettled } ?? matching.first
  }

  /// The person's debts, unsettled first, then in the display order of currencies.
  public func debts(person: String) -> [Debt] {
    let key = Debt.personKey(person)
    let order = Dictionary(uniqueKeysWithValues: Currency.displayOrder.enumerated().map { ($1, $0) })
    return debts.filter { $0.personKey == key }.sorted {
      ($0.isSettled ? 1 : 0, order[$0.currency] ?? 99) < ($1.isSettled ? 1 : 0, order[$1.currency] ?? 99)
    }
  }

  /// One name per person (the first spelling), A–Z.
  public var personNames: [String] {
    var seen: Set<String> = []
    var names: [String] = []
    for debt in debts where seen.insert(debt.personKey).inserted {
      names.append(debt.personName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// The debt's balance (positive = they owe me), in minor units of its currency.
  public func balance(of debtID: Debt.ID) -> Int64 {
    entries.reduce(0) { $1.record.debtID == debtID ? $0 + $1.record.balanceEffect : $0 }
  }
}
