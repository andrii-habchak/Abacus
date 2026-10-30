import Foundation

// Contracts between lanes (PLAN.md §1). AbacusStore implements them (WP A5); calculators,
// importers and view models depend only on these. Read-only screens may also observe tables
// directly with SQLiteData's @FetchAll/@FetchOne.

public enum RepositoryError: Error, Equatable, Sendable {
  case notFound
  /// R-ACC-5: an account with transactions can only be archived.
  case accountHasTransactions
  /// R-CAT-3: a category in use needs a reassignment target of the same kind.
  case categoryInUse
  case kindMismatch
}

public protocol AccountRepository: Sendable {
  func accounts(includeArchived: Bool) async throws -> [Account]
  func save(_ account: Account) async throws
  /// Callers warn first when the balance is not zero (R-ACC-4).
  func setArchived(_ id: Account.ID, _ isArchived: Bool) async throws
  /// Throws `accountHasTransactions` when the account is used (R-ACC-5).
  func delete(_ id: Account.ID) async throws
  /// Account groups (R-MGMT-9, D48), in custom order.
  func groups() async throws -> [AccountGroup]
  /// Inserts or updates a group.
  func saveGroup(_ group: AccountGroup) async throws
  /// Deletes a group; its accounts move to the top level (no account is touched otherwise).
  func deleteGroup(_ id: AccountGroup.ID) async throws
}

extension AccountRepository {
  /// Read-only fakes without groups: every account is at the top level.
  public func groups() async throws -> [AccountGroup] { [] }
  public func saveGroup(_ group: AccountGroup) async throws { throw RepositoryError.notFound }
  public func deleteGroup(_ id: AccountGroup.ID) async throws { throw RepositoryError.notFound }
}

public protocol CategoryRepository: Sendable {
  func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [Category]
  func save(_ category: Category) async throws
  func setArchived(_ id: Category.ID, _ isArchived: Bool) async throws
  /// Moves transactions, attached records, budget allocations and rules to `reassignTo`
  /// (same kind) before deleting; children move up to top level. Throws `categoryInUse` when
  /// the category is used and `reassignTo` is nil (R-CAT-3).
  func delete(_ id: Category.ID, reassignTo: Category.ID?) async throws
}

/// Filters of the transaction list (R-LIST-2…6). Empty sets mean "any".
public struct TxnQuery: Hashable, Sendable {
  public var fromDay: Day?
  public var toDay: Day?
  /// A parent category matches its children too.
  public var categoryIDs: Set<Category.ID>
  public var accountIDs: Set<Account.ID>
  public var types: Set<TxnType>
  public var eventIDs: Set<Event.ID>
  /// Case-insensitive match on payee and note.
  public var search: String
  public var newestFirst: Bool
  /// Only expenses/incomes without a category (dashboard "Uncategorised" slice). Combines with
  /// `categoryIDs` as "uncategorised OR one of these".
  public var includeUncategorised: Bool
  /// Only transactions created by these imports ("Show transactions" after an import).
  public var importBatchIDs: Set<ImportBatch.ID>
  /// "Uncategorised" also matches transfers (they never have a category). Set while a debt is
  /// filtered: its rows are transfers, so the Categories menu can offer Uncategorised (C28).
  public var uncategorisedIncludesTransfers: Bool

  public init(
    fromDay: Day? = nil, toDay: Day? = nil, categoryIDs: Set<Category.ID> = [],
    accountIDs: Set<Account.ID> = [], types: Set<TxnType> = [], eventIDs: Set<Event.ID> = [],
    search: String = "", newestFirst: Bool = true, includeUncategorised: Bool = false,
    importBatchIDs: Set<ImportBatch.ID> = [], uncategorisedIncludesTransfers: Bool = false
  ) {
    self.fromDay = fromDay
    self.toDay = toDay
    self.categoryIDs = categoryIDs
    self.accountIDs = accountIDs
    self.types = types
    self.eventIDs = eventIDs
    self.search = search
    self.newestFirst = newestFirst
    self.includeUncategorised = includeUncategorised
    self.importBatchIDs = importBatchIDs
    self.uncategorisedIncludesTransfers = uncategorisedIncludesTransfers
  }

  /// R-LIST-1: the last 30 days, newest first.
  public static func lastThirtyDays(today: Day) -> TxnQuery {
    TxnQuery(fromDay: today.adding(days: -29), toDay: today)
  }
}

/// A filter dimension whose menu offers only values that have rows under all the other filters
/// (R-LIST-2, C28 cascading filters).
public enum TxnFacetDimension: Hashable, CaseIterable, Sendable {
  /// Accounts (either side of a transfer); debts are derived from their accounts.
  case accounts
  case categories
  case events
  case types
}

extension TxnQuery {
  /// The query without the filter of `dimension`: what that dimension's menu is computed under.
  public func dropping(_ dimension: TxnFacetDimension) -> TxnQuery {
    var copy = self
    switch dimension {
    case .accounts: copy.accountIDs = []
    case .categories:
      copy.categoryIDs = []
      copy.includeUncategorised = false
    case .events: copy.eventIDs = []
    case .types: copy.types = []
    }
    return copy
  }
}

/// How many rows of a query have each value of one dimension (`TxnRepository.facets`). Only values
/// with at least one row appear.
public struct TxnFacetCounts: Hashable, Sendable {
  /// Rows touching the account (either side of a transfer).
  public var accounts: [UUID: Int] = [:]
  /// Rows whose own category, or one of whose attached records' categories, is this one (exact
  /// category, parents not summed up).
  public var categories: [UUID: Int] = [:]
  /// Expenses and incomes without a category (with `uncategorisedIncludesTransfers`: any type).
  public var uncategorised = 0
  public var events: [UUID: Int] = [:]
  public var types: [TxnType: Int] = [:]

  public init() {}
}

/// What the footer and the day headers of a filtered list need, for the WHOLE filtered set and
/// without its rows (R-LIST-4/5, C28 paging): the row count and the amounts as light flows,
/// grouped by minute, account, type, refund flag and category. The feature layer applies its
/// totals rule and converts each day at its rate (R-FX-3).
public struct TxnListSummary: Hashable, Sendable {
  /// A transaction's main amount.
  public struct Main: Hashable, Sendable {
    public var occurredAt: Date
    public var accountID: UUID
    public var type: TxnType
    public var isRefund: Bool
    /// An expense refund linked to its original (C30): nets its category whatever R-SET-3 says.
    public var isLinkedRefund: Bool
    public var categoryID: UUID?
    public var amountMinor: Int64

    public init(
      occurredAt: Date, accountID: UUID, type: TxnType, isRefund: Bool, categoryID: UUID?, amountMinor: Int64,
      isLinkedRefund: Bool = false
    ) {
      self.isLinkedRefund = isLinkedRefund
      self.occurredAt = occurredAt
      self.accountID = accountID
      self.type = type
      self.isRefund = isRefund
      self.categoryID = categoryID
      self.amountMinor = amountMinor
    }
  }

  /// An attached record's amount, on its transaction's day and account.
  public struct Line: Hashable, Sendable {
    public var occurredAt: Date
    public var accountID: UUID
    public var kind: CategoryKind
    public var categoryID: UUID?
    public var amountMinor: Int64

    public init(occurredAt: Date, accountID: UUID, kind: CategoryKind, categoryID: UUID?, amountMinor: Int64) {
      self.occurredAt = occurredAt
      self.accountID = accountID
      self.kind = kind
      self.categoryID = categoryID
      self.amountMinor = amountMinor
    }
  }

  /// Transactions in the filtered set.
  public var count: Int
  public var mains: [Main]
  public var lines: [Line]

  public init(count: Int = 0, mains: [Main] = [], lines: [Line] = []) {
    self.count = count
    self.mains = mains
    self.lines = lines
  }

  /// From fetched rows (fakes, previews, tests).
  public init(rows: [TxnWithLines]) {
    count = rows.count
    mains = rows.map {
      Main(
        occurredAt: $0.txn.occurredAt, accountID: $0.txn.accountID, type: $0.txn.type, isRefund: $0.txn.isRefund,
        categoryID: $0.txn.categoryID, amountMinor: $0.txn.amountMinor, isLinkedRefund: $0.txn.isLinkedRefund)
    }
    lines = rows.flatMap { row in
      row.lines.map {
        Line(
          occurredAt: row.txn.occurredAt, accountID: row.txn.accountID, kind: $0.kind, categoryID: $0.categoryID,
          amountMinor: $0.amountMinor)
      }
    }
  }
}

public struct TxnWithLines: Hashable, Sendable {
  public var txn: Txn
  public var lines: [AttachedRecord]

  public init(txn: Txn, lines: [AttachedRecord]) {
    self.txn = txn
    self.lines = lines
  }
}

public protocol TxnRepository: Sendable {
  func transactions(matching query: TxnQuery) async throws -> [TxnWithLines]
  /// `limit` rows of the query's order starting at `offset` (the list loads pages, C28).
  func page(matching query: TxnQuery, offset: Int, limit: Int) async throws -> [TxnWithLines]
  /// Count and amounts of the whole filtered set, without its rows.
  func summary(matching query: TxnQuery) async throws -> TxnListSummary
  /// Per-value row counts of one dimension under the query's OTHER filters (the dimension's own
  /// filter is dropped), computed with aggregate queries.
  func facets(matching query: TxnQuery, dimension: TxnFacetDimension) async throws -> TxnFacetCounts
  /// One transaction with its attached records, or nil.
  func transaction(_ id: Txn.ID) async throws -> TxnWithLines?
  /// Replaces the transaction's attached records with `lines`.
  func save(_ txn: Txn, lines: [AttachedRecord]) async throws
  func delete(_ id: Txn.ID) async throws
}

extension TxnRepository {
  /// Fallbacks for simple implementations (fakes); the store answers these in SQL.
  public func page(matching query: TxnQuery, offset: Int, limit: Int) async throws -> [TxnWithLines] {
    let all = try await transactions(matching: query)
    guard offset < all.count else { return [] }
    return Array(all[offset..<min(all.count, offset + limit)])
  }

  public func summary(matching query: TxnQuery) async throws -> TxnListSummary {
    TxnListSummary(rows: try await transactions(matching: query))
  }

  public func facets(matching query: TxnQuery, dimension: TxnFacetDimension) async throws -> TxnFacetCounts {
    var counts = TxnFacetCounts()
    for row in try await transactions(matching: query.dropping(dimension)) {
      let txn = row.txn
      counts.accounts[txn.accountID, default: 0] += 1
      if let to = txn.toAccountID, to != txn.accountID { counts.accounts[to, default: 0] += 1 }
      let categories = Set(([txn.categoryID] + row.lines.map(\.categoryID)).compactMap { $0 })
      for id in categories { counts.categories[id, default: 0] += 1 }
      if txn.categoryID == nil, txn.type != .transfer || query.uncategorisedIncludesTransfers { counts.uncategorised += 1 }
      if let event = txn.eventID { counts.events[event, default: 0] += 1 }
      counts.types[txn.type, default: 0] += 1
    }
    return counts
  }

  /// Fallback for simple implementations (fakes); stores provide a direct lookup.
  public func transaction(_ id: Txn.ID) async throws -> TxnWithLines? {
    try await transactions(matching: TxnQuery()).first { $0.txn.id == id }
  }
}

public protocol BudgetRepository: Sendable {
  /// The plan in effect for `month`: the latest plan with `effectiveMonth <= month`.
  func plan(for month: Month) async throws -> (plan: BudgetPlan, allocations: [BudgetAllocation])?
  /// Saves a plan effective from its month onward (R-BUD-3).
  func save(_ plan: BudgetPlan, allocations: [BudgetAllocation]) async throws
}

public protocol EventRepository: Sendable {
  func events(includeArchived: Bool) async throws -> [Event]
  func save(_ event: Event) async throws
  func setArchived(_ id: Event.ID, _ isArchived: Bool) async throws
  /// Clears the event from its transactions, then deletes it.
  func delete(_ id: Event.ID) async throws
}

public protocol RuleRepository: Sendable {
  func rules() async throws -> [CategoryRule]
  func save(_ rule: CategoryRule) async throws
  /// Saves the rule and replaces the given existing transactions (the rule applied to them,
  /// "Update existing transactions", R-MGMT-6) in one database transaction; attached records
  /// are kept. Throws `notFound` (and writes nothing) when one of them no longer exists.
  /// `rule == nil` only replaces the transactions (undo).
  func save(_ rule: CategoryRule?, updating txns: [Txn]) async throws
  /// "Update existing transactions" (R-MGMT-6, TA v1.6): saves the rule, writes each record's
  /// `after` state onto its transaction and keeps the records for rollback — one database
  /// transaction. Throws `notFound` (and writes nothing) when a transaction no longer exists.
  func apply(_ rule: CategoryRule, records: [RuleApplication]) async throws
  /// The rule's recorded applications, newest first.
  func applications(of ruleID: CategoryRule.ID) async throws -> [RuleApplication]
  /// Rolls back every recorded application of the rule, newest first: a transaction whose
  /// rule-changed fields still hold the record's `after` gets `before` back (other edits stay);
  /// one edited since — or whose old category/account no longer exists — is left alone. The
  /// records are deleted. One database transaction.
  func rollBack(_ ruleID: CategoryRule.ID) async throws -> RuleRollback
  func delete(_ id: CategoryRule.ID) async throws
  func recordHit(_ id: CategoryRule.ID) async throws
}

public protocol SettingsRepository: Sendable {
  func value(_ key: SettingKey) async throws -> String?
  func set(_ key: SettingKey, _ value: String) async throws
}

/// Rates cache and manual overrides (R-FX).
public protocol RateStore: Sendable {
  func rates(from: Day, to: Day) async throws -> [FXRate]
  func latestRates() async throws -> [FXRate]
  func save(_ rates: [FXRate]) async throws
  func overrides() async throws -> [FXOverride]
  func save(_ override: FXOverride) async throws
  func deleteOverride(_ id: FXOverride.ID) async throws
}

/// What an import commit writes (R-IMP-6). Everything in one database transaction.
public struct ImportCommit: Sendable {
  public var batch: ImportBatch
  public var newAccounts: [Account]
  public var newCategories: [Category]
  public var newEvents: [Event]
  public var txns: [TxnWithLines]
  public var fingerprints: [ImportFingerprint]
  /// Existing transactions changed by the import: pending→settled upgrades and links (R-IMP-4,
  /// R-IMP-PKO-2). Their new fingerprints are in `fingerprints`.
  public var updatedTxns: [Txn]
  public var mappings: [ImportMapping]
  public var rules: [CategoryRule]
  /// New transactions that become debt records' legs (import row action and rules, R-DEBT-10/12),
  /// converted after the inserts, oldest first.
  public var debtLinks: [ImportDebtLink]

  public init(
    batch: ImportBatch, newAccounts: [Account] = [], newCategories: [Category] = [],
    newEvents: [Event] = [], txns: [TxnWithLines] = [], fingerprints: [ImportFingerprint] = [],
    updatedTxns: [Txn] = [], mappings: [ImportMapping] = [], rules: [CategoryRule] = [],
    debtLinks: [ImportDebtLink] = []
  ) {
    self.batch = batch
    self.newAccounts = newAccounts
    self.newCategories = newCategories
    self.newEvents = newEvents
    self.txns = txns
    self.fingerprints = fingerprints
    self.updatedTxns = updatedTxns
    self.mappings = mappings
    self.rules = rules
    self.debtLinks = debtLinks
  }
}

public protocol ImportStore: Sendable {
  /// Fingerprint → transaction for the ones already imported (exact dedupe, R-IMP-3).
  func existingFingerprints(_ ids: [String]) async throws -> [String: Txn.ID]
  /// Possible duplicates for fuzzy dedupe (R-IMP-4): same account and amount, date window.
  func candidates(accountID: Account.ID, amountMinor: Int64, from: Day, to: Day) async throws -> [Txn]
  /// Pending PKO holds of an account in a date window (R-IMP-PKO-2).
  func pendingTxns(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn]
  func mappings(source: ImportSource) async throws -> [ImportMapping]
  func commit(_ commit: ImportCommit) async throws
  func batches() async throws -> [ImportBatch]
  /// Deletes the batch's transactions and fingerprints, marks it undone (R-IMP-6).
  func undo(_ batchID: ImportBatch.ID) async throws
  /// Debts and records with their legs: who an import row can be recorded for (R-DEBT-10/12).
  func debtBook() async throws -> DebtBook
}

extension ImportStore {
  /// Fakes without debts.
  public func debtBook() async throws -> DebtBook { .empty }
}
