import Foundation
import SQLiteData

// Entities are @Table types: the same structs are used by the store, the calculators and the
// view models. Rules (TA §3, DECISIONS D6–D7): UUID primary keys generated in Swift, amounts in
// minor units, archive flags instead of deletes, no UNIQUE columns (CloudKit sync in v2).
// Column names = property names; table names are explicit.

// MARK: - Accounts (R-ACC)

public enum AccountKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  // Assets
  case cash, bank, card, savings, investment
  // Liabilities
  case creditCard, loan, debt

  public var isLiability: Bool {
    switch self {
    case .creditCard, .loan, .debt: true
    case .cash, .bank, .card, .savings, .investment: false
    }
  }
}

/// A folder of accounts ("Monobank", "PKO"; R-MGMT-9, D48). It holds no money of its own: the
/// Accounts page and the net worth widget show the sum of its accounts. One level only.
/// Ordering (custom order): a group and the accounts outside any group share one `position`
/// space at the top level; accounts in a group are ordered by their own `position`.
@Table("accountGroups")
public struct AccountGroup: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var position: Int
  /// `#RRGGBB`, optional.
  public var colorHex: String?

  public init(id: UUID = UUID(), name: String, position: Int = 0, colorHex: String? = nil) {
    self.id = id
    self.name = name
    self.position = position
    self.colorHex = colorHex
  }
}

@Table("accounts")
public struct Account: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var currency: Currency
  public var kind: AccountKind
  /// Signed: a liability normally opens negative.
  public var openingBalanceMinor: Int64
  public var openingDate: Date
  /// Used by importers to recognise own-account transfers (R-ACC-1, R-IMP-PKO-3).
  public var iban: String?
  /// The account's group (R-MGMT-9); nil = top level. (The old free-text `groupName` column
  /// stays in the table unused since migration v11.)
  public var groupID: AccountGroup.ID?
  public var colorHex: String?
  public var icon: String?
  /// Custom order: among the top-level groups and accounts, or within the group.
  public var position: Int
  public var isArchived: Bool
  /// The import that created this account; undoing it removes the account if unused (R-IMP-6).
  public var importBatchID: ImportBatch.ID?

  public init(
    id: UUID = UUID(), name: String, currency: Currency, kind: AccountKind,
    openingBalanceMinor: Int64 = 0, openingDate: Date, iban: String? = nil,
    groupID: AccountGroup.ID? = nil, colorHex: String? = nil, icon: String? = nil,
    position: Int = 0, isArchived: Bool = false, importBatchID: ImportBatch.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.currency = currency
    self.kind = kind
    self.openingBalanceMinor = openingBalanceMinor
    self.openingDate = openingDate
    self.iban = iban
    self.groupID = groupID
    self.colorHex = colorHex
    self.icon = icon
    self.position = position
    self.isArchived = isArchived
    self.importBatchID = importBatchID
  }
}

// MARK: - Categories (R-CAT)

public enum CategoryKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case expense, income
}

@Table("categories")
public struct Category: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var kind: CategoryKind
  /// One level of subcategories (R-CAT-2): a parent has `parentID == nil`.
  public var parentID: Category.ID?
  public var icon: String?
  public var colorHex: String?
  public var position: Int
  public var isArchived: Bool
  /// The import that created this category; undoing it removes the category if unused.
  public var importBatchID: ImportBatch.ID?
  /// When the category was created: the Categories page's "Newest first" / "Oldest first"
  /// (R-MGMT-8), in whole seconds. Categories older than migration v9 got stable values in
  /// their order then.
  public var createdAt: Date

  public init(
    id: UUID = UUID(), name: String, kind: CategoryKind, parentID: Category.ID? = nil,
    icon: String? = nil, colorHex: String? = nil, position: Int = 0, isArchived: Bool = false,
    importBatchID: ImportBatch.ID? = nil, createdAt: Date = Date()
  ) {
    // Whole seconds: the value reads back from the database exactly as it was saved.
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    self.id = id
    self.name = name
    self.kind = kind
    self.parentID = parentID
    self.icon = icon
    self.colorHex = colorHex
    self.position = position
    self.isArchived = isArchived
    self.importBatchID = importBatchID
  }
}

// MARK: - Events (R-EVT)

@Table("events")
public struct Event: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  /// `YYYY-MM-DD` (see `Day`).
  public var startDay: String?
  public var endDay: String?
  public var budgetMinor: Int64?
  public var budgetCurrency: Currency?
  /// `#RRGGBB` (R-EVT-1, R-MGMT-7); the store gives a new event a palette colour when nil.
  public var colorHex: String?
  public var isArchived: Bool
  /// The import that created this event (Saldo tag); undoing it removes the event.
  public var importBatchID: ImportBatch.ID?

  public init(
    id: UUID = UUID(), name: String, startDay: String? = nil, endDay: String? = nil,
    budgetMinor: Int64? = nil, budgetCurrency: Currency? = nil, colorHex: String? = nil,
    isArchived: Bool = false, importBatchID: ImportBatch.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.startDay = startDay
    self.endDay = endDay
    self.budgetMinor = budgetMinor
    self.budgetCurrency = budgetCurrency
    self.colorHex = colorHex
    self.isArchived = isArchived
    self.importBatchID = importBatchID
  }
}

// MARK: - Transactions (R-TX)

public enum TxnType: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case expense, income, transfer
}

public enum TxnSource: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case manual, saldo, pko
}

/// A transaction ("tx"). Named `Txn` to avoid clashing with `SwiftUI.Transaction`.
///
/// Sign convention: `amountMinor` is always positive, in the account's currency; the direction
/// comes from `type` and `isRefund`. A transfer moves `amountMinor` out of `accountID` and
/// `toAmountMinor` (in the destination currency) into `toAccountID`. Attached records add to
/// the effect on `accountID` (R-TX-6).
///
/// A debt record's leg (`debtRecordID` set, R-DEBT-3) that is not counted as an expense or
/// income is a transfer without a destination (`toAccountID == nil`): money out of `accountID`,
/// or into it when `isRefund` is set.
@Table("txns")
public struct Txn: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var type: TxnType
  public var occurredAt: Date
  public var accountID: Account.ID
  public var amountMinor: Int64
  /// Expense/income only.
  public var categoryID: Category.ID?
  /// Transfer only.
  public var toAccountID: Account.ID?
  public var toAmountMinor: Int64?
  /// Expense refund / income reversal: money flows the other way (R-TX-4).
  public var isRefund: Bool
  /// Amount in the merchant's currency, informational (R-CUR-4).
  public var originalAmountMinor: Int64?
  public var originalCurrencyCode: String?
  /// "Description" in the UI: merchant / payee (R-TX-2).
  public var payee: String
  public var note: String
  public var eventID: Event.ID?
  public var source: TxnSource
  public var importBatchID: ImportBatch.ID?
  /// Imported PKO hold not yet settled (R-IMP-PKO-2).
  public var isPendingAtBank: Bool
  public var createdAt: Date
  /// `YYYY-MM-DD` the bank booked it, when that differs from the purchase day `occurredAt`
  /// (PKO `Data operacji`, TA Q22). Reference only.
  public var bookedDay: String?
  /// Set on the leg of a debt record: the money the record moved on this account (R-DEBT-3).
  /// Deleting the record deletes the leg.
  public var debtRecordID: DebtRecord.ID?

  public init(
    id: UUID = UUID(), type: TxnType, occurredAt: Date, accountID: Account.ID,
    amountMinor: Int64, categoryID: Category.ID? = nil, toAccountID: Account.ID? = nil,
    toAmountMinor: Int64? = nil, isRefund: Bool = false, originalAmountMinor: Int64? = nil,
    originalCurrencyCode: String? = nil, payee: String = "", note: String = "",
    eventID: Event.ID? = nil, source: TxnSource = .manual, importBatchID: ImportBatch.ID? = nil,
    isPendingAtBank: Bool = false, createdAt: Date = Date(), bookedDay: String? = nil,
    debtRecordID: DebtRecord.ID? = nil
  ) {
    self.id = id
    self.type = type
    self.occurredAt = occurredAt
    self.accountID = accountID
    self.amountMinor = amountMinor
    self.categoryID = categoryID
    self.toAccountID = toAccountID
    self.toAmountMinor = toAmountMinor
    self.isRefund = isRefund
    self.originalAmountMinor = originalAmountMinor
    self.originalCurrencyCode = originalCurrencyCode
    self.payee = payee
    self.note = note
    self.eventID = eventID
    self.source = source
    self.importBatchID = importBatchID
    self.isPendingAtBank = isPendingAtBank
    self.createdAt = createdAt
    self.bookedDay = bookedDay
    self.debtRecordID = debtRecordID
  }

  /// Money comes into `accountID` from outside the app's accounts: a debt leg without a
  /// destination marked `isRefund` (They repaid, I borrowed).
  public var isOneSidedInflow: Bool { type == .transfer && toAccountID == nil && isRefund }
}

/// A fee, cashback or split line belonging to a transaction (R-TX-6). Hits the parent's
/// `accountID`, shares its date, deleted with it.
@Table("attachedRecords")
public struct AttachedRecord: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var txnID: Txn.ID
  /// `.expense` takes money out of the account (fee), `.income` puts it in (cashback).
  public var kind: CategoryKind
  public var categoryID: Category.ID?
  public var amountMinor: Int64
  public var originalAmountMinor: Int64?
  public var originalCurrencyCode: String?
  public var note: String
  public var position: Int

  public init(
    id: UUID = UUID(), txnID: Txn.ID, kind: CategoryKind = .expense,
    categoryID: Category.ID? = nil, amountMinor: Int64, originalAmountMinor: Int64? = nil,
    originalCurrencyCode: String? = nil, note: String = "", position: Int = 0
  ) {
    self.id = id
    self.txnID = txnID
    self.kind = kind
    self.categoryID = categoryID
    self.amountMinor = amountMinor
    self.originalAmountMinor = originalAmountMinor
    self.originalCurrencyCode = originalCurrencyCode
    self.note = note
    self.position = position
  }
}

// MARK: - Budget (R-BUD)

/// The monthly budget in effect from `effectiveMonth` until the next plan (R-BUD-3).
///
/// TA v1.6 (D46): a total limit in its own currency plus per-category limits, each in its own
/// currency (`BudgetAllocation.currency`); "unallocated" = total − limits at one rate.
/// `totalMinor == 0` means no total is set (plans saved by 1.1.0, which had no total field): the
/// budget's total is then the sum of the limits.
@Table("budgetPlans")
public struct BudgetPlan: Hashable, Identifiable, Sendable {
  public let id: UUID
  /// `YYYY-MM` (see `Month`).
  public var effectiveMonth: String
  /// The total limit in `currency`; 0 = no total set.
  public var totalMinor: Int64
  /// The total's currency.
  public var currency: Currency

  public init(id: UUID = UUID(), effectiveMonth: String, totalMinor: Int64 = 0, currency: Currency = .PLN) {
    self.id = id
    self.effectiveMonth = effectiveMonth
    self.totalMinor = totalMinor
    self.currency = currency
  }

  /// The total limit; nil when none is set (`totalMinor` 0 or less).
  public var total: Money? {
    totalMinor > 0 ? Money(minorUnits: totalMinor, currency: currency) : nil
  }
}

/// A category's monthly limit in its own currency (R-BUD-1, D43, D46). A parent's limit covers its
/// children unless a child has a limit of its own (D27).
@Table("budgetAllocations")
public struct BudgetAllocation: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var planID: BudgetPlan.ID
  public var categoryID: Category.ID
  public var limitMinor: Int64
  /// The limit's currency: the category's spending is converted to it (R-BUD-2).
  public var currency: Currency

  public init(
    id: UUID = UUID(), planID: BudgetPlan.ID, categoryID: Category.ID, limitMinor: Int64, currency: Currency
  ) {
    self.id = id
    self.planID = planID
    self.categoryID = categoryID
    self.limitMinor = limitMinor
    self.currency = currency
  }

  public var limit: Money { Money(minorUnits: limitMinor, currency: currency) }
}

// MARK: - Exchange rates (R-FX)

/// Rates are stored as integers scaled by 10^8: `1 base = rateE8 / 10^8 quote`.
public enum RateScale {
  public static let factor: Int64 = 100_000_000

  public static func decimal(_ rateE8: Int64) -> Decimal {
    Decimal(rateE8) / Decimal(factor)
  }

  public static func scaled(_ rate: Decimal) -> Int64 {
    var value = rate * Decimal(factor)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 0, .bankers)
    return NSDecimalNumber(decimal: rounded).int64Value
  }
}

/// A fetched rate (local cache, not synced).
@Table("fxRates")
public struct FXRate: Hashable, Identifiable, Sendable {
  public let id: UUID
  /// `YYYY-MM-DD`: the day the rate is valid for.
  public var day: String
  public var base: Currency
  public var quote: Currency
  public var rateE8: Int64
  /// e.g. "NBU".
  public var provider: String
  public var fetchedAt: Date

  public init(
    id: UUID = UUID(), day: String, base: Currency, quote: Currency, rateE8: Int64,
    provider: String, fetchedAt: Date = Date()
  ) {
    self.id = id
    self.day = day
    self.base = base
    self.quote = quote
    self.rateE8 = rateE8
    self.provider = provider
    self.fetchedAt = fetchedAt
  }
}

/// A user-set rate (R-FX-2): one day (`untilDay == fromDay`) or from a day until changed
/// (`untilDay == nil`). Overrides win over fetched rates.
@Table("fxOverrides")
public struct FXOverride: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var base: Currency
  public var quote: Currency
  public var rateE8: Int64
  public var fromDay: String
  public var untilDay: String?
  public var note: String

  public init(
    id: UUID = UUID(), base: Currency, quote: Currency, rateE8: Int64, fromDay: String,
    untilDay: String? = nil, note: String = ""
  ) {
    self.id = id
    self.base = base
    self.quote = quote
    self.rateE8 = rateE8
    self.fromDay = fromDay
    self.untilDay = untilDay
    self.note = note
  }
}

// MARK: - Import (R-IMP)

public enum ImportSource: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case saldo, pko
}

@Table("importBatches")
public struct ImportBatch: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var source: ImportSource
  public var fileName: String
  public var importedAt: Date
  /// PKO: the account the file belongs to.
  public var accountID: Account.ID?
  /// Human-readable counts shown in the import history.
  public var summary: String
  public var isUndone: Bool

  public init(
    id: UUID = UUID(), source: ImportSource, fileName: String, importedAt: Date = Date(),
    accountID: Account.ID? = nil, summary: String = "", isUndone: Bool = false
  ) {
    self.id = id
    self.source = source
    self.fileName = fileName
    self.importedAt = importedAt
    self.accountID = accountID
    self.summary = summary
    self.isUndone = isUndone
  }
}

/// Exact-dedupe key of an imported row (R-IMP-3). The fingerprint itself is the primary key,
/// which is what makes it unique without a UNIQUE constraint. ASCII, < 255 chars: `saldo:<id>`,
/// `pko:<sha256 hex>`.
@Table("importFingerprints")
public struct ImportFingerprint: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public var id: String
  public var txnID: Txn.ID
  public var batchID: ImportBatch.ID?

  public init(id: String, txnID: Txn.ID, batchID: ImportBatch.ID? = nil) {
    self.id = id
    self.txnID = txnID
    self.batchID = batchID
  }
}

public enum MappingKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case account, category
}

/// Remembered source → Abacus mapping (R-IMP-2). `externalKey` e.g. "Monobank UAH|UAH".
@Table("importMappings")
public struct ImportMapping: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var source: ImportSource
  public var kind: MappingKind
  public var externalKey: String
  public var targetID: UUID

  public init(id: UUID = UUID(), source: ImportSource, kind: MappingKind, externalKey: String, targetID: UUID) {
    self.id = id
    self.source = source
    self.kind = kind
    self.externalKey = externalKey
    self.targetID = targetID
  }
}

// MARK: - Categorisation rules (R-IMP-8)

public enum RuleOrigin: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case imported, manual
}

/// How a rule's text is compared with the description (R-IMP-8). Both sides are folded for
/// case, diacritics and whitespace first. The raw values are stored in `categoryRules.matchKind`:
/// never rename them. `exactly` is "Description equals" (the whole description, C15).
public enum RuleMatchKind: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  /// The description contains the text anywhere.
  case contains
  /// The description begins with the text (C15).
  case startsWith
  /// The whole description equals the text ("Description equals").
  case exactly
}

/// The optional amount condition: the transaction's absolute amount in its account's currency
/// is strictly bigger / smaller than the rule's amount.
public enum RuleAmountComparison: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  case biggerThan, smallerThan
}

/// What a matching rule does.
public enum RuleAction: String, CaseIterable, Codable, Hashable, Sendable, QueryBindable {
  /// Assign `categoryID` (to an expense/income of the category's kind).
  case category
  /// Turn the transaction into a transfer between its own account and `transferAccountID`:
  /// money out → to that account, money in → from it (D44).
  case transfer
  /// Record the transaction as a debt record for `debtPersonName` (R-DEBT-12, C17): the
  /// person's debt in the account's currency, kind from the money's direction.
  case debt
}

/// A rule (R-IMP-8, D44): a description condition (`matchKind` + `pattern`) and/or an amount
/// condition (`amountComparison` + `amountMinor`) — at least one of the two (TA v1.6) — and an
/// optional account (`accountID`) → an action (`category` with `categoryID`, or `transfer` with
/// `transferAccountID`). An empty `pattern` means "no description condition" (C9: the column
/// stays NOT NULL, no table rebuild). The table keeps its name from the category-only rules
/// (schema v6 rebuilt it).
@Table("categoryRules")
public struct CategoryRule: Hashable, Identifiable, Sendable {
  public let id: UUID
  /// The description text; empty = no description condition (an amount-only rule).
  public var pattern: String
  /// Only on this account; nil = any account.
  public var accountID: Account.ID?
  /// Set when `action == .category`.
  public var categoryID: Category.ID?
  public var origin: RuleOrigin
  public var hitCount: Int
  public var position: Int
  public var isEnabled: Bool
  public var matchKind: RuleMatchKind
  public var amountComparison: RuleAmountComparison?
  /// Positive minor units, compared with each transaction's amount in its account's currency.
  public var amountMinor: Int64?
  public var action: RuleAction
  /// Set when `action == .transfer`.
  public var transferAccountID: Account.ID?
  /// Set when `action == .debt`: the person the debt record is for (schema v12).
  public var debtPersonName: String?

  public init(
    id: UUID = UUID(), pattern: String, matchKind: RuleMatchKind = .contains,
    amountComparison: RuleAmountComparison? = nil, amountMinor: Int64? = nil,
    accountID: Account.ID? = nil, action: RuleAction = .category, categoryID: Category.ID? = nil,
    transferAccountID: Account.ID? = nil, debtPersonName: String? = nil, origin: RuleOrigin = .manual,
    hitCount: Int = 0, position: Int = 0, isEnabled: Bool = true
  ) {
    self.id = id
    self.pattern = pattern
    self.matchKind = matchKind
    self.amountComparison = amountComparison
    self.amountMinor = amountMinor
    self.accountID = accountID
    self.action = action
    self.categoryID = categoryID
    self.transferAccountID = transferAccountID
    self.debtPersonName = debtPersonName
    self.origin = origin
    self.hitCount = hitCount
    self.position = position
    self.isEnabled = isEnabled
  }
}

extension CategoryRule {
  /// The rule has a description condition (a non-blank `pattern`).
  public var hasDescriptionCondition: Bool { !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// The rule has an amount condition.
  public var hasAmountCondition: Bool { amountComparison != nil && amountMinor != nil }

  /// A rule needs a description condition, an amount condition or both (TA v1.6); a rule with
  /// neither never matches.
  public var hasCondition: Bool { hasDescriptionCondition || hasAmountCondition }

  /// The person of a debt rule, trimmed; nil when blank (R-DEBT-12).
  public var debtPerson: String? {
    let name = (debtPersonName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}

/// The fields a rule changes on a transaction (category, or the transfer conversion), as they
/// were before or after one "Update existing transactions" (R-IMP-8 rollback, C9).
public struct RuleTxnState: Codable, Hashable, Sendable {
  public var type: TxnType
  public var accountID: Account.ID
  public var amountMinor: Int64
  public var categoryID: Category.ID?
  public var toAccountID: Account.ID?
  public var toAmountMinor: Int64?
  public var isRefund: Bool
  public var originalAmountMinor: Int64?
  public var originalCurrencyCode: String?

  public init(_ txn: Txn) {
    type = txn.type
    accountID = txn.accountID
    amountMinor = txn.amountMinor
    categoryID = txn.categoryID
    toAccountID = txn.toAccountID
    toAmountMinor = txn.toAmountMinor
    isRefund = txn.isRefund
    originalAmountMinor = txn.originalAmountMinor
    originalCurrencyCode = txn.originalCurrencyCode
  }

  /// `txn` with these fields; everything else (description, note, date, event…) stays.
  public func applied(to txn: Txn) -> Txn {
    var txn = txn
    txn.type = type
    txn.accountID = accountID
    txn.amountMinor = amountMinor
    txn.categoryID = categoryID
    txn.toAccountID = toAccountID
    txn.toAmountMinor = toAmountMinor
    txn.isRefund = isRefund
    txn.originalAmountMinor = originalAmountMinor
    txn.originalCurrencyCode = originalCurrencyCode
    return txn
  }
}

/// One transaction changed by applying a rule to existing transactions (R-IMP-8, R-MGMT-6,
/// TA v1.6 rollback): the rule-changed fields before and after. Rows of one "Save & apply" share
/// `batchID`. Rolling the rule back restores `before` on transactions that still hold `after`
/// and deletes the rows. Deleting the rule or the transaction deletes its rows (CASCADE).
@Table("ruleApplications")
public struct RuleApplication: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var ruleID: CategoryRule.ID
  public var batchID: UUID
  public var txnID: Txn.ID
  public var appliedAt: Date
  @Column(as: RuleTxnState.JSONRepresentation.self)
  public var before: RuleTxnState
  @Column(as: RuleTxnState.JSONRepresentation.self)
  public var after: RuleTxnState

  public init(
    id: UUID = UUID(), ruleID: CategoryRule.ID, batchID: UUID, txnID: Txn.ID, appliedAt: Date = Date(),
    before: RuleTxnState, after: RuleTxnState
  ) {
    self.id = id
    self.ruleID = ruleID
    self.batchID = batchID
    self.txnID = txnID
    self.appliedAt = appliedAt
    self.before = before
    self.after = after
  }

  /// One record per changed transaction: `originals` as they are now, `changes` as the rule
  /// leaves them (matched by id; changes without an original are skipped).
  public static func records(
    ruleID: CategoryRule.ID, originals: [Txn], changes: [Txn], batchID: UUID = UUID(), at date: Date = Date()
  ) -> [RuleApplication] {
    let byID = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return changes.compactMap { change in
      byID[change.id].map {
        RuleApplication(
          ruleID: ruleID, batchID: batchID, txnID: change.id, appliedAt: date, before: RuleTxnState($0),
          after: RuleTxnState(change))
      }
    }
  }

  /// The transaction restored, or nil when it was edited since (its rule-changed fields no
  /// longer hold what the rule set).
  public func restoring(_ current: Txn) -> Txn? {
    guard current.id == txnID, RuleTxnState(current) == after else { return nil }
    return before.applied(to: current)
  }
}

/// What "Roll back" did: transactions restored, and those left alone because they were edited
/// since the rule changed them (or what they referred to is gone).
public struct RuleRollback: Hashable, Sendable {
  public var restored: Int
  public var skipped: Int

  public init(restored: Int = 0, skipped: Int = 0) {
    self.restored = restored
    self.skipped = skipped
  }
}

// MARK: - Settings (R-SET)

public enum SettingKey: String, CaseIterable, Sendable {
  /// `Currency.rawValue`; default UAH.
  case displayCurrency
  /// "true"/"false"; default false (R-SET-3).
  case refundsReduceSpending
  /// "true"/"false"; default true (R-FX-1).
  case ratesAutoRefresh
  /// Editor defaults (R-EDIT-4/5): last used transaction currency (ISO code) and account,
  /// and the accounts of the last transfer (UUID strings).
  case lastTxnCurrency
  case lastAccountID
  case lastTransferFromID
  case lastTransferToID
  /// `YYYY-MM-DD` of the last backup export (R-SET-2, Settings › Data).
  case lastBackupExport
  /// `#RRGGBB` of the built-in "Uncategorised" entry (D47); default `Uncategorised.defaultColorHex`.
  case uncategorisedColor
  /// The Categories page sort (`CategorySort.rawValue`); default custom order (R-MGMT-8).
  case categorySort
  /// The Accounts page sort (`AccountSort.rawValue`); default custom order (R-MGMT-9).
  case accountSort
  /// The dashboard widget order (`DashboardLayout`): a JSON array of widget ids (R-HOME-6).
  case dashboardLayout
}

@Table("appSettings")
public struct AppSetting: Hashable, Identifiable, Sendable {
  /// `SettingKey.rawValue`.
  @Column(primaryKey: true)
  public var id: String
  public var value: String

  public init(_ key: SettingKey, value: String) {
    self.id = key.rawValue
    self.value = value
  }
}
