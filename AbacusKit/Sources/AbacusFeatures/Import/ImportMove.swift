import AbacusDomain
import AbacusImport
import Foundation
import Observation

/// C44: "Move to another account" of an import batch (History). Lists the batch's transactions
/// in the review's row list (same columns, header sort and selection), all movable ones selected,
/// with the searchable account picker for the target (accounts in the batch's currency) and a
/// summary of what the move does. `ImportWizardModel.startMove()` runs it.
@MainActor
@Observable
public final class ImportMoveModel: ImportRowSorting, ImportRowSelecting {
  public let plan: ImportMovePlan
  /// The account the rows move to; nil until chosen.
  public var targetAccountID: Account.ID? {
    didSet { if targetAccountID != oldValue { targetChanged() } }
  }
  /// Rows (transaction ids) that move; only movable rows can be selected.
  public internal(set) var selection: Set<String> = []
  @ObservationIgnored var selectionAnchor: String?
  /// The header's sort; nil = by date (the plan's order).
  public internal(set) var rowSort: ImportRowSort?
  /// Shown under the list when the move was refused; cleared by the next change.
  public var errorMessage: String?
  public internal(set) var isMoving = false

  @ObservationIgnored let accounts: [Account]
  @ObservationIgnored let groups: [AccountGroup]
  @ObservationIgnored let format: ImportFormat

  init(plan: ImportMovePlan, accounts: [Account], groups: [AccountGroup], calendar: Calendar) {
    self.plan = plan
    self.accounts = accounts
    self.groups = groups
    format = ImportFormat(calendar: calendar)
    selection = Set(plan.candidates.filter { $0.refusal == nil }.map { $0.id.uuidString })
  }

  // MARK: Accounts

  public var sourceAccount: Account? { accounts.first { $0.id == plan.sourceAccountID } }
  public var currency: Currency? { sourceAccount?.currency }

  /// Accounts the batch can move to: active, not debt accounts, in the batch's currency (its
  /// amounts are in it), the source excluded.
  public var targetSections: [AccountPickerSection] {
    let options = accounts.filter {
      !$0.isArchived && $0.kind != .debt && $0.id != plan.sourceAccountID && $0.currency == currency
    }
    return AccountOrder.pickerSections(options, groups: groups)
  }

  public var targetItems: [AccountPickerItem] { AccountPickerItem.items(from: targetSections) }

  func name(_ id: Account.ID?) -> String {
    guard let id else { return "" }
    return accounts.first { $0.id == id }?.name ?? "another account"
  }

  private func targetChanged() {
    errorMessage = nil
    // A transfer cannot move onto its own other side: it leaves the selection.
    selection = selection.filter { isMovable($0) }
  }

  // MARK: Rows

  func candidate(_ id: String) -> ImportMoveCandidate? {
    plan.candidates.first { $0.id.uuidString == id }
  }

  /// The category column of a row (the transaction's category).
  public func categoryName(ofRow id: String) -> String? { candidate(id)?.categoryName }

  func isMovable(_ id: String) -> Bool {
    guard let candidate = candidate(id) else { return false }
    return candidate.refusal(movingTo: targetAccountID) == nil
  }

  /// The rows in the header's order, as review rows: "Moves" (selected), "Stays" (not selected)
  /// or "Can't move" with the reason.
  public var visibleRows: [ImportRowItem] {
    let rows = plan.candidates
    let sorted = ImportRowSort.sorted(rows, by: rowSort) { sortKey($0, $1) }
    return sorted.map(item)
  }

  public var rowItems: [ImportRowItem] { plan.candidates.map(item) }

  private func item(_ candidate: ImportMoveCandidate) -> ImportRowItem {
    let id = candidate.id.uuidString
    let refusal = candidate.refusal(movingTo: targetAccountID)
    let moves = refusal == nil && selection.contains(id)
    let status: RowStatus = refusal != nil ? .possibleDuplicate : moves ? .new : .skipped
    let label = refusal != nil ? "Can't move" : moves ? "Moves" : "Stays"
    let txn = candidate.txn
    let onSource = txn.accountID == plan.sourceAccountID || txn.toAccountID == plan.sourceAccountID
    var account = onSource ? name(plan.sourceAccountID) : name(txn.accountID)
    if moves, let targetAccountID { account += " → " + name(targetAccountID) }
    var note: ImportNote?
    if let refusal {
      note = ImportNote(text(refusal), .attention)
    } else if !candidate.notes.isEmpty {
      note = ImportNote(candidate.notes.map(text).joined(separator: " "), .info)
    }
    return ImportRowItem(
      id: id, status: status, statusLabel: label, date: format.day(txn.occurredAt), payee: txn.payee,
      detail: detail(candidate), account: account,
      amount: format.amount(amount(txn), (currency ?? .PLN).rawValue, inflow: isInflow(txn)), isInflow: isInflow(txn),
      isDimmed: !moves, category: .none, duplicateAction: nil, note: note, savesRule: nil)
  }

  private func detail(_ candidate: ImportMoveCandidate) -> String {
    let txn = candidate.txn
    var parts: [String] = []
    switch txn.type {
    case .transfer:
      if let other = candidate.otherAccountID {
        parts.append(txn.accountID == plan.sourceAccountID ? "Transfer to \(name(other))" : "Transfer from \(name(other))")
      } else {
        parts.append("Transfer")
      }
    case .expense: parts.append(txn.isRefund ? "Refund" : "Expense")
    case .income: parts.append(txn.isRefund ? "Income reversal" : "Income")
    }
    if !txn.note.isEmpty { parts.append(txn.note) }
    return parts.joined(separator: " · ")
  }

  /// The amount on the source account's side (in the batch's currency).
  private func amount(_ txn: Txn) -> Int64 {
    if txn.type == .transfer, txn.toAccountID == plan.sourceAccountID, txn.accountID != plan.sourceAccountID {
      return txn.toAmountMinor ?? txn.amountMinor
    }
    return txn.amountMinor
  }

  /// Money comes into the source account.
  private func isInflow(_ txn: Txn) -> Bool {
    switch txn.type {
    case .income: !txn.isRefund
    case .expense: txn.isRefund
    case .transfer: txn.toAccountID == plan.sourceAccountID && txn.accountID != plan.sourceAccountID
    }
  }

  func text(_ refusal: ImportMoveRefusal) -> String {
    switch refusal {
    case .notOwn:
      "Existed before this import (linked or settled by it); stays where it is."
    case .notOnSource(let ids):
      "Now on \(ids.map { "“\(name($0))”" }.joined(separator: " and ")), not on “\(name(plan.sourceAccountID))”; changed after the import."
    case .debt:
      "Part of a debt record; change it in Debts."
    case .laterImport(let file):
      "A later import" + (file.map { " (“\($0)”)" } ?? "") + " is linked to it; undo that import first."
    case .transferToTarget:
      "A transfer to or from “\(name(targetAccountID))”; it can't move onto its own other side."
    }
  }

  func text(_ note: ImportMoveNote) -> String {
    switch note {
    case .transfer(let other): "Only the “\(name(plan.sourceAccountID))” side moves; “\(name(other))” stays."
    case .refundLink: "Refund link kept."
    case .pending: "Pending at the bank."
    }
  }

  private func sortKey(_ candidate: ImportMoveCandidate, _ column: ImportSortColumn) -> ImportSortKey {
    let id = candidate.id.uuidString
    let txn = candidate.txn
    switch column {
    case .status:
      let rank = candidate.refusal(movingTo: targetAccountID) != nil ? 2 : selection.contains(id) ? 0 : 1
      return .number(Double(rank), tie: "")
    case .date: return .number(txn.occurredAt.timeIntervalSinceReferenceDate, tie: "")
    case .description: return .text(txn.payee)
    case .account: return .text(name(txn.accountID))
    case .amount: return .number(Double(isInflow(txn) ? amount(txn) : -amount(txn)), tie: "")
    case .category: return .text(candidate.categoryName ?? "")
    }
  }

  // MARK: Sorting and selection (same behaviour as the review list)

  public func toggleSort(_ column: ImportSortColumn) {
    rowSort = ImportRowSort.toggled(rowSort, column)
  }

  public func sortDirection(of column: ImportSortColumn) -> Bool? {
    guard let rowSort, rowSort.column == column else { return nil }
    return rowSort.ascending
  }

  /// Movable rows in the list's order.
  public var selectableIDs: [String] { visibleRows.map(\.id).filter(isMovable) }

  public func select(_ id: String, mode: ImportSelectionMode) {
    errorMessage = nil
    guard isMovable(id) else { return }
    switch mode {
    case .replace:
      selection = [id]
      selectionAnchor = id
    case .toggle:
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      selectionAnchor = id
    case .range:
      let ids = selectableIDs
      guard let end = ids.firstIndex(of: id) else { return }
      let start = selectionAnchor.flatMap { ids.firstIndex(of: $0) } ?? end
      selection = Set(ids[min(start, end)...max(start, end)])
      if selectionAnchor == nil || !ids.contains(selectionAnchor!) { selectionAnchor = id }
    }
  }

  public func selectAll() {
    errorMessage = nil
    selection = Set(selectableIDs)
  }

  public func selectNone() {
    errorMessage = nil
    selection = []
    selectionAnchor = nil
  }

  // MARK: What happens

  /// The transactions that move, in the plan's order.
  public var movingIDs: [Txn.ID] {
    plan.candidates.filter { selection.contains($0.id.uuidString) && $0.refusal(movingTo: targetAccountID) == nil }.map(\.id)
  }

  public var movableCount: Int { plan.candidates.filter { $0.refusal(movingTo: targetAccountID) == nil }.count }

  public var canMove: Bool { targetAccountID != nil && !movingIDs.isEmpty && !isMoving }

  public var moveButtonTitle: String { "Move " + ImportFormat.count(movingIDs.count, "transaction") }

  public var title: String { "Move “\(plan.batch.fileName)” to another account" }

  public var subtitle: String {
    let own = plan.candidates.filter { $0.refusal != .notOwn }.count
    return ImportFormat.count(own, "transaction") + " of this import on “\(name(plan.sourceAccountID))”"
      + (currency.map { " (\($0.rawValue))" } ?? "")
      + ". Only accounts in the same currency are offered: the amounts stay as they are."
  }

  /// What the move does, line by line, for the text above the button.
  public var summaryLines: [String] {
    guard let target = targetAccountID else {
      return ["Choose the account these transactions belong to."]
    }
    let moving = Set(movingIDs)
    var lines: [String] = []
    if moving.isEmpty {
      lines.append("Nothing is selected to move.")
    } else {
      lines.append(
        ImportFormat.count(moving.count, "transaction") + " move from “\(name(plan.sourceAccountID))” to “\(name(target))”. "
          + "Categories, notes, events, attached records and links stay.")
      let net = plan.candidates.filter { moving.contains($0.id) }.reduce(Int64(0)) { sum, candidate in
        sum + (isInflow(candidate.txn) ? amount(candidate.txn) : -amount(candidate.txn))
      }
      if net != 0, let code = currency?.rawValue {
        lines.append(
          "Balance of “\(name(plan.sourceAccountID))” changes by \(format.amount(abs(net), code, inflow: net < 0)), "
            + "of “\(name(target))” by \(format.amount(abs(net), code, inflow: net > 0)).")
      }
    }
    let stays = plan.candidates.count - moving.count
    if stays > 0 {
      lines.append(ImportFormat.count(stays, "row") + " stay" + (stays == 1 ? "s" : "") + " where " + (stays == 1 ? "it is." : "they are."))
    }
    lines.append(
      "A re-import of the same statement into “\(name(target))” finds them as already imported. "
        + "Undo import still removes them; the move can be undone right after.")
    return lines
  }
}

// MARK: - Wizard: History → Move to another account (C44)

/// A button of the "Transactions moved" alert (C45: OK is the default, Undo move the plain one).
public struct ImportNoticeButton: Hashable, Sendable {
  public enum Action: Hashable, Sendable { case dismiss, undoMove }
  public var title: String
  public var action: Action
  /// The blue button that Return presses.
  public var isDefault: Bool
}

extension ImportWizardModel {
  /// The History button and the sheet's name (C45: no ellipsis).
  public static let moveActionTitle = "Move to another account"

  /// The buttons of the "Transactions moved" alert, in order: OK (the default) first, then
  /// Undo move while the move can still be undone.
  public var moveNoticeButtons: [ImportNoticeButton] {
    var buttons = [ImportNoticeButton(title: "OK", action: .dismiss, isDefault: true)]
    if lastMove != nil { buttons.append(ImportNoticeButton(title: "Undo move", action: .undoMove, isDefault: false)) }
    return buttons
  }

  /// Whether History offers "Move to another account" for `batch`: a PKO statement, not undone,
  /// with transactions of its own.
  public func canMove(_ batch: ImportBatch) -> Bool {
    moveUnavailableReason(batch) == nil
  }

  /// Why "Move to another account" is disabled for `batch` (the button's help); nil = enabled.
  public func moveUnavailableReason(_ batch: ImportBatch) -> String? {
    if dependencies.movePlan == nil || dependencies.moveBatch == nil { return "Not available here." }
    if batch.isUndone { return "This import is undone." }
    if batch.source != .pko || batch.accountID == nil {
      return "Only a PKO statement can be moved: a Saldo export spans many accounts."
    }
    if batchCounts[batch.id] == 0 { return "This import has no transactions of its own to move." }
    return nil
  }

  /// Opens the move list for `batch`.
  public func requestMove(_ batch: ImportBatch) async {
    guard canMove(batch), let load = dependencies.movePlan else { return }
    do {
      let plan = try await load(batch.id)
      if accounts.isEmpty { await reloadReference() }
      moveSheet = ImportMoveModel(plan: plan, accounts: accounts, groups: accountGroups, calendar: dependencies.calendar)
    } catch {
      errorMessage = Self.moveMessage(for: error)
    }
  }

  public func cancelMove() {
    moveSheet = nil
  }

  /// The sheet's "Move N transactions" button. Takes the sheet at once (SwiftUI may clear the
  /// binding before the task runs, C41).
  @discardableResult
  public func startMove() -> Task<Void, Never>? {
    guard let sheet = moveSheet, sheet.canMove else { return nil }
    sheet.isMoving = true
    return Task { await confirmMove(sheet) }
  }

  /// Moves the sheet's selected rows to its target in one database transaction. On success the
  /// sheet closes and `moveNotice` says what moved (with Undo move); a refusal stays in the sheet.
  public func confirmMove(_ sheet: ImportMoveModel) async {
    guard let target = sheet.targetAccountID, let move = dependencies.moveBatch else { return }
    let ids = sheet.movingIDs
    sheet.isMoving = true
    activity = .moving
    defer {
      sheet.isMoving = false
      activity = .idle
    }
    do {
      let result = try await move(sheet.plan.batch.id, ids, nil, target)
      if moveSheet === sheet { moveSheet = nil }
      lastMove = result
      moveNotice =
        ImportFormat.count(result.txnIDs.count, "transaction") + " of “\(sheet.plan.batch.fileName)” moved from “\(sheet.name(result.from))” to “\(sheet.name(result.to))”."
      onDataChanged?()
    } catch {
      sheet.errorMessage = Self.moveMessage(for: error)
      return
    }
    await reloadHistory()
    await reviewAfterMove(between: sheet.plan.sourceAccountID, and: target)
  }

  /// The notice's "Undo move": moves the same transactions back. Takes the move at once (the
  /// alert clears the notice when it closes).
  @discardableResult
  public func startUndoLastMove() -> Task<Void, Never>? {
    guard let result = lastMove else { return nil }
    lastMove = nil
    return Task { await undoMove(result) }
  }

  func undoMove(_ result: ImportMoveResult) async {
    guard let move = dependencies.moveBatch else { return }
    activity = .moving
    defer { activity = .idle }
    do {
      try await move(result.batchID, result.txnIDs, result.to, result.from)
      onDataChanged?()
      let file = history.first { $0.id == result.batchID }?.fileName ?? "the import"
      moveNotice = "The move of “\(file)” was undone: " + ImportFormat.count(result.txnIDs.count, "transaction")
        + " " + (result.txnIDs.count == 1 ? "is" : "are") + " back on “\(accountName(result.from))”."
    } catch {
      errorMessage = "The move couldn't be undone; nothing was changed. " + Self.moveMessage(for: error)
    }
    await reloadHistory()
    await reviewAfterMove(between: result.from, and: result.to)
  }

  /// A PKO file under review whose target (or where its rows were found) is one of the two
  /// accounts is built again, so "Already imported" follows the moved rows.
  func reviewAfterMove(between a: Account.ID, and b: Account.ID) async {
    guard let file, file.source == .pko, step == .review else { return }
    let touched = [a, b].contains { $0 == targetAccountID || targetOverlaps[$0] != nil }
    if touched, preview != nil, let targetAccountID {
      await buildPreview(file, target: targetAccountID)
    } else {
      await refreshTargetOverlaps()
    }
  }

  private func accountName(_ id: Account.ID) -> String {
    accounts.first { $0.id == id }?.name ?? "the account"
  }

  static func moveMessage(for error: any Error) -> String {
    switch error {
    case ImportMoveError.notMovable:
      "Only a PKO statement's import that is not undone can be moved."
    case ImportMoveError.invalidTarget:
      "Choose an active account in the same currency (not the one the rows are on)."
    case ImportMoveError.nothingToMove:
      "Select the transactions to move."
    case ImportMoveError.refused(let count):
      "Nothing was moved: " + ImportFormat.count(count, "transaction") + " can no longer move (changed meanwhile). Close and open the list again."
    case ImportMoveError.alreadyInTarget(let count):
      "Nothing was moved: " + ImportFormat.count(count, "row")
        + " of this statement were imported and moved before, so they would be there twice. Undo the other import first."
    default:
      "Nothing was moved: \(error.localizedDescription)"
    }
  }
}
