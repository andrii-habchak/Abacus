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
  public var groupName: String?
  public var colorHex: String?
  public var icon: String?
  public var position: Int
  public var isArchived: Bool

  public init(
    id: UUID = UUID(), name: String, currency: Currency, kind: AccountKind,
    openingBalanceMinor: Int64 = 0, openingDate: Date, iban: String? = nil,
    groupName: String? = nil, colorHex: String? = nil, icon: String? = nil,
    position: Int = 0, isArchived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.currency = currency
    self.kind = kind
    self.openingBalanceMinor = openingBalanceMinor
    self.openingDate = openingDate
    self.iban = iban
    self.groupName = groupName
    self.colorHex = colorHex
    self.icon = icon
    self.position = position
    self.isArchived = isArchived
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

  public init(
    id: UUID = UUID(), name: String, kind: CategoryKind, parentID: Category.ID? = nil,
    icon: String? = nil, colorHex: String? = nil, position: Int = 0, isArchived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.parentID = parentID
    self.icon = icon
    self.colorHex = colorHex
    self.position = position
    self.isArchived = isArchived
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
  public var isArchived: Bool

  public init(
    id: UUID = UUID(), name: String, startDay: String? = nil, endDay: String? = nil,
    budgetMinor: Int64? = nil, budgetCurrency: Currency? = nil, isArchived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.startDay = startDay
    self.endDay = endDay
    self.budgetMinor = budgetMinor
    self.budgetCurrency = budgetCurrency
    self.isArchived = isArchived
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

  public init(
    id: UUID = UUID(), type: TxnType, occurredAt: Date, accountID: Account.ID,
    amountMinor: Int64, categoryID: Category.ID? = nil, toAccountID: Account.ID? = nil,
    toAmountMinor: Int64? = nil, isRefund: Bool = false, originalAmountMinor: Int64? = nil,
    originalCurrencyCode: String? = nil, payee: String = "", note: String = "",
    eventID: Event.ID? = nil, source: TxnSource = .manual, importBatchID: ImportBatch.ID? = nil,
    isPendingAtBank: Bool = false, createdAt: Date = Date()
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
  }
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
@Table("budgetPlans")
public struct BudgetPlan: Hashable, Identifiable, Sendable {
  public let id: UUID
  /// `YYYY-MM` (see `Month`).
  public var effectiveMonth: String
  public var totalMinor: Int64
  public var currency: Currency

  public init(id: UUID = UUID(), effectiveMonth: String, totalMinor: Int64, currency: Currency) {
    self.id = id
    self.effectiveMonth = effectiveMonth
    self.totalMinor = totalMinor
    self.currency = currency
  }
}

/// A category's share of a plan's total (R-BUD-1). A parent's limit covers its children.
@Table("budgetAllocations")
public struct BudgetAllocation: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var planID: BudgetPlan.ID
  public var categoryID: Category.ID
  public var limitMinor: Int64

  public init(id: UUID = UUID(), planID: BudgetPlan.ID, categoryID: Category.ID, limitMinor: Int64) {
    self.id = id
    self.planID = planID
    self.categoryID = categoryID
    self.limitMinor = limitMinor
  }
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

/// "Description contains `pattern` → category" (case-insensitive), optionally per account.
@Table("categoryRules")
public struct CategoryRule: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var pattern: String
  public var accountID: Account.ID?
  public var categoryID: Category.ID
  public var origin: RuleOrigin
  public var hitCount: Int
  public var position: Int
  public var isEnabled: Bool

  public init(
    id: UUID = UUID(), pattern: String, accountID: Account.ID? = nil, categoryID: Category.ID,
    origin: RuleOrigin = .manual, hitCount: Int = 0, position: Int = 0, isEnabled: Bool = true
  ) {
    self.id = id
    self.pattern = pattern
    self.accountID = accountID
    self.categoryID = categoryID
    self.origin = origin
    self.hitCount = hitCount
    self.position = position
    self.isEnabled = isEnabled
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
