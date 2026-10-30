import AbacusDomain
import Foundation

/// The status of a row in the import preview (R-IMP-1, design § 5 summary cards).
public enum RowStatus: String, CaseIterable, Hashable, Sendable {
  /// Will be imported (including opening balances of accounts this import creates).
  case new
  /// A fingerprint is already stored, or the other side of the transfer is (R-IMP-3).
  case alreadyImported
  /// Looks like an existing transaction from another source (R-IMP-4); skipped unless chosen.
  case possibleDuplicate
  /// Settles an imported PKO hold (R-IMP-PKO-2).
  case settlesPending
  /// Needs a decision before the import can run (R-IMP-5).
  case needsReview
  /// Not imported: e.g. an opening balance of an account that already exists (R-IMP-7).
  case skipped
}

public struct StatusCounts: Hashable, Sendable {
  public var new = 0
  public var alreadyImported = 0
  public var possibleDuplicate = 0
  public var settlesPending = 0
  public var needsReview = 0
  /// Preview rows with status `.skipped` plus source transactions the parser skipped.
  public var skipped = 0

  public var all: Int { new + alreadyImported + possibleDuplicate + settlesPending + needsReview + skipped }

  public subscript(status: RowStatus) -> Int {
    switch status {
    case .new: new
    case .alreadyImported: alreadyImported
    case .possibleDuplicate: possibleDuplicate
    case .settlesPending: settlesPending
    case .needsReview: needsReview
    case .skipped: skipped
    }
  }

  mutating func add(_ status: RowStatus) {
    switch status {
    case .new: new += 1
    case .alreadyImported: alreadyImported += 1
    case .possibleDuplicate: possibleDuplicate += 1
    case .settlesPending: settlesPending += 1
    case .needsReview: needsReview += 1
    case .skipped: skipped += 1
    }
  }
}

/// What to do with a possible duplicate (R-IMP-4). Default `skip`.
public enum DuplicateAction: String, CaseIterable, Hashable, Sendable {
  case skip
  case importAnyway
  /// Keep the existing transaction and store this row's fingerprint on it.
  case link
}

/// A decision for a *needs review* row (R-IMP-5).
public enum ReviewChoice: Hashable, Sendable {
  /// Pair with another unpaired transfer half of this file (by row id) into one transfer.
  case pair(rowID: String)
  /// The other half is an existing expense on another account: it becomes the transfer.
  case pairExisting(Txn.ID)
  /// A transfer between the row's account and `accountID` (e.g. "Transfer to my account").
  case transfer(accountID: Account.ID)
  /// Record as expense or income in a category (nil = uncategorised). Money keeps its
  /// direction: income recorded for money out is an income reversal, and so on.
  case record(CategoryKind, categoryID: AbacusDomain.Category.ID?)
  /// Transfer to a person's debt account (R-DEBT-10, R-DEBT-19).
  case debt(ImportDebtChoice)
  case skip
}

/// A row sent to a person's debt account (R-DEBT-10, R-DEBT-19): the person, the debt (an
/// existing one, else the person's debt is created on commit), the person's account the money goes
/// to or comes from (a linked account of that debt, else the debt's virtual account in `currency`,
/// created when missing). The row's transaction becomes a transfer between the row's account and
/// that account.
public struct ImportDebtChoice: Hashable, Sendable {
  public var personName: String
  /// nil = the person's debt, created on commit when there is none.
  public var debtID: Debt.ID?
  /// A linked account of the debt (external or virtual); nil = the debt's virtual account in
  /// `currency`.
  public var accountID: Account.ID?
  /// The currency of the person's account (the row account's by default).
  public var currency: Currency
  /// In the person's account currency when it differs from the row account's; nil = converted at
  /// the day's rate (or the row's original amount in that currency).
  public var amountMinor: Int64?

  public init(
    personName: String, debtID: Debt.ID? = nil, accountID: Account.ID? = nil, currency: Currency,
    amountMinor: Int64? = nil
  ) {
    self.personName = personName
    self.debtID = debtID
    self.accountID = accountID
    self.currency = currency
    self.amountMinor = amountMinor
  }
}

/// The transfer to a debt account a row becomes, as the preview shows it (R-DEBT-10/12/19).
public struct PreviewDebt: Hashable, Sendable {
  public var personName: String
  public var debtID: Debt.ID?
  public var accountID: Account.ID?
  /// The currency of the person's account.
  public var currency: Currency
  /// In the person's account currency; nil when unknown (another currency without a rate).
  public var amountMinor: Int64?
  /// The rule that made it ("Transfer to debt of …"); nil = chosen in the preview.
  public var ruleID: CategoryRule.ID?
  /// The commit creates the debt (the person has none yet).
  public var createsDebt: Bool { debtID == nil }

  /// The choice that reproduces it (the sheet starts from it).
  public var choice: ImportDebtChoice {
    ImportDebtChoice(
      personName: personName, debtID: debtID, accountID: accountID, currency: currency, amountMinor: amountMinor)
  }
}

/// Where a row's category comes from.
public enum CategorySource: Hashable, Sendable {
  /// The source file (Saldo category, via the category mapping).
  case file
  /// An existing categorisation rule (R-IMP-8): "By rule “x”".
  case rule(CategoryRule.ID, pattern: String)
  /// A rule this import learns from another row's choice.
  case learnedRule(pattern: String)
  /// Picked in the preview; `savesRule` tells whether it becomes a rule.
  case user
  /// No category yet ("Needs a category").
  case none
  /// Transfers, opening balances and rows that are not imported.
  case notApplicable
}

public struct DuplicateInfo: Hashable, Sendable {
  /// The existing transaction the row looks like.
  public var existing: Txn
  public var action: DuplicateAction
}

public struct ReviewInfo: Hashable, Sendable {
  public var reason: ReviewReason
  /// Halves of this file the row can be paired with, best first (row ids).
  public var pairRows: [String]
  /// Existing expenses that may be the other half.
  public var pairExisting: [Txn]
  /// What the importer would pick; not applied until the user (or
  /// `acceptSuggestedReviewChoices`) chooses.
  public var suggested: ReviewChoice
  public var choice: ReviewChoice?
}

/// One source row in the preview.
public struct PreviewRow: Identifiable, Hashable, Sendable {
  public var id: String { source.id }
  public let source: NormalizedRow
  public internal(set) var status: RowStatus
  /// A short explanation: "Settles the pending payment of 2026-01-15", "Imported earlier", …
  public internal(set) var detail: String?
  /// The transaction type it becomes; nil for opening balances and rows not imported.
  public internal(set) var type: TxnType?
  public internal(set) var account: AccountRef
  public internal(set) var counterAccount: AccountRef?
  /// Positive, in the row account's currency; `isInflow` gives the direction on `account`.
  public internal(set) var amountMinor: Int64
  public internal(set) var counterAmountMinor: Int64?
  public internal(set) var isInflow: Bool
  public internal(set) var category: CategoryRef?
  public internal(set) var categorySource: CategorySource
  /// The rule pattern this row's category choice will be saved as (R-IMP-8).
  public internal(set) var rulePattern: String?
  public internal(set) var duplicate: DuplicateInfo?
  public internal(set) var review: ReviewInfo?
  /// The debt record the row becomes (R-DEBT-10/12).
  public internal(set) var debt: PreviewDebt?
  /// R-DEBT-13: the leg of the hand-entered debt record this row matches (status Already
  /// imported; the commit stores the row's fingerprints on it).
  public internal(set) var linkedDebtLeg: Txn?
  /// The tag's event when the tag is ticked (R-IMP-SALDO-4).
  public internal(set) var eventTag: String?
  /// True when committing creates a new transaction for this row.
  public internal(set) var createsTransaction: Bool

  public var warnings: [String] { source.warnings }
  public var day: Date { source.occurredAt }
  public var needsCategory: Bool {
    createsTransaction && debt == nil && (type == .expense || type == .income) && category == nil
  }

  /// The row can be recorded as a debt record: a new expense/income (also a possible duplicate
  /// imported anyway), a row already recorded as one, or a row in Needs review.
  public var canRecordDebt: Bool {
    if review != nil { return true }
    if debt != nil { return true }
    return createsTransaction && (type == .expense || type == .income)
  }
}

/// A Saldo tag the user may turn into an event (R-IMP-SALDO-4).
public struct EventCandidate: Identifiable, Hashable, Sendable {
  public var id: String { tag }
  public let tag: String
  public let rowCount: Int
  public let firstDay: Day
  public let lastDay: Day
  /// An existing event with the same name: rows go there instead of a new event.
  public let existingEventID: Event.ID?
  public internal(set) var isSelected: Bool
}

/// A rule the commit saves (R-IMP-8).
public struct RuleProposal: Identifiable, Hashable, Sendable {
  public var id: String { pattern }
  public let pattern: String
  public let categoryID: AbacusDomain.Category.ID
  /// Rows of this import it categorises (the one chosen included).
  public let rowCount: Int
}

public enum ImportPipelineError: Error, Equatable, Sendable {
  case unrecognisedFormat
  /// PKO statements name no account: pick one (R-IMP-PKO-1). `currency` is the file's.
  case targetAccountRequired(currency: Currency?)
  case unknownAccount
  case currencyMismatch
  /// Commit refused: unresolved review rows or other issues (see `ImportPreview.issues`).
  case notReady([String])
}
