import AbacusDomain
import Foundation

/// The import preview (R-IMP-1): every row with its status and choices, the mappings, events
/// from tags, rules to be saved and the counts of the summary cards. Nothing is written until
/// `ImportPipeline.commit(_:)`.
///
/// A value type: the wizard keeps it in its view model and changes it with the mutating
/// methods below; each change recomputes rows and counts. Changing an account mapping needs
/// the store again (dedupe depends on it), so it goes through `ImportPipeline.remapAccount`.
public struct ImportPreview: Sendable {
  public let batchID: ImportBatch.ID
  public let source: ImportSource
  public let fileName: String
  /// PKO: the account the statement is imported into (R-IMP-PKO-1).
  public let targetAccountID: Account.ID?
  /// PKO: true when the target account came from the remembered choice.
  public let targetRemembered: Bool
  public let fileWarnings: [ImportWarning]
  /// Source transactions the parser skipped (unsupported shapes); counted in `counts.skipped`.
  public let parserSkippedCount: Int
  /// Earliest and latest day of the file's rows.
  public let dateRange: ClosedRange<Day>?

  public private(set) var rows: [PreviewRow] = []
  public private(set) var accountMappings: [AccountMapping] = []
  public private(set) var categoryMappings: [CategoryMapping] = []
  public private(set) var eventCandidates: [EventCandidate] = []
  public private(set) var rulesToSave: [RuleProposal] = []
  public private(set) var counts = StatusCounts()
  /// Rows that will be imported without a category (footer).
  public private(set) var uncategorisedCount = 0
  /// Review rows without a choice yet; the commit waits for them (R-IMP-5).
  public private(set) var unresolvedReviewCount = 0
  /// Problems that block the commit besides unresolved review rows.
  public private(set) var issues: [String] = []
  /// New transactions the commit creates ("Import N transactions").
  public private(set) var transactionsToCreate = 0

  public var canCommit: Bool { unresolvedReviewCount == 0 && issues.isEmpty }

  // Inputs.
  let parsedRows: [NormalizedRow]
  let context: ImportContext
  let calendar: Calendar
  /// Day rates for debt records in another currency than the row's account (R-DEBT-10).
  let converter: (any CurrencyConverter)?
  var analysis: [RowAnalysis]
  let defaultAccountMappings: [AccountMapping]
  let defaultCategoryMappings: [CategoryMapping]
  var decisions = Decisions()
  // Outputs for the commit.
  private(set) var plans: [RowPlan] = []
  private var index: [String: Int] = [:]

  struct Decisions: Sendable {
    var accountTargets: [String: AccountMapping.Target] = [:]
    var categoryTargets: [String: CategoryMapping.Target] = [:]
    var categories: [String: AbacusDomain.Category.ID?] = [:]
    var duplicates: [String: DuplicateAction] = [:]
    var reviews: [String: ReviewChoice] = [:]
    var events: [String: Bool] = [:]
    var noRule: Set<String> = []
    /// R-DEBT-10: rows recorded as debt records, or kept from a debt rule (`nil` choice).
    var debts: [String: ImportDebtChoice?] = [:]
    /// Review rows recorded by `acceptDefaults()` into "Uncategorised" with a review note.
    var defaultHalves: Set<String> = []
  }

  init(
    batchID: ImportBatch.ID, parsed: ParsedImport, fileName: String, targetAccountID: Account.ID?,
    targetRemembered: Bool, context: ImportContext, calendar: Calendar, analysis: [RowAnalysis],
    accountMappings: [AccountMapping], categoryMappings: [CategoryMapping], converter: (any CurrencyConverter)? = nil
  ) {
    self.converter = converter
    self.batchID = batchID
    self.source = parsed.source
    self.fileName = fileName
    self.targetAccountID = targetAccountID
    self.targetRemembered = targetRemembered
    self.fileWarnings = parsed.warnings
    self.parserSkippedCount = parsed.skippedRowCount
    self.parsedRows = parsed.rows
    self.context = context
    self.calendar = calendar
    self.analysis = analysis
    self.defaultAccountMappings = accountMappings
    self.defaultCategoryMappings = categoryMappings
    let days = parsed.rows.map { $0.valueDay ?? Day($0.occurredAt, calendar: calendar) }
    if let first = days.min(), let last = days.max() { dateRange = first...last } else { dateRange = nil }
    self.index = Dictionary(parsed.rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    recompute()
  }

  // MARK: - Lookups

  public func row(_ id: String) -> PreviewRow? { index[id].map { rows[$0] } }

  public func rows(with status: RowStatus) -> [PreviewRow] { rows.filter { $0.status == status } }

  /// Existing accounts a source account can be mapped to (same currency).
  public func accountOptions(for key: String) -> [Account] {
    guard let mapping = accountMappings.first(where: { $0.id == key }) else { return [] }
    return context.accounts.filter { $0.currency == mapping.external.currency }
  }

  /// Existing categories a source category can be mapped to (same kind).
  public func categoryOptions(for key: String) -> [AbacusDomain.Category] {
    guard let mapping = categoryMappings.first(where: { $0.id == key }) else { return [] }
    return context.categories.filter { $0.kind == mapping.external.kind }
  }

  /// Display name of an account reference (existing or to be created).
  public func name(of ref: AccountRef) -> String {
    switch ref {
    case .existing(let id): return context.account(id)?.name ?? "?"
    case .new(let key): return accountMappings.first { $0.id == key }?.newName ?? key
    }
  }

  /// Display name of a category reference.
  public func name(of ref: CategoryRef) -> String {
    switch ref {
    case .existing(let id): return context.category(id)?.name ?? "?"
    case .new(let key): return categoryMappings.first { $0.id == key }?.external.name ?? key
    }
  }

  // MARK: - Choices

  /// Sets (or clears with nil) the category of an expense/income row. A row that had no
  /// category from the file or a rule also gets a rule proposal (R-IMP-8).
  public mutating func setCategory(_ categoryID: AbacusDomain.Category.ID?, forRow id: String) {
    decisions.categories[id] = .some(categoryID)
    recompute()
  }

  /// Back to the category from the file or the rules.
  public mutating func resetCategory(forRow id: String) {
    decisions.categories[id] = nil
    recompute()
  }

  /// Whether the row's category choice is saved as a rule (default: yes).
  public mutating func setSavesRule(_ saves: Bool, forRow id: String) {
    if saves { decisions.noRule.remove(id) } else { decisions.noRule.insert(id) }
    recompute()
  }

  // MARK: Debts (R-DEBT-10, docs/status/C17.md)

  /// Debts and records before this import: the people a row can be recorded for.
  public var debtBook: DebtBook { context.debts }

  /// Records a new row as a debt record (its transaction becomes the record's leg); nil = not a
  /// debt record (also overrides a "Record as debt" rule). Rows in Needs review use
  /// `setReviewChoice(.debt(…))`.
  public mutating func setDebt(_ choice: ImportDebtChoice?, forRow id: String) {
    decisions.debts[id] = .some(choice)
    recompute()
  }

  /// Back to what the rules decide.
  public mutating func resetDebt(forRow id: String) {
    decisions.debts[id] = nil
    recompute()
  }

  /// The currency of the row's account.
  public func accountCurrency(ofRow id: String) -> Currency? {
    row(id).flatMap { currency(of: $0.account) }
  }

  /// The debt's balance before the row (positive = they owe me): the stored records plus this
  /// import's debt rows dated earlier. `debtID` nil = the person's debt in `currency` (none = 0).
  public func debtBalance(person: String, currency: Currency, debtID: Debt.ID?, beforeRow id: String) -> Int64 {
    let target = debtID ?? context.debts.debt(person: person)?.id
    let key = Self.debtKey(person: person, currency: currency, debtID: target)
    var balance = target.map { context.debts.balance(of: $0, currency: currency) } ?? 0
    guard let position = index[id] else { return balance }
    let day = rows[position].day
    for (j, other) in rows.enumerated() where j != position {
      guard let debt = other.debt, let amount = debt.amountMinor,
        Self.debtKey(person: debt.personName, currency: debt.currency, debtID: debt.debtID ?? context.debts.debt(person: debt.personName)?.id) == key,
        (other.day, j) < (day, position)
      else { continue }
      balance += debt.kind.balanceSign * amount
    }
    return balance
  }

  /// What the sheet starts with for `person`: the person's debt in the account's currency (or a
  /// new one), the kind suggested from the money's direction and the debt's balance.
  public func suggestedDebtChoice(forRow id: String, person: String) -> ImportDebtChoice? {
    guard let row = row(id), let currency = accountCurrency(ofRow: id) else { return nil }
    let debt = context.debts.debt(person: person)
    let balance = debtBalance(person: person, currency: currency, debtID: debt?.id, beforeRow: id)
    return ImportDebtChoice(
      personName: person, debtID: debt?.id, currency: currency,
      kind: .suggested(inflow: row.isInflow, balance: balance))
  }

  static func debtKey(person: String, currency: Currency, debtID: Debt.ID?) -> String {
    debtID.map(\.uuidString) ?? "new|\(Debt.personKey(person))|\(currency.rawValue)"
  }

  public mutating func setDuplicateAction(_ action: DuplicateAction, forRow id: String) {
    decisions.duplicates[id] = action
    recompute()
  }

  /// Chooses how a review row is resolved; nil clears it. Pairing is mutual: the partner gets
  /// the reverse choice and its previous partner is cleared.
  public mutating func setReviewChoice(_ choice: ReviewChoice?, forRow id: String) {
    applyReviewChoice(choice, forRow: id)
    recompute()
  }

  /// Applies the suggested choice to every review row that has none.
  public mutating func acceptSuggestedReviewChoices() {
    for row in rows {
      guard let review = row.review, decisions.reviews[row.id] == nil else { continue }
      if case .pair(let other) = review.suggested, decisions.reviews[other] != nil { continue }
      applyReviewChoice(review.suggested, forRow: row.id)
    }
    recompute()
  }

  /// Name of the category `acceptDefaults()` records unpaired transfer halves in.
  public static let uncategorisedName = "Uncategorised"
  /// Note `acceptDefaults()` adds to an unpaired transfer half it records.
  public static let unpairedHalfNote = "Unpaired transfer half — review"

  /// Resolves every open choice with the wizard's defaults, for imports without the wizard:
  /// - account and category mappings stay as proposed (new ones are created);
  /// - possible duplicates without a choice are skipped; pending holds are upgraded (automatic);
  /// - no Saldo tag becomes an event;
  /// - an unpaired transfer half is recorded as expense (outgoing) or income (incoming) in an
  ///   "Uncategorised" category of that kind (created if missing) with the note
  ///   `unpairedHalfNote`; other review rows (unknown PKO types, transfers with an unknown
  ///   amount) are recorded by their sign, without a category.
  /// Choices already made are kept.
  public mutating func acceptDefaults() {
    for candidate in eventCandidates { decisions.events[candidate.tag] = false }
    for row in rows {
      guard let review = row.review, decisions.reviews[row.id] == nil else { continue }
      let kind: CategoryKind = row.source.flow == .in ? .income : .expense
      decisions.reviews[row.id] = .record(kind, categoryID: nil)
      if case .unpairedTransferHalf = review.reason { decisions.defaultHalves.insert(row.id) }
    }
    recompute()
  }

  /// A copy with `acceptDefaults()` applied.
  public func acceptingDefaults() -> ImportPreview {
    var preview = self
    preview.acceptDefaults()
    return preview
  }

  /// Ticks or unticks a Saldo tag to become an event (R-IMP-SALDO-4).
  public mutating func setEvent(tag: String, selected: Bool) {
    decisions.events[tag] = selected
    recompute()
  }

  /// Maps a source category to an existing category of the same kind or to a new one.
  public mutating func mapCategory(key: String, to target: CategoryMapping.Target) throws {
    guard let mapping = defaultCategoryMappings.first(where: { $0.id == key }) else { throw ImportPipelineError.unknownAccount }
    if case .existing(let id) = target {
      guard let category = context.category(id), category.kind == mapping.external.kind else {
        throw ImportPipelineError.currencyMismatch
      }
    }
    decisions.categoryTargets[key] = target
    recompute()
  }

  private mutating func applyReviewChoice(_ choice: ReviewChoice?, forRow id: String) {
    decisions.defaultHalves.remove(id)
    if case .pair(let old) = decisions.reviews[id], decisions.reviews[old] == .pair(rowID: id) {
      decisions.reviews[old] = nil
    }
    decisions.reviews[id] = choice
    if case .pair(let other) = choice {
      if case .pair(let previous) = decisions.reviews[other], previous != id {
        decisions.reviews[previous] = nil
      }
      decisions.reviews[other] = .pair(rowID: id)
    }
  }

  // MARK: - Resolution

  mutating func recompute() {
    accountMappings = defaultAccountMappings.map { mapping in
      var mapping = mapping
      if let target = decisions.accountTargets[mapping.id] {
        mapping.target = target
        mapping.origin = .user
      }
      return mapping
    }
    categoryMappings = defaultCategoryMappings.map { mapping in
      var mapping = mapping
      if let target = decisions.categoryTargets[mapping.id] {
        mapping.target = target
        mapping.origin = .user
      }
      return mapping
    }
    // The "Uncategorised" categories default-recorded halves go to, mapped like file categories.
    let defaultKinds = Set(decisions.defaultHalves.compactMap { id in
      index[id].map { parsedRows[$0].flow == .in ? CategoryKind.income : .expense }
    })
    for kind in CategoryKind.allCases where defaultKinds.contains(kind) {
      let external = ExternalCategory(name: Self.uncategorisedName, kind: kind)
      if !categoryMappings.contains(where: { $0.id == external.key }) {
        categoryMappings.append(MappingResolver.category(external, rowCount: 0, context: context))
      }
    }
    eventCandidates = makeEventCandidates()
    var resolver = Resolver(preview: self)
    resolver.run()
    rows = resolver.rows
    plans = resolver.plans
    rulesToSave = resolver.proposals
    issues = resolver.issues

    counts = StatusCounts()
    rows.forEach { counts.add($0.status) }
    counts.skipped += parserSkippedCount
    uncategorisedCount = rows.filter(\.needsCategory).count
    unresolvedReviewCount = rows.filter { $0.review != nil && $0.review?.choice == nil }.count
    transactionsToCreate = rows.filter(\.createsTransaction).count
  }

  private func makeEventCandidates() -> [EventCandidate] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    var ranges: [String: (Day, Day)] = [:]
    for row in parsedRows {
      guard let tag = row.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { continue }
      let day = Day(row.occurredAt, calendar: calendar)
      if counts[tag] == nil { order.append(tag) }
      counts[tag, default: 0] += 1
      let range = ranges[tag] ?? (day, day)
      ranges[tag] = (min(range.0, day), max(range.1, day))
    }
    return order.map { tag in
      let existing = context.events.first { MappingResolver.same($0.name, tag) }
      return EventCandidate(
        tag: tag, rowCount: counts[tag] ?? 0, firstDay: ranges[tag]!.0, lastDay: ranges[tag]!.1,
        existingEventID: existing?.id, isSelected: decisions.events[tag] ?? (existing != nil))
    }
  }

  func accountRef(_ account: ExternalAccount) -> AccountRef {
    if let id = account.resolvedID { return .existing(id) }
    switch accountMappings.first(where: { $0.id == account.key })?.target {
    case .existing(let id): return .existing(id)
    case .create, nil: return .new(key: account.key)
    }
  }

  func categoryRef(_ category: ExternalCategory?) -> CategoryRef? {
    guard let category else { return nil }
    switch categoryMappings.first(where: { $0.id == category.key })?.target {
    case .existing(let id): return .existing(id)
    case .create, nil: return .new(key: category.key)
    }
  }

  func currency(of ref: AccountRef) -> Currency? {
    switch ref {
    case .existing(let id): return context.account(id)?.currency
    case .new(let key): return accountMappings.first { $0.id == key }?.external.currency
    }
  }
}

// MARK: - Plans

/// A new transaction, before IDs are assigned.
struct TxnShape: Hashable, Sendable {
  var type: TxnType
  var from: AccountRef
  var to: AccountRef?
  var amountMinor: Int64
  var toAmountMinor: Int64?
  var isRefund = false
  var category: CategoryRef?
  var ruleID: CategoryRule.ID?
  var lines: [NormalizedLine] = []
  var occurredAt: Date
  var payee: String
  var note: String
  var original: OriginalAmount?
  var isPending = false
  var bookedDay: Day?
  var tag: String?
  var fingerprints: [String]
  /// R-DEBT-10/12: the transaction becomes this debt record's leg on commit.
  var debt: PreviewDebt?
}

/// What the commit does with a row.
enum RowPlan: Hashable, Sendable {
  case nothing
  /// Sets the opening balance of an account this import creates (R-IMP-SALDO-3).
  case openingBalance(AccountRef, Int64, Date)
  case create(TxnShape)
  /// Upgrades a pending hold (R-IMP-PKO-2).
  case settle(Txn, NormalizedRow)
  /// Stores the row's fingerprints on an existing transaction (R-IMP-4 link).
  case link(Txn, [String])
  /// Turns an existing expense/income into the transfer (other side already imported).
  case convert(Txn, TxnShape)
}

/// Turns parsed rows + analysis + decisions into preview rows and commit plans.
private struct Resolver {
  let preview: ImportPreview
  let matcher: RuleMatcher
  var rows: [PreviewRow] = []
  var plans: [RowPlan] = []
  var proposals: [RuleProposal] = []
  var issues: [String] = []

  init(preview: ImportPreview) {
    self.preview = preview
    self.matcher = RuleMatcher(rules: preview.context.rules, categories: preview.context.categories, accounts: preview.context.accounts)
  }

  var parsed: [NormalizedRow] { preview.parsedRows }
  var analysis: [RowAnalysis] { preview.analysis }
  var decisions: ImportPreview.Decisions { preview.decisions }

  func dayText(_ date: Date) -> String { Day(date, calendar: preview.calendar).string }

  mutating func run() {
    let selectedTags = Set(preview.eventCandidates.filter(\.isSelected).map(\.tag))
    for i in parsed.indices {
      var (row, plan) = resolve(i)
      if let tag = parsed[i].tag?.trimmingCharacters(in: .whitespacesAndNewlines), selectedTags.contains(tag) {
        row.eventTag = tag
        if case .create(var shape) = plan {
          shape.tag = tag
          plan = .create(shape)
        }
      }
      rows.append(row)
      plans.append(plan)
    }
    learnRules()
    assignRuleDebtKinds()
    checkConflicts()
  }

  // MARK: Rows

  private mutating func resolve(_ i: Int) -> (PreviewRow, RowPlan) {
    let source = parsed[i]
    let found = analysis[i]
    let account = preview.accountRef(source.account)
    var row = PreviewRow(
      source: source, status: .new, detail: nil, type: nil, account: account,
      counterAccount: source.counterAccount.map(preview.accountRef), amountMinor: source.amountMinor,
      counterAmountMinor: source.counterAmountMinor, isInflow: source.flow == .in, category: nil,
      categorySource: .notApplicable, rulePattern: nil, duplicate: nil, review: nil, debt: nil,
      linkedDebtLeg: nil, eventTag: nil, createsTransaction: false)

    if source.kind == .openingBalance {
      row.isInflow = source.amountMinor >= 0
      row.amountMinor = abs(source.amountMinor)
      if case .new = account {
        row.detail = "Opening balance of the new account"
        return (row, .openingBalance(account, source.amountMinor, source.occurredAt))
      }
      row.status = .skipped
      row.detail = "The account exists; its opening balance is not changed"
      return (row, .nothing)
    }
    if found.exactTxnID != nil {
      row.status = .alreadyImported
      row.detail = "Imported earlier"
      return (row, .nothing)
    }
    if let hold = found.settles {
      row.status = .settlesPending
      row.type = .expense
      row.detail = "Settles the pending payment of \(dayText(hold.occurredAt))"
      return (row, .settle(hold, source))
    }
    if let transfer = found.ownTransfer {
      row.type = .transfer
      row.counterAccount = .existing(transfer.ownAccountID)
      row.counterAmountMinor = row.isInflow ? transfer.amountMinor : transfer.toAmountMinor
      if let same = found.sameTransfer {
        row.status = .alreadyImported
        row.detail = "The other account's statement already has this transfer"
        return (row, .link(same, source.fingerprints))
      }
    }
    if let leg = found.debtLeg {
      // R-DEBT-13: a debt record entered by hand for this payment; never a second transaction.
      row.status = .alreadyImported
      row.linkedDebtLeg = leg
      row.detail = "Matches the debt record “\(leg.payee)” of \(dayText(leg.occurredAt))"
      return (row, .link(leg, source.fingerprints))
    }
    if let reason = found.review {
      return review(i, row, reason)
    }

    var shape = baseShape(source, found)
    row.type = shape.type
    var transferRuleDetail: String?
    if shape.type != .transfer, let (debt, ruleID) = debtDecision(for: source, shape: shape, account: account) {
      applyDebt(debt, ruleID: ruleID, source: source, shape: &shape, row: &row)
    } else if shape.type != .transfer, let (rule, accountID, otherAmount) = transferRule(for: source, shape: shape, account: account) {
      // A transfer rule (D44): money out → to the rule's account, money in → from it.
      let inflow = (shape.type == .income) != shape.isRefund
      shape.type = .transfer
      shape.original = nil
      shape.isRefund = false
      if inflow {
        shape.from = .existing(accountID)
        shape.to = account
        shape.toAmountMinor = shape.amountMinor
        shape.amountMinor = otherAmount
      } else {
        shape.to = .existing(accountID)
        shape.toAmountMinor = otherAmount
      }
      shape.ruleID = rule.id
      row.type = .transfer
      row.counterAccount = .existing(accountID)
      row.counterAmountMinor = otherAmount
      transferRuleDetail = "Transfer by rule “\(rule.label)”"
    } else if shape.type != .transfer {
      let (category, from, rule) = resolveCategory(for: source, kind: shape.type == .income ? .income : .expense, account: account, explicit: nil)
      shape.category = category
      shape.ruleID = rule
      row.category = category
      row.categorySource = from
      row.rulePattern = rulePattern(source, from)
    }
    row.detail = detail(source, found) ?? transferRuleDetail ?? row.detail

    if let existing = found.duplicate {
      let action = decisions.duplicates[source.id] ?? .skip
      row.status = .possibleDuplicate
      row.duplicate = DuplicateInfo(existing: existing, action: action)
      row.detail = "Looks like “\(existing.payee)” of \(dayText(existing.occurredAt)), same amount"
      switch action {
      case .skip:
        return (row, .nothing)
      case .link:
        return (row, .link(existing, source.fingerprints))
      case .importAnyway:
        row.createsTransaction = true
        return (row, .create(shape))
      }
    }
    if let other = found.completesTransfer {
      row.detail = "Completes the transfer imported from the other account on \(dayText(other.occurredAt))"
      return (row, .convert(other, shape))
    }
    row.createsTransaction = true
    return (row, .create(shape))
  }

  private func baseShape(_ source: NormalizedRow, _ found: RowAnalysis) -> TxnShape {
    var shape = TxnShape(
      type: .expense, from: preview.accountRef(source.account), amountMinor: source.amountMinor,
      isRefund: source.isRefund, lines: source.lines, occurredAt: source.occurredAt, payee: source.payee,
      note: source.note, original: source.original, isPending: source.isPending,
      bookedDay: bookedDay(source), fingerprints: source.fingerprints)
    if let transfer = found.ownTransfer {
      shape.type = .transfer
      shape.from = transfer.from
      shape.to = transfer.to
      shape.amountMinor = transfer.amountMinor
      shape.toAmountMinor = transfer.toAmountMinor
      shape.isRefund = false
      shape.original = nil
      return shape
    }
    switch source.kind {
    case .income: shape.type = .income
    case .transfer, .transferHalf:
      shape.type = .transfer
      shape.to = source.counterAccount.map(preview.accountRef)
      shape.toAmountMinor = source.counterAmountMinor ?? source.amountMinor
    case .expense, .openingBalance: shape.type = .expense
    }
    return shape
  }

  private func bookedDay(_ source: NormalizedRow) -> Day? {
    guard let booked = source.bookedDay else { return nil }
    return booked == (source.valueDay ?? Day(source.occurredAt, calendar: preview.calendar)) ? nil : booked
  }

  private func detail(_ source: NormalizedRow, _ found: RowAnalysis) -> String? {
    if found.ownTransfer != nil { return "Own account recognised by its account number → transfer" }
    if source.isPending { return "Pending at the bank" }
    if source.kind == .transfer, source.fingerprints.count == 2 { return "Two transfer halves paired" }
    if preview.source == .pko, source.kind == .transfer { return "ATM withdrawal → cash account" }
    return nil
  }

  // MARK: Categories and rules

  /// File category, else an existing rule; an explicit choice (review) or a user pick wins.
  private func resolveCategory(
    for source: NormalizedRow, kind: CategoryKind, account: AccountRef, explicit: AbacusDomain.Category.ID??
  ) -> (CategoryRef?, CategorySource, CategoryRule.ID?) {
    if let explicit {
      return (explicit.map(CategoryRef.existing), explicit == nil ? .none : .user, nil)
    }
    if let picked = decisions.categories[source.id] {
      return (picked.map(CategoryRef.existing), picked == nil ? .none : .user, nil)
    }
    if let fileCategory = preview.categoryRef(source.category), source.category?.kind == kind {
      return (fileCategory, .file, nil)
    }
    let accountID: Account.ID? = if case .existing(let id) = account { id } else { nil }
    if let rule = matcher.match(description: source.payee, accountID: accountID, kind: kind, amountMinor: abs(source.amountMinor)),
      let categoryID = rule.categoryID
    {
      return (.existing(categoryID), .rule(rule.id, pattern: rule.label), rule.id)
    }
    return (nil, .none, nil)
  }

  /// A transfer rule that wins for an expense/income row (D44): only when the file and the user
  /// gave no category and no earlier category rule matches. Skips a transfer rule whose amount in
  /// the other account's currency is unknown, and one that would move the row's attached records
  /// to the other account (money in), and tries the next rule.
  private func transferRule(
    for source: NormalizedRow, shape: TxnShape, account: AccountRef
  ) -> (CategoryRule, Account.ID, Int64)? {
    let kind: CategoryKind = shape.type == .income ? .income : .expense
    if decisions.categories[source.id] != nil { return nil }
    if preview.categoryRef(source.category) != nil, source.category?.kind == kind { return nil }
    let accountID: Account.ID? = if case .existing(let id) = account { id } else { nil }
    let subject = RuleSubject(description: source.payee, accountID: accountID, amountMinor: abs(source.amountMinor), kind: kind)
    for rule in matcher.candidates(for: subject) {
      guard rule.action == .transfer else { return nil }
      guard let (target, amount) = transferTarget(rule, source: source, shape: shape, account: account) else { continue }
      return (rule, target, amount)
    }
    return nil
  }

  /// The other account and the amount in its currency when `rule` (a transfer rule) can act on
  /// the row.
  private func transferTarget(
    _ rule: CategoryRule, source: NormalizedRow, shape: TxnShape, account: AccountRef
  ) -> (Account.ID, Int64)? {
    let inflow = (shape.type == .income) != shape.isRefund
    guard let target = rule.transferAccountID, let other = preview.context.account(target), !other.isArchived,
      account != .existing(target)
    else { return nil }
    if inflow, !shape.lines.isEmpty { return nil }
    guard let amount = amount(of: source, in: other.currency, accountCurrency: preview.currency(of: account)) else { return nil }
    return (target, amount)
  }

  // MARK: Debts (R-DEBT-10/12)

  /// The row's debt record: the user's choice, else a "Record as debt" rule that wins like a
  /// transfer rule (no file category, no category picked, the first rule that can act).
  private func debtDecision(
    for source: NormalizedRow, shape: TxnShape, account: AccountRef
  ) -> (ImportDebtChoice, CategoryRule.ID?)? {
    switch decisions.debts[source.id] {
    case .some(.some(let choice)): return (choice, nil)
    case .some(.none): return nil
    case .none: break
    }
    let kind: CategoryKind = shape.type == .income ? .income : .expense
    if decisions.categories[source.id] != nil { return nil }
    if preview.categoryRef(source.category) != nil, source.category?.kind == kind { return nil }
    guard let currency = preview.currency(of: account) else { return nil }
    let accountID: Account.ID? = if case .existing(let id) = account { id } else { nil }
    let subject = RuleSubject(description: source.payee, accountID: accountID, amountMinor: abs(source.amountMinor), kind: kind)
    for rule in matcher.candidates(for: subject) {
      switch rule.action {
      case .category:
        return nil
      case .transfer:
        if transferTarget(rule, source: source, shape: shape, account: account) != nil { return nil }
      case .debt:
        guard let person = rule.debtPerson else { continue }
        let debt = preview.context.debts.debt(person: person)
        // The kind is set from the running balance once every row is resolved.
        let inflow = (shape.type == .income) != shape.isRefund
        let balance = debt.map { preview.context.debts.balance(of: $0.id, currency: currency) } ?? 0
        let choice = ImportDebtChoice(
          personName: person, debtID: debt?.id, currency: currency, kind: .suggested(inflow: inflow, balance: balance))
        return (choice, rule.id)
      }
    }
    return nil
  }

  /// Makes the row's new transaction a debt record's leg: expense/income without category
  /// (money keeps its direction), the record's amount in the debt's currency.
  private mutating func applyDebt(
    _ choice: ImportDebtChoice, ruleID: CategoryRule.ID?, source: NormalizedRow, shape: inout TxnShape,
    row: inout PreviewRow
  ) {
    let inflow = (shape.type == .income) != shape.isRefund
    let currency = choice.currency
    var debtID = choice.debtID
    if let id = debtID {
      // R-DEBT-16: a debt has no currency; `currency` is the one of the person's account the
      // payment goes to (the choice's, by default the row account's).
      if preview.context.debts.debt(id) == nil {
        debtID = nil
        issues.append("“\(source.payee)”: the chosen debt no longer exists")
      }
    }
    let accountCurrency = preview.currency(of: shape.from)
    var amount: Int64?
    if currency == accountCurrency {
      amount = shape.amountMinor
    } else if let given = choice.amountMinor {
      amount = given
    } else if let original = shape.original, original.currencyCode == currency.rawValue {
      amount = original.minorUnits
    } else if let accountCurrency, let converter = preview.converter,
      let converted = converter.convert(
        Money(minorUnits: shape.amountMinor, currency: accountCurrency), to: currency,
        on: Day(shape.occurredAt, calendar: preview.calendar))
    {
      amount = converted.minorUnits
    } else {
      issues.append("“\(source.payee)”: the amount in \(currency.rawValue) is unknown; enter it in the debt record")
    }
    let kind = DebtRecordKind.linkable(inflow: inflow).contains(choice.kind)
      ? choice.kind : DebtRecordKind.suggested(inflow: inflow, balance: 0)
    let debt = PreviewDebt(
      personName: choice.personName.trimmingCharacters(in: .whitespacesAndNewlines), debtID: debtID,
      currency: currency, kind: kind, countsInReports: choice.countsInReports && kind.offeredReportKind != nil,
      amountMinor: amount, ruleID: ruleID)
    shape.category = nil
    shape.ruleID = ruleID
    shape.debt = debt
    row.type = shape.type
    row.debt = debt
    row.category = nil
    row.categorySource = .notApplicable
    row.rulePattern = nil
    row.detail = debtDetail(debt)
  }

  /// "I lent · Ann (new debt in EUR) · by rule “ann”".
  private func debtDetail(_ debt: PreviewDebt) -> String {
    var detail = "\(debt.kind.title) · \(debt.personName)"
    if debt.createsDebt { detail += " (new debt in \(debt.currency.rawValue))" }
    if let ruleID = debt.ruleID, let rule = preview.context.rules.first(where: { $0.id == ruleID }) {
      detail += " · by rule “\(rule.label)”"
    }
    return detail
  }

  /// R-DEBT-12: kinds of rule-made debt rows from the running balance of their debt (rows in
  /// date order, this import's earlier debt rows included), so "lent, then repaid" in one file
  /// gives I lent and They repaid.
  private mutating func assignRuleDebtKinds() {
    let order = plans.indices.filter { rows[$0].debt != nil }.sorted { (rows[$0].day, $0) < (rows[$1].day, $1) }
    var running: [String: Int64] = [:]
    for i in order {
      guard var debt = rows[i].debt else { continue }
      let id = debt.debtID ?? preview.context.debts.debt(person: debt.personName)?.id
      let key = ImportPreview.debtKey(person: debt.personName, currency: debt.currency, debtID: id)
      let balance = running[key] ?? id.map { preview.context.debts.balance(of: $0, currency: debt.currency) } ?? 0
      if debt.ruleID != nil {
        debt.kind = .suggested(inflow: rows[i].isInflow, balance: balance)
        debt.countsInReports = false
        rows[i].debt = debt
        rows[i].detail = debtDetail(debt)
        if case .create(var shape) = plans[i] {
          shape.debt = debt
          plans[i] = .create(shape)
        }
      }
      running[key] = balance + debt.kind.balanceSign * (debt.amountMinor ?? 0)
    }
  }

  /// A user pick on a row the file and the rules left without a category becomes a rule.
  private func rulePattern(_ source: NormalizedRow, _ from: CategorySource) -> String? {
    guard from == .user, !decisions.noRule.contains(source.id), source.category == nil,
      case .some(.some) = decisions.categories[source.id]
    else { return nil }
    let accountID: Account.ID? = if case .existing(let id) = preview.accountRef(source.account) { id } else { nil }
    let kind: CategoryKind = source.kind == .income ? .income : .expense
    if matcher.match(description: source.payee, accountID: accountID, kind: kind) != nil { return nil }
    let pattern = RulePattern.derive(from: source.payee)
    return pattern.isEmpty ? nil : pattern
  }

  /// R-IMP-8: proposals from the user's picks, applied at once to the other rows of this
  /// import that have no category.
  private mutating func learnRules() {
    var learned: [(pattern: String, categoryID: AbacusDomain.Category.ID, kind: CategoryKind)] = []
    for row in rows {
      guard let pattern = row.rulePattern, case .existing(let id)? = row.category,
        let category = preview.context.category(id), !learned.contains(where: { $0.pattern == pattern })
      else { continue }
      learned.append((pattern, id, category.kind))
    }
    guard !learned.isEmpty else { return }
    var hits = Dictionary(learned.map { ($0.pattern, 0) }, uniquingKeysWith: { a, _ in a })
    for i in rows.indices {
      if let pattern = rows[i].rulePattern { hits[pattern, default: 0] += 1; continue }
      guard rows[i].categorySource == .none, rows[i].createsTransaction, decisions.categories[rows[i].id] == nil,
        rows[i].review == nil, case .create(var shape) = plans[i]
      else { continue }
      let kind: CategoryKind = rows[i].type == .income ? .income : .expense
      let text = RulePattern.normalized(rows[i].source.payee)
      guard let rule = learned.first(where: { $0.kind == kind && text.contains($0.pattern) }) else { continue }
      rows[i].category = .existing(rule.categoryID)
      rows[i].categorySource = .learnedRule(pattern: rule.pattern)
      shape.category = .existing(rule.categoryID)
      plans[i] = .create(shape)
      hits[rule.pattern, default: 0] += 1
    }
    proposals = learned.map { RuleProposal(pattern: $0.pattern, categoryID: $0.categoryID, rowCount: hits[$0.pattern] ?? 1) }
  }

  // MARK: Review

  private func suggestion(_ source: NormalizedRow, _ found: RowAnalysis, _ reason: ReviewReason) -> ReviewChoice {
    let kind: CategoryKind = source.flow == .in ? .income : .expense
    if case .unpairedTransferHalf = reason {
      if let first = found.pairRows.first, let other = parsed.first(where: { $0.id == first }),
        other.transferHalf?.transit == source.transferHalf?.transit
      {
        return .pair(rowID: first)
      }
      if let existing = found.pairExisting.first { return .pairExisting(existing.id) }
    }
    return .record(kind, categoryID: nil)
  }

  private mutating func review(_ i: Int, _ base: PreviewRow, _ reason: ReviewReason) -> (PreviewRow, RowPlan) {
    let source = parsed[i]
    let found = analysis[i]
    var row = base
    row.status = .needsReview
    let choice = decisions.reviews[source.id]
    row.review = ReviewInfo(
      reason: reason, pairRows: found.pairRows, pairExisting: found.pairExisting,
      suggested: suggestion(source, found, reason), choice: choice)
    switch reason {
    case .unpairedTransferHalf(let direction):
      row.detail = direction == .outgoing
        ? "Outgoing transfer half without a matching incoming half"
        : "Incoming transfer half without a matching outgoing half"
    case .unknownOperationType: row.detail = "Unknown operation type — check the sign"
    case .transferAmountUnknown: row.detail = "Transfer to an own account in another currency; the received amount is unknown"
    }
    guard let choice else { return (row, .nothing) }

    let account = preview.accountRef(source.account)
    let flow = source.flow ?? .out
    var shape = TxnShape(
      type: .expense, from: account, amountMinor: source.amountMinor, lines: source.lines,
      occurredAt: source.occurredAt, payee: source.payee, note: source.note, original: source.original,
      isPending: source.isPending, bookedDay: bookedDay(source), fingerprints: source.fingerprints)

    switch choice {
    case .skip:
      return (row, .nothing)

    case .record(let kind, let categoryID):
      shape.type = kind == .income ? .income : .expense
      // Keep the money's direction: income for money out is a reversal, expense for money in a refund.
      shape.isRefund = (kind == .income) != (flow == .in)
      if let transit = source.transferHalf?.transit, transit.currencyCode != preview.currency(of: account)?.rawValue {
        shape.original = transit
      }
      var (category, from, _) = resolveCategory(for: source, kind: kind, account: account, explicit: .some(categoryID))
      if decisions.defaultHalves.contains(source.id) {
        category = preview.categoryRef(ExternalCategory(name: ImportPreview.uncategorisedName, kind: kind))
        from = .user
        shape.note = [shape.note, ImportPreview.unpairedHalfNote].filter { !$0.isEmpty }.joined(separator: "\n")
      }
      shape.category = category
      row.type = shape.type
      row.category = category
      row.categorySource = from
      row.createsTransaction = true
      return (row, .create(shape))

    case .debt(let choice):
      shape.type = flow == .in ? .income : .expense
      shape.isRefund = false
      if let transit = source.transferHalf?.transit, transit.currencyCode != preview.currency(of: account)?.rawValue {
        shape.original = transit
      }
      applyDebt(choice, ruleID: nil, source: source, shape: &shape, row: &row)
      row.createsTransaction = true
      return (row, .create(shape))

    case .transfer(let accountID):
      guard let other = preview.context.account(accountID), account != .existing(accountID) else {
        issues.append("“\(source.payee)”: choose another account for the transfer")
        return (row, .nothing)
      }
      let otherAmount = amount(of: source, in: other.currency, accountCurrency: preview.currency(of: account))
      guard let otherAmount else {
        issues.append("“\(source.payee)”: the amount in \(other.currency.rawValue) is unknown; record it instead")
        return (row, .nothing)
      }
      shape.type = .transfer
      shape.original = nil
      if flow == .out {
        shape.to = .existing(accountID)
        shape.toAmountMinor = otherAmount
      } else {
        shape.from = .existing(accountID)
        shape.to = account
        shape.amountMinor = otherAmount
        shape.toAmountMinor = source.amountMinor
        shape.lines = []
      }
      row.type = .transfer
      row.counterAccount = .existing(accountID)
      row.counterAmountMinor = otherAmount
      row.createsTransaction = true
      return (row, .create(shape))

    case .pair(let otherID):
      guard let j = parsed.firstIndex(where: { $0.id == otherID }), decisions.reviews[otherID] == .pair(rowID: source.id),
        let mine = source.transferHalf, let theirs = parsed[j].transferHalf, mine.direction != theirs.direction,
        parsed[j].account.key != source.account.key
      else {
        issues.append("“\(source.payee)”: the chosen half cannot be paired with it")
        return (row, .nothing)
      }
      let other = parsed[j]
      row.type = .transfer
      row.counterAccount = preview.accountRef(other.account)
      row.counterAmountMinor = other.amountMinor
      guard mine.direction == .outgoing else {
        // The outgoing half carries the transfer.
        return (row, .nothing)
      }
      shape.type = .transfer
      shape.to = preview.accountRef(other.account)
      shape.toAmountMinor = other.amountMinor
      shape.original = nil
      shape.fingerprints = source.fingerprints + other.fingerprints
      if shape.payee.isEmpty { shape.payee = other.payee }
      if !other.note.isEmpty, other.note != shape.note {
        shape.note = [shape.note, other.note].filter { !$0.isEmpty }.joined(separator: "\n")
      }
      shape.tag = source.tag ?? other.tag
      row.createsTransaction = true
      return (row, .create(shape))

    case .pairExisting(let txnID):
      guard flow == .in, let existing = found.pairExisting.first(where: { $0.id == txnID }) else {
        issues.append("“\(source.payee)”: the chosen transaction cannot be its other half")
        return (row, .nothing)
      }
      shape.type = .transfer
      shape.from = .existing(existing.accountID)
      shape.to = account
      shape.amountMinor = existing.amountMinor
      shape.toAmountMinor = source.amountMinor
      row.type = .transfer
      row.counterAccount = .existing(existing.accountID)
      row.counterAmountMinor = existing.amountMinor
      return (row, .convert(existing, shape))
    }
  }

  /// The row's amount in `currency`: itself, the in-transit amount or the original amount.
  private func amount(of source: NormalizedRow, in currency: Currency, accountCurrency: Currency?) -> Int64? {
    if currency == accountCurrency { return source.amountMinor }
    if let transit = source.transferHalf?.transit, transit.currencyCode == currency.rawValue { return transit.minorUnits }
    if let original = source.original, original.currencyCode == currency.rawValue { return original.minorUnits }
    return nil
  }

  // MARK: Conflicts

  /// Two rows must not change or link the same existing transaction.
  private mutating func checkConflicts() {
    var seen: [Txn.ID: Int] = [:]
    for plan in plans {
      let id: Txn.ID? = switch plan {
      case .settle(let txn, _), .link(let txn, _), .convert(let txn, _): txn.id
      case .nothing, .openingBalance, .create: nil
      }
      if let id { seen[id, default: 0] += 1 }
    }
    let conflicts = seen.values.filter { $0 > 1 }.count
    if conflicts > 0 {
      issues.append("\(conflicts) existing transaction(s) are chosen for more than one row")
    }
  }
}
