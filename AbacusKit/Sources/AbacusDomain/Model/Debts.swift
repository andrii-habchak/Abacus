import Foundation
import SQLiteData

// MARK: - Debts (R-DEBT, TA v1.9, D59-D61; design in docs/status/C19.md)

/// Money between me and one person (R-DEBT-16): a name, an optional due date, a note, "Count in
/// net worth" and a settled flag. **No currency:** the balance per currency comes from the
/// person's linked accounts (`DebtAccountLink`) and manual records (R-DEBT-18). Positive = they
/// owe me, negative = I owe them (R-DEBT-2). One debt per person (`personKey`).
@Table("debts")
public struct Debt: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var personName: String
  /// `YYYY-MM-DD` (see `Day`); optional.
  public var dueDay: String?
  public var note: String
  /// R-DEBT-7: the balance counts in net worth (owed to me = asset, I owe = liability).
  /// Off by default for new debts (R-DEBT-21, D61).
  public var countsInNetWorth: Bool
  /// R-DEBT-5: moved to Settled, off the dashboard widget.
  public var isSettled: Bool
  /// The debt-kind account this debt was converted from (migration v10 / imports, R-DEBT-8);
  /// since v13 that account is also a linked (virtual) account of the debt.
  public var sourceAccountID: Account.ID?
  /// The import that created this debt; undoing it removes the debt when nothing is left in it.
  public var importBatchID: ImportBatch.ID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), personName: String, dueDay: String? = nil, note: String = "",
    countsInNetWorth: Bool = false, isSettled: Bool = false, sourceAccountID: Account.ID? = nil,
    importBatchID: ImportBatch.ID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.personName = personName
    self.dueDay = dueDay
    self.note = note
    self.countsInNetWorth = countsInNetWorth
    self.isSettled = isSettled
    self.sourceAccountID = sourceAccountID
    self.importBatchID = importBatchID
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
  }

  /// The name people are grouped by: trimmed, case- and diacritic-insensitive.
  public var personKey: String { Debt.personKey(personName) }

  /// The grouping key of a person name (see `personKey`).
  public static func personKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

/// Whose account a linked account is (R-DEBT-17); both are *the person's* accounts, never mine.
public enum DebtAccountRole: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  /// The person's real account whose statement I import (e.g. "Revolut Anna").
  case external
  /// A debt-kind account I keep for the person, no statement; created from the debt dialog.
  case virtual
}

/// An account of a debt (R-DEBT-17). The account id is the primary key, which is what makes an
/// account belong to at most one debt without a UNIQUE constraint (CloudKit rules).
@Table("debtAccounts")
public struct DebtAccountLink: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public var accountID: Account.ID
  public var debtID: Debt.ID
  public var role: DebtAccountRole
  public var createdAt: Date

  public var id: Account.ID { accountID }

  public init(accountID: Account.ID, debtID: Debt.ID, role: DebtAccountRole, createdAt: Date = Date()) {
    self.accountID = accountID
    self.debtID = debtID
    self.role = role
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
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


/// A **manual** record of a debt (R-DEBT-18): forgive, adjustments, carried opening balances.
/// Money that moves through accounts is never a record any more, it is a transaction on a linked
/// account (R-DEBT-19). A record has its own currency; `kind` fixes the sign of its effect.
/// `reportKind` = the expense/income flag (R-DEBT-4); a flagged record reports through
/// `DebtBook.reportLedger()`.
@Table("debtRecords")
public struct DebtRecord: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var debtID: Debt.ID
  public var kind: DebtRecordKind
  /// `YYYY-MM-DD`.
  public var day: String
  /// Positive, in `currency`.
  public var amountMinor: Int64
  /// The record's own currency (a debt has none).
  public var currency: Currency
  public var note: String
  /// Counted as an expense or income (R-DEBT-4); nil = never in reports or budgets.
  public var reportKind: CategoryKind?
  /// Where a flagged record is reported: the "Debts" category.
  public var categoryID: Category.ID?
  /// The import fingerprint of a record migrated from a converted transaction (re-import dedupe).
  public var fingerprint: String?
  public var importBatchID: ImportBatch.ID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), debtID: Debt.ID, kind: DebtRecordKind, day: String, amountMinor: Int64,
    currency: Currency, note: String = "", reportKind: CategoryKind? = nil, categoryID: Category.ID? = nil,
    fingerprint: String? = nil, importBatchID: ImportBatch.ID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.debtID = debtID
    self.kind = kind
    self.day = day
    self.amountMinor = amountMinor
    self.currency = currency
    self.note = note
    self.reportKind = reportKind
    self.categoryID = categoryID
    self.fingerprint = fingerprint
    self.importBatchID = importBatchID
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
  }

  /// The signed change of the debt's balance in `currency` (positive = they owe me more).
  public var balanceEffect: Int64 { kind.balanceSign * amountMinor }
}

/// Every debt with what its balance is made of: the input of the debt calculators (balances,
/// net-worth term, hints, reports, widget). Self-contained: the linked accounts and the
/// transactions touching them are part of it.
public struct DebtBook: Hashable, Sendable {
  public var debts: [Debt]
  /// Which account belongs to which debt (R-DEBT-17).
  public var links: [DebtAccountLink]
  /// The linked accounts (any state, archived too).
  public var accounts: [Account]
  /// Every transaction touching a linked account (attached records included).
  public var txns: [TxnWithLines]
  /// Manual records of all debts.
  public var records: [DebtRecord]

  public init(
    debts: [Debt] = [], links: [DebtAccountLink] = [], accounts: [Account] = [], txns: [TxnWithLines] = [],
    records: [DebtRecord] = []
  ) {
    self.debts = debts
    self.links = links
    self.accounts = accounts
    self.txns = txns
    self.records = records
  }

  public static let empty = DebtBook()

  public var isEmpty: Bool { debts.isEmpty }

  public func records(of debtID: Debt.ID) -> [DebtRecord] {
    records.filter { $0.debtID == debtID }
  }

  public func links(of debtID: Debt.ID) -> [DebtAccountLink] {
    links.filter { $0.debtID == debtID }
  }

  /// The linked accounts of a debt, in the order of `accounts`.
  public func accounts(of debtID: Debt.ID) -> [Account] {
    let ids = Set(links(of: debtID).map(\.accountID))
    return accounts.filter { ids.contains($0.id) }
  }

  /// The debt an account is linked to (R-DEBT-17), if any.
  public func debtID(ofAccount accountID: Account.ID) -> Debt.ID? {
    links.first { $0.accountID == accountID }?.debtID
  }

  public var linkedAccountIDs: Set<Account.ID> { Set(links.map(\.accountID)) }

  public func debt(_ id: Debt.ID) -> Debt? { debts.first { $0.id == id } }

  /// The person's debt (person key match, R-DEBT-16): an unsettled one first when old data still
  /// holds several.
  public func debt(person: String) -> Debt? {
    let key = Debt.personKey(person)
    let matching = debts.filter { $0.personKey == key }
    return matching.first { !$0.isSettled } ?? matching.first
  }

  /// One name per person (the first spelling), A–Z (R-DEBT-16 autocomplete source).
  public var personNames: [String] {
    var seen: Set<String> = []
    var names: [String] = []
    for debt in debts where seen.insert(debt.personKey).inserted {
      names.append(debt.personName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// Names starting with, else containing, `text` (case/diacritic-insensitive); every name when
  /// `text` is blank.
  public func personNames(matching text: String) -> [String] {
    let key = Debt.personKey(text)
    guard !key.isEmpty else { return personNames }
    let all = personNames
    let prefix = all.filter { Debt.personKey($0).hasPrefix(key) }
    let inner = all.filter { !Debt.personKey($0).hasPrefix(key) && Debt.personKey($0).contains(key) }
    return prefix + inner
  }
}

// MARK: - Kind helpers (R-DEBT-3, kept for the manual records and for callers of C17)

extension DebtRecordKind {
  /// The kinds a transaction moving money in (`inflow`) or out can become: out → I lent, I
  /// repaid, Paid on their behalf; in → They repaid, I borrowed.
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
