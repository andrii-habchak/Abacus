import AbacusDomain
import Foundation

/// The import pipeline (D12, R-IMP-1…8): detect → parse → map → dedupe → preview → commit.
///
/// Works only against the repository protocols, so tests use fakes and the app the SQLite store.
public struct ImportPipeline: Sendable {
  public let store: any ImportStore
  public let accounts: any AccountRepository
  public let categories: any CategoryRepository
  public let events: any EventRepository
  public let rules: any RuleRepository
  /// Days, Saldo's zone-less times and dedupe windows are read in this calendar.
  public let calendar: Calendar
  public let now: @Sendable () -> Date
  /// Day rates for debt records in another currency than the row's account (R-DEBT-10); nil =
  /// none (the amount must then be entered).
  public let converter: @Sendable () async -> (any CurrencyConverter)?
  /// Finds the expense an incoming row may be the refund of (C35); nil = no suggestions among
  /// existing expenses (rows of the file are still matched with each other).
  public let refunds: (any RefundRepository)?
  /// Finds the other side of a transfer to an own account in another currency and the estimated
  /// transfers a later row completes (C38); nil = no search and no such offers.
  public let counterparts: (any TransferCounterpartRepository)?

  public init(
    store: any ImportStore, accounts: any AccountRepository, categories: any CategoryRepository,
    events: any EventRepository, rules: any RuleRepository, calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { Date() },
    converter: @escaping @Sendable () async -> (any CurrencyConverter)? = { nil },
    refunds: (any RefundRepository)? = nil, counterparts: (any TransferCounterpartRepository)? = nil
  ) {
    self.refunds = refunds
    self.counterparts = counterparts
    self.converter = converter
    self.store = store
    self.accounts = accounts
    self.categories = categories
    self.events = events
    self.rules = rules
    self.calendar = calendar
    self.now = now
  }

  // MARK: - Detection (R-IMP-1)

  /// The file's format, from its first bytes.
  public static func detect(_ data: Data) -> ImportSource? {
    if SaldoParser.canParse(data) { return .saldo }
    if PKOParser.canParse(data) { return .pko }
    return nil
  }

  /// The currency column of a PKO statement's first row.
  public static func statementCurrency(_ data: Data) -> Currency? {
    guard let text = PKOText.decode(data) else { return nil }
    return PKOText.records(text).dropFirst().lazy
      .compactMap { $0.fields.count > 4 ? Currency(rawValue: $0.fields[4].pkoTrimmed) : nil }
      .first
  }

  static func statementKey(_ currency: Currency?) -> String {
    "statement|\(currency?.rawValue ?? "")"
  }

  /// The account the last PKO statement in this currency went into (R-IMP-PKO-1), if it still
  /// exists.
  public func rememberedTargetAccount(for data: Data) async throws -> Account.ID? {
    let key = Self.statementKey(Self.statementCurrency(data))
    guard let mapping = try await store.mappings(source: .pko).first(where: { $0.kind == .account && $0.externalKey == key })
    else { return nil }
    return try await accounts.accounts(includeArchived: true).contains { $0.id == mapping.targetID } ? mapping.targetID : nil
  }

  // MARK: - Preview

  /// Parses `data` and builds the preview. PKO statements need `targetAccountID`, or a
  /// remembered one (throws `targetAccountRequired`).
  public func preview(data: Data, fileName: String, targetAccountID: Account.ID? = nil) async throws -> ImportPreview {
    guard let source = Self.detect(data) else { throw ImportPipelineError.unrecognisedFormat }
    var context = try await loadContext(source)

    var target: Account?
    var remembered = false
    let parsed: ParsedImport
    switch source {
    case .saldo:
      parsed = try SaldoParser(timeZone: calendar.timeZone).parse(data)
    case .pko:
      var id = targetAccountID
      if id == nil {
        id = try await rememberedTargetAccount(for: data)
        remembered = id != nil
      }
      guard let id else { throw ImportPipelineError.targetAccountRequired(currency: Self.statementCurrency(data)) }
      guard let account = context.account(id) else { throw ImportPipelineError.unknownAccount }
      target = account
      parsed = try PKOParser(account: account, calendar: calendar).parse(data)
    }
    context.mappings = context.mappings.filter { $0.source == source }

    let accountMappings = MappingResolver.accounts(rows: parsed.rows, source: source, context: context)
    let categoryMappings = MappingResolver.categories(rows: parsed.rows, context: context)
    let analysis = try await analyze(parsed.rows, source: source, context: context, mappings: accountMappings, target: target?.id)
    var built = ImportPreview(
      batchID: UUID(), parsed: parsed, fileName: fileName, targetAccountID: target?.id,
      targetRemembered: remembered, context: context, calendar: calendar, analysis: analysis,
      accountMappings: accountMappings, categoryMappings: categoryMappings, converter: await converter())
    await suggestRefunds(&built)
    await suggestEstimateMatches(&built)
    return built
  }

  /// Same as `preview(data:fileName:targetAccountID:)`; for headless imports (command-line
  /// tool) together with `ImportPreview.acceptingDefaults()` and `commit(_:)`.
  public func preview(data: Data, fileName: String, pkoAccountID: Account.ID?) async throws -> ImportPreview {
    try await preview(data: data, fileName: fileName, targetAccountID: pkoAccountID)
  }

  /// Maps a source account to an existing account (same currency) or to a new one, and redoes
  /// the store-dependent matching with the new mapping. Other choices are kept.
  public func remapAccount(_ preview: ImportPreview, key: String, to target: AccountMapping.Target) async throws -> ImportPreview {
    guard let mapping = preview.defaultAccountMappings.first(where: { $0.id == key }) else {
      throw ImportPipelineError.unknownAccount
    }
    if case .existing(let id) = target {
      guard let account = preview.context.account(id) else { throw ImportPipelineError.unknownAccount }
      guard account.currency == mapping.external.currency else { throw ImportPipelineError.currencyMismatch }
    }
    var updated = preview
    updated.decisions.accountTargets[key] = target
    updated.recompute()
    updated.analysis = try await analyze(
      preview.parsedRows, source: preview.source, context: preview.context, mappings: updated.accountMappings,
      target: preview.targetAccountID)
    updated.recompute()
    await suggestRefunds(&updated)
    await suggestEstimateMatches(&updated)
    return updated
  }

  // MARK: - Refunds (C35)

  /// Looks for the existing expense each incoming row may be the refund of and stores the
  /// confident ones (same amount, same description: C30's score of 70) in the preview. Read-only;
  /// a failing search just leaves the row without a suggestion.
  private func suggestRefunds(_ preview: inout ImportPreview) async {
    guard let refunds else { return }
    var found: [String: ImportRefundOriginal] = [:]
    for (rowID, probe) in preview.refundProbes {
      guard let currency = preview.accountCurrency(ofRow: rowID),
        let candidates = try? await refunds.refundCandidates(probe: probe, matching: "", limit: 3),
        let top = candidates.first, top.isSameAmount, top.score >= ImportPreview.refundSuggestionScore,
        top.currency == currency
      else { continue }
      found[rowID] = Self.original(top)
    }
    preview.setExistingRefundSuggestions(found)
  }

  static func original(_ candidate: RefundCandidate) -> ImportRefundOriginal {
    ImportRefundOriginal(
      ref: .existing(candidate.txn.id), payee: candidate.txn.payee, occurredAt: candidate.txn.occurredAt,
      amountMinor: candidate.txn.amountMinor, currency: candidate.currency, remainingMinor: candidate.remainingMinor,
      categoryID: candidate.txn.categoryID, score: candidate.score, isSameAmount: candidate.isSameAmount)
  }

  /// The expenses row `rowID` may be the refund of, best first, for "Choose another…": existing
  /// ones in the row account's currency and the expenses of the file. A non-empty `search`
  /// filters by description or note and drops the 60-day window.
  public func refundOptions(
    for preview: ImportPreview, row rowID: String, matching search: String = "", limit: Int = 30
  ) async throws -> [ImportRefundOriginal] {
    var options = preview.fileRefundOptions(forRow: rowID, matching: search, limit: limit)
    if let refunds, let probe = preview.refundProbe(forRow: rowID), let currency = preview.accountCurrency(ofRow: rowID) {
      let candidates = try await refunds.refundCandidates(probe: probe, matching: search, limit: limit)
      options += candidates.filter { $0.currency == currency }.map(Self.original)
    }
    return Array(options.sorted { ($0.score, $0.occurredAt) > ($1.score, $1.occurredAt) }.prefix(max(0, limit)))
  }

  private func loadContext(_ source: ImportSource) async throws -> ImportContext {
    async let accounts = accounts.accounts(includeArchived: true)
    async let categories = categories.categories(kind: nil, includeArchived: true)
    async let events = events.events(includeArchived: true)
    async let rules = rules.rules()
    async let mappings = store.mappings(source: source)
    async let debts = store.debtBook()
    return try await ImportContext(
      accounts: accounts, categories: categories, events: events, rules: rules, mappings: mappings, debts: debts)
  }

  private func analyze(
    _ rows: [NormalizedRow], source: ImportSource, context: ImportContext, mappings: [AccountMapping],
    target: Account.ID?
  ) async throws -> [RowAnalysis] {
    var refs: [String: AccountRef] = [:]
    for mapping in mappings {
      switch mapping.target {
      case .existing(let id): refs[mapping.id] = .existing(id)
      case .create: refs[mapping.id] = .new(key: mapping.id)
      }
    }
    return try await RowAnalyzer(
      rows: rows, source: source, context: context, accountRefs: refs, targetAccountID: target, store: store,
      calendar: calendar
    ).run()
  }

  // MARK: - Commit, undo, history (R-IMP-6)

  /// Writes the preview in one database transaction (all or nothing) and returns the summary
  /// for the done screen. Refuses while review rows have no choice or `issues` is not empty.
  @discardableResult
  public func commit(_ preview: ImportPreview) async throws -> ImportSummary {
    guard preview.canCommit else {
      var problems = preview.issues
      if preview.unresolvedReviewCount > 0 {
        problems.insert("\(preview.unresolvedReviewCount) row(s) in Needs review have no decision", at: 0)
      }
      throw ImportPipelineError.notReady(problems)
    }
    let built = CommitBuilder(preview: preview, calendar: calendar, now: now()).build()
    try await store.commit(built.commit)
    return built.summary
  }

  public func undo(_ batchID: ImportBatch.ID) async throws {
    try await store.undo(batchID)
  }

  /// Import history, newest first.
  public func history() async throws -> [ImportBatch] {
    try await store.batches()
  }
}
