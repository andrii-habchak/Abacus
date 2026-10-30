import AbacusDomain
import AbacusImport
import Foundation
import Observation

/// The import wizard (approved prototype 5; R-IMP-1…8, R-IMP-SALDO-4, R-IMP-PKO-1/2): choose a
/// file → review the preview (summary cards, transactions, mappings, events from tags, needs
/// review) → commit all or nothing → done, plus the import history with undo.
///
/// Every choice goes through `ImportPreview`'s methods (or `ImportPipeline.remapAccount` for
/// accounts); the display values (`rowItems`, `cards`, `mappingGroups`, `reviewItems`, …) are
/// derived from the preview after each change. Nothing is written before `commit()`.
@MainActor
@Observable
public final class ImportWizardModel {
  public enum Step: Int, CaseIterable, Sendable {
    case chooseFile = 1, review, done

    public var title: String {
      switch self {
      case .chooseFile: "Choose file"
      case .review: "Review"
      case .done: "Done"
      }
    }
  }

  public enum Tab: Hashable, Sendable {
    case transactions, mapping, events, review
  }

  /// C36: the sub-filters of the Needs review tab.
  public enum ReviewFilter: Hashable, Sendable {
    /// Decisions and categories together (the default).
    case all
    /// Rows the importer could not place (the review cards).
    case decisions
    /// Rows that still need a category.
    case categories
  }

  /// What the model is busy with; the views disable their controls meanwhile.
  public enum Activity: Equatable, Sendable {
    case idle, reading, previewing, committing, undoing
  }

  /// The file being imported.
  public struct LoadedFile: Equatable, Sendable {
    public var name: String
    public var data: Data
    public var source: ImportSource
    /// PKO: the statement's currency (R-IMP-PKO-1).
    public var currency: Currency?
  }

  // MARK: State

  public private(set) var step: Step = .chooseFile
  public private(set) var file: LoadedFile?
  public private(set) var preview: ImportPreview?
  /// PKO: the account the statement goes into; nil until chosen when nothing is remembered.
  public private(set) var targetAccountID: Account.ID?
  public private(set) var accounts: [Account] = []
  /// Account groups: account pickers list A–Z under them (R-MGMT-8).
  public private(set) var accountGroups: [AccountGroup] = []
  public private(set) var categories: [AbacusDomain.Category] = []
  public var tab: Tab = .transactions {
    didSet { if tab != oldValue { clearSelection() } }
  }
  /// C36: what the Needs review tab lists; changing it clears the selection.
  public var reviewFilter: ReviewFilter = .all {
    didSet { if reviewFilter != oldValue { clearSelection() } }
  }
  /// The pressed summary card; nil = all rows.
  public private(set) var filter: RowStatus? {
    didSet { if filter != oldValue { clearSelection() } }
  }
  /// C31: the rows selected in the list (row ids); bulk actions work on them.
  public internal(set) var selection: Set<String> = []
  @ObservationIgnored var selectionAnchor: String?
  /// C31: the "Save rules" sheet after a bulk category; nil when closed.
  public var ruleSheet: RuleSuggestionSheet?
  /// C31: the "New category" sheet; nil when closed.
  public var newCategoryDraft: NewCategoryDraft?
  /// C35: the "This is a refund of…" search of a row; nil when closed.
  public var refundPicker: ImportRefundPicker?
  /// C38: the "Find the other side…" sheet of a row's transfer; nil when closed.
  public var counterpartPicker: ImportCounterpartPicker?
  /// C31: what the last bulk action did ("Category set on 12 rows"), shown in the bulk bar.
  public internal(set) var bulkMessage: String?
  /// C31: the state before the last bulk action (undo of one step).
  @ObservationIgnored var bulkUndo: (preview: ImportPreview, noRuleRows: Set<String>)?
  public var canUndoBulk: Bool { bulkUndo != nil }
  /// C31: the rows a "Transfer to debt account" sheet opened from the bulk bar records.
  public internal(set) var debtBulkRowIDs: [String] = []
  public private(set) var activity: Activity = .idle
  /// Shown as an alert; the view clears it.
  public var errorMessage: String?
  public private(set) var summary: ImportSummary?
  public private(set) var history: [ImportBatch] = []
  public var isHistoryShown = false
  /// The batch waiting for the "Undo import?" confirmation.
  public private(set) var pendingUndo: ImportBatch?
  /// Rows whose category pick is not saved as a rule (`ImportPreview.setSavesRule`).
  public internal(set) var noRuleRows: Set<String> = []
  /// Display values, rebuilt after every change of the preview.
  public private(set) var rowItems: [ImportRowItem] = []
  public private(set) var reviewItems: [ImportReviewItem] = []
  /// The "Transfer to debt account" sheet of a row (R-DEBT-10); nil when closed.
  public var debtDraft: DebtLinkDraft?
  /// The row the sheet records.
  public private(set) var debtDraftRowID: String?

  /// Called after a commit or an undo changed the database (other screens reload).
  @ObservationIgnored public var onDataChanged: (() -> Void)?

  @ObservationIgnored let dependencies: ImportWizardDependencies
  @ObservationIgnored let format: ImportFormat

  public init(dependencies: ImportWizardDependencies) {
    self.dependencies = dependencies
    format = ImportFormat(calendar: dependencies.calendar)
  }

  var pipeline: ImportPipeline { dependencies.pipeline }

  public var isBusy: Bool { activity != .idle }

  // MARK: Loading

  /// Loads the history and the accounts and categories the pickers offer.
  public func load() async {
    await reloadReference()
    await reloadHistory()
  }

  func reloadReference() async {
    do {
      accounts = try await pipeline.accounts.accounts(includeArchived: true)
      accountGroups = (try? await pipeline.accounts.groups()) ?? []
      categories = try await pipeline.categories.categories(kind: nil, includeArchived: true)
      // The open preview knows the categories too (names, rules learned from a pick); rebuild
      // the pickers so a category created meanwhile can be chosen (C31).
      if var preview {
        preview.refreshCategories(categories)
        setPreview(preview)
      }
    } catch {
      errorMessage = "Couldn't load accounts and categories."
    }
  }

  /// Reads accounts and categories again: called when a category is created elsewhere and when
  /// the window becomes active again, so the row pickers offer what exists now (C31).
  public func refreshReference() async {
    await reloadReference()
  }

  private func reloadHistory() async {
    do {
      history = try await pipeline.history()
    } catch {
      errorMessage = "Couldn't load the import history."
    }
  }

  // MARK: Step 1 — choose a file (R-IMP-1)

  /// Reads a file picked in the open panel or dropped on the window.
  public func open(url: URL) async {
    activity = .reading
    let data: Data
    do {
      data = try dependencies.readFile(url)
    } catch {
      activity = .idle
      errorMessage = "“\(url.lastPathComponent)” couldn't be read."
      return
    }
    activity = .idle
    await open(data: data, fileName: url.lastPathComponent)
  }

  /// Detects the format and builds the preview. A PKO statement goes into the account
  /// remembered for its currency; when there is none, the review step asks for it first.
  public func open(data: Data, fileName: String) async {
    guard let source = ImportPipeline.detect(data) else {
      errorMessage = "“\(fileName)” isn't a Saldo export or a PKO BP statement (“Zestawienie operacji”)."
      return
    }
    await reloadReference()
    let currency = source == .pko ? ImportPipeline.statementCurrency(data) : nil
    var target: Account.ID?
    if source == .pko {
      target = try? await pipeline.rememberedTargetAccount(for: data)
    }
    let loaded = LoadedFile(name: fileName, data: data, source: source, currency: currency)
    if source == .pko, target == nil {
      file = loaded
      targetAccountID = nil
      setPreview(nil)
      resetReviewState()
      step = .review
      return
    }
    // A remembered account is resolved by the pipeline itself, which marks it as remembered.
    await buildPreview(loaded, target: nil)
  }

  /// PKO: imports the statement into another account (R-IMP-PKO-1). The preview is built again,
  /// so choices made so far are dropped.
  public func chooseTargetAccount(_ id: Account.ID) async {
    guard let file, file.source == .pko, id != targetAccountID || preview == nil else { return }
    await buildPreview(file, target: id)
  }

  /// Accounts a PKO statement can go into: active accounts in the statement's currency.
  public var targetOptions: [Account] {
    guard let file, file.source == .pko else { return [] }
    return AccountOrder.alphabetical(
      accounts.filter { !$0.isArchived && (file.currency == nil || $0.currency == file.currency) },
      groups: accountGroups)
  }

  /// `targetOptions` as picker sections: groups A–Z, then the accounts without a group.
  public var targetSections: [AccountPickerSection] {
    AccountOrder.pickerSections(targetOptions, groups: accountGroups)
  }

  /// PKO without a remembered or chosen account: the review step shows only the picker.
  public var needsTargetAccount: Bool { file?.source == .pko && preview == nil }

  private func buildPreview(_ loaded: LoadedFile, target: Account.ID?) async {
    activity = .previewing
    defer { activity = .idle }
    do {
      let built = try await pipeline.preview(data: loaded.data, fileName: loaded.name, targetAccountID: target)
      file = loaded
      targetAccountID = built.targetAccountID
      resetReviewState()
      setPreview(built)
      step = .review
    } catch {
      errorMessage = Self.message(for: error, fileName: loaded.name)
    }
  }

  private func resetReviewState() {
    tab = .transactions
    reviewFilter = .all
    filter = nil
    clearSelection()
    ruleSheet = nil
    newCategoryDraft = nil
    refundPicker = nil
    counterpartPicker = nil
    bulkUndo = nil
    bulkMessage = nil
    noRuleRows = []
    summary = nil
  }

  /// Cancel: back to step 1; nothing was saved.
  public func cancel() {
    file = nil
    targetAccountID = nil
    setPreview(nil)
    resetReviewState()
    step = .chooseFile
  }

  // MARK: Step 2 — review

  /// Summary card: shows rows of `status` (nil = all); the Needs review card opens its tab.
  public func selectFilter(_ status: RowStatus?) {
    filter = status
    tab = status == .needsReview ? .review : .transactions
  }

  public var visibleRows: [ImportRowItem] {
    guard let filter else { return rowItems }
    return rowItems.filter { $0.status == filter }
  }

  /// Category of an expense/income row. Picking the file's own new category returns the row
  /// to its default (file or rule).
  public func setCategory(_ choice: ImportCategoryChoice, forRow id: String) {
    if choice == .createNew {
      beginNewCategory(forRow: id)
      return
    }
    update { preview in
      switch choice {
      case .none: preview.setCategory(nil, forRow: id)
      case .existing(let categoryID): preview.setCategory(categoryID, forRow: id)
      case .new: preview.resetCategory(forRow: id)
      case .createNew: break
      }
    }
  }

  /// Whether the row's pick becomes a categorisation rule (R-IMP-8; default yes).
  public func setSavesRule(_ saves: Bool, forRow id: String) {
    if saves { noRuleRows.remove(id) } else { noRuleRows.insert(id) }
    update { $0.setSavesRule(saves, forRow: id) }
  }

  /// Possible duplicate: Skip (default) / Import anyway / Link to existing (R-IMP-4).
  public func setDuplicateAction(_ action: DuplicateAction, forRow id: String) {
    update { $0.setDuplicateAction(action, forRow: id) }
  }

  /// Saldo tag → event (R-IMP-SALDO-4).
  public func setEvent(tag: String, selected: Bool) {
    update { $0.setEvent(tag: tag, selected: selected) }
  }

  /// Source category → existing category or a new one (R-IMP-2).
  public func mapCategory(key: String, to choice: ImportMappingChoice) {
    let target: CategoryMapping.Target = switch choice {
    case .create: .create
    case .existing(let id): .existing(id)
    }
    update { preview in
      do {
        try preview.mapCategory(key: key, to: target)
      } catch {
        errorMessage = "That category can't be used for this one."
      }
    }
  }

  /// Source account → existing account or a new one (R-IMP-2). Dedupe depends on the account,
  /// so the pipeline redoes the matching; other choices are kept.
  public func mapAccount(key: String, to choice: ImportMappingChoice) async {
    guard let preview else { return }
    let target: AccountMapping.Target = switch choice {
    case .create: .create
    case .existing(let id): .existing(id)
    }
    activity = .previewing
    defer { activity = .idle }
    do {
      setPreview(try await pipeline.remapAccount(preview, key: key, to: target))
    } catch ImportPipelineError.currencyMismatch {
      errorMessage = "Only an account in the same currency can be used."
    } catch {
      errorMessage = Self.message(for: error, fileName: file?.name ?? "")
    }
  }

  // MARK: Needs review (R-IMP-5)

  /// Applies the importer's suggestion to every review row without a decision.
  public func acceptSuggestions() {
    update { $0.acceptSuggestedReviewChoices() }
  }

  /// Picks a radio option of a review row; the details (pair candidate, category, account)
  /// keep their current value or start with the first candidate.
  public func selectReviewOption(_ option: ImportReviewOption, forRow id: String) {
    guard let item = reviewItems.first(where: { $0.id == id }) else { return }
    let choice: ReviewChoice?
    switch option {
    case .pair:
      if let current = item.selectedPair { choice = current } else { choice = item.pairCandidates.first?.choice }
    case .record(let kind):
      choice = .record(kind, categoryID: item.recordKind == kind ? item.selectedCategory : nil)
    case .transfer:
      guard let accountID = item.selectedTransferAccount ?? item.transferAccounts.first?.id else { return }
      // C38: another currency and no amount in the file: the other side comes from the sheet.
      if needsCounterpart(forRow: id, to: accountID) {
        beginCounterpart(forRow: id, to: accountID)
        return
      }
      choice = .transfer(accountID: accountID)
    case .debt:
      // The sheet decides (`openDebt(forRow:)`); a debt already chosen stays.
      return
    case .skip:
      choice = .skip
    }
    guard let choice else { return }
    update { $0.setReviewChoice(choice, forRow: id) }
  }

  /// "Pair with" candidate of a review row.
  public func selectPairCandidate(_ choice: ReviewChoice, forRow id: String) {
    update { $0.setReviewChoice(choice, forRow: id) }
  }

  /// Category of a review row recorded as expense or income.
  public func selectReviewCategory(_ categoryID: AbacusDomain.Category.ID?, forRow id: String) {
    guard let kind = reviewItems.first(where: { $0.id == id })?.recordKind else { return }
    update { $0.setReviewChoice(.record(kind, categoryID: categoryID), forRow: id) }
  }

  /// The other own account of a review row recorded as a transfer.
  public func selectTransferAccount(_ accountID: Account.ID, forRow id: String) {
    if needsCounterpart(forRow: id, to: accountID) {
      beginCounterpart(forRow: id, to: accountID)
      return
    }
    update { $0.setReviewChoice(.transfer(accountID: accountID), forRow: id) }
  }

  // MARK: Transfer to a debt account (R-DEBT-10, R-DEBT-19, docs/status/C22.md)

  /// Opens the debt sheet for a row (a new expense/income or a Needs review row), starting from
  /// its current choice or the person's debt and virtual account in the account's currency.
  public func openDebt(forRow id: String, bulkRows: [String] = []) async {
    guard let preview, let row = preview.row(id), row.canRecordDebt,
      let currency = preview.accountCurrency(ofRow: id)
    else { return }
    var converted: [Currency: Int64] = [:]
    if let converter = await pipeline.converter() {
      let day = Day(row.day, calendar: format.calendar)
      for other in Currency.allCases where other != currency {
        if let original = row.source.original, original.currencyCode == other.rawValue {
          converted[other] = original.minorUnits
        } else if let money = converter.convert(Money(minorUnits: row.amountMinor, currency: currency), to: other, on: day) {
          converted[other] = money.minorUnits
        }
      }
    } else if let original = row.source.original, let other = Currency(rawValue: original.currencyCode) {
      converted[other] = original.minorUnits
    }
    let book = preview.debtBook
    let existing = row.debt
    var account: DebtLinkDraft.AccountOption?
    if let existing {
      if let id = existing.accountID {
        account = .existing(id)
      } else if let debtID = existing.debtID,
        let virtual = DebtLinkDraft.virtualAccount(in: book, debtID: debtID, currency: existing.currency)
      {
        account = .existing(virtual.id)
      } else {
        account = .newVirtual
      }
    }
    debtDraftRowID = id
    debtBulkRowIDs = bulkRows
    let bulk = bulkRows.count > 1
    debtDraft = DebtLinkDraft(
      title: bulk
        ? "Transfer \(bulkRows.count.formatted()) payments to a debt account"
        : row.source.payee.isEmpty ? "Transfer to debt account" : "Transfer “\(row.source.payee)” to a debt account",
      subtitle: (bulk ? "Amounts shown are of the first row · " : "") + "\(format.amount(row.amountMinor, currency.rawValue, inflow: row.isInflow)) on \(preview.name(of: row.account)) · \(format.day(row.day))",
      inflow: row.isInflow, accountCurrency: currency, accountAmountMinor: row.amountMinor, book: book,
      convertedAmounts: converted, personName: existing?.personName ?? "", account: account,
      newAccountCurrency: existing?.currency,
      amountMinor: existing.flatMap { $0.currency == currency ? nil : $0.amountMinor })
  }

  public func cancelDebt() {
    debtDraft = nil
    debtDraftRowID = nil
    debtBulkRowIDs = []
  }

  /// Saves the sheet: the row becomes a transfer to the person's account on commit (Needs review rows: their
  /// decision). Takes the draft the sheet showed (SwiftUI may clear the binding first).
  public func saveDebt(_ draft: DebtLinkDraft? = nil) {
    guard let draft = draft ?? debtDraft, let id = debtDraftRowID, let link = draft.link else { return }
    debtDraft = nil
    debtDraftRowID = nil
    let bulkIDs = debtBulkRowIDs
    debtBulkRowIDs = []
    if bulkIDs.count > 1 {
      applyBulkDebt(link: link, personCurrency: draft.personCurrency, baseRow: id, rows: bulkIDs)
      return
    }
    let choice = ImportDebtChoice(
      personName: link.personName, debtID: link.debtID, accountID: link.accountID,
      currency: link.currency ?? draft.personCurrency, amountMinor: link.amountMinor)
    let isReview = preview?.row(id)?.review != nil
    update { preview in
      if isReview {
        preview.setReviewChoice(.debt(choice), forRow: id)
      } else {
        preview.setDebt(choice, forRow: id)
      }
    }
  }

  /// "Not a debt": back to an ordinary row (also against a "Transfer to debt" rule); a
  /// Needs review row loses its decision.
  public func removeDebt(forRow id: String) {
    let isReview = preview?.row(id)?.review != nil
    update { preview in
      if isReview {
        preview.setReviewChoice(nil, forRow: id)
      } else {
        preview.setDebt(nil, forRow: id)
      }
    }
  }

  // MARK: Commit (R-IMP-6)

  /// Writes the preview in one database transaction. On failure nothing is saved and the
  /// review stays as it was.
  public func commit() async {
    guard let preview, canCommit else { return }
    activity = .committing
    defer { activity = .idle }
    do {
      summary = try await pipeline.commit(preview)
      step = .done
      onDataChanged?()
    } catch {
      errorMessage = Self.message(for: error, fileName: file?.name ?? "")
    }
    await reloadHistory()
  }

  // MARK: History and undo (R-IMP-6, D28)

  public func toggleHistory() {
    isHistoryShown.toggle()
  }

  /// Asks for the confirmation of undoing `batch`.
  public func requestUndo(_ batch: ImportBatch) {
    guard !batch.isUndone else { return }
    pendingUndo = batch
  }

  /// Undo of the import the done screen shows.
  public func requestUndoOfLastImport() {
    guard let batch = summary?.batch else { return }
    pendingUndo = history.first { $0.id == batch.id } ?? batch
  }

  public func cancelUndo() {
    pendingUndo = nil
  }

  /// Removes the batch's transactions (and the accounts, categories and events it created
  /// that nothing else uses, D28). From the done screen it returns to step 1 with the history
  /// open, where the batch shows as undone.
  public func confirmUndo() async {
    guard let batch = pendingUndo else { return }
    pendingUndo = nil
    activity = .undoing
    defer { activity = .idle }
    do {
      try await pipeline.undo(batch.id)
      onDataChanged?()
      if summary?.batch.id == batch.id {
        cancel()
        isHistoryShown = true
      }
    } catch {
      errorMessage = "The import couldn't be undone; nothing was changed. \(error.localizedDescription)"
    }
    await reloadHistory()
  }

  public var undoConfirmationTitle: String {
    "Undo the import of “\(pendingUndo?.fileName ?? "")”?"
  }

  public var undoConfirmationMessage: String {
    "Its transactions are removed, together with the accounts, categories and events it created "
      + "that nothing else uses. Pending payments it settled and transactions it linked stay as they are."
  }

  // MARK: Updating

  func update(keepBulk: Bool = false, _ change: (inout ImportPreview) -> Void) {
    guard var preview else { return }
    if !keepBulk {
      bulkUndo = nil
      bulkMessage = nil
    }
    change(&preview)
    setPreview(preview)
  }

  func setPreview(_ preview: ImportPreview?) {
    self.preview = preview
    rowItems = preview.map { makeRowItems($0) } ?? []
    reviewItems = preview.map { makeReviewItems($0) } ?? []
    if let filter, let preview, preview.counts[filter] == 0 { self.filter = nil }
    pruneSelection()
  }

  static func message(for error: any Error, fileName: String) -> String {
    switch error {
    case ImportPipelineError.unrecognisedFormat:
      return "“\(fileName)” isn't a Saldo export or a PKO BP statement (“Zestawienie operacji”)."
    case ImportPipelineError.targetAccountRequired:
      return "Choose the account this statement belongs to."
    case ImportPipelineError.unknownAccount:
      return "The chosen account no longer exists."
    case ImportPipelineError.currencyMismatch:
      return "Only an account in the same currency can be used."
    case ImportPipelineError.notReady(let problems):
      return "Nothing was imported. " + problems.joined(separator: "; ") + "."
    case ImportError.unreadableEncoding:
      return "“\(fileName)” couldn't be decoded."
    case ImportError.malformed(let line, let reason):
      return "“\(fileName)” couldn't be read: line \(line), \(reason)"
    default:
      return "Nothing was saved: \(error.localizedDescription)"
    }
  }
}
