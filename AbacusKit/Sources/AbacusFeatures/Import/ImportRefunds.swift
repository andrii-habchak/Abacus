import AbacusDomain
import AbacusImport
import Foundation

// C35: an incoming row that looks like the refund of an expense is offered as one in the import
// preview: "Looks like a refund of <payee> · <date> · <amount>" with Accept, Choose another… and
// Not a refund. The rules live in `ImportPreview` (AbacusImport); this file is the display values
// and the wizard's actions, and the picker's candidate source (existing expenses and expenses of
// the same file, through the C30 `RefundPickerModel`).

/// What a row shows about its refund suggestion.
public struct ImportRefundItem: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// "Looks like a refund of …": Accept / Choose another… / Not a refund.
    case offered
    /// Accepted: the row is a refund of this expense (Change… / Not a refund).
    case accepted
    /// "Not a refund" was chosen (Undo).
    case declined
  }

  public var state: State
  /// "Looks like a refund of Shop · 12.10.2026 · zł 45.00", "Refund of Shop · 12.10.2026 · zł 45.00".
  public var text: String
  /// The expense is another row of this file.
  public var isInFile: Bool
}

/// The "Choose another…" sheet of a row.
public struct ImportRefundPicker: Identifiable {
  public let rowID: String
  public let model: RefundPickerModel
  let source: ImportRefundOptions
  public var id: String { rowID }
}

extension ImportWizardModel {
  // MARK: Display

  func refundItem(_ row: PreviewRow) -> ImportRefundItem? {
    guard row.canBeRefund else { return nil }
    if let original = row.refundOf {
      return ImportRefundItem(state: .accepted, text: "Refund of " + describe(original), isInFile: isInFile(original))
    }
    if row.refundDeclined {
      return ImportRefundItem(state: .declined, text: "Not a refund", isInFile: false)
    }
    if let offer = row.refundOffer {
      return ImportRefundItem(
        state: .offered, text: "Looks like a refund of " + describe(offer), isInFile: isInFile(offer))
    }
    return nil
  }

  private func isInFile(_ original: ImportRefundOriginal) -> Bool {
    if case .row = original.ref { return true }
    return false
  }

  /// "Shop · 12.10.2026 · zł 45.00".
  private func describe(_ original: ImportRefundOriginal) -> String {
    let payee = original.payee.isEmpty ? "an expense" : original.payee
    return [payee, format.day(original.occurredAt), format.money.string(minor: original.amountMinor, code: original.currency.rawValue)]
      .joined(separator: " · ")
  }

  // MARK: Actions

  /// "Accept": the row becomes an expense refund of the offered expense, in its category.
  public func acceptRefundOffer(forRow id: String) {
    guard let offer = preview?.row(id)?.refundOffer else { return }
    var accepted = false
    update { accepted = $0.acceptRefund(offer, forRow: id) }
    if !accepted { errorMessage = "That expense can't take this refund any more." }
  }

  /// "Not a refund": an ordinary income row; the suggestion does not come back.
  public func declineRefund(forRow id: String) {
    update { $0.declineRefund(forRow: id) }
  }

  /// Undo of "Not a refund" or of an accepted refund: the suggestion is offered again.
  public func resetRefund(forRow id: String) {
    update { $0.resetRefund(forRow: id) }
  }

  /// "Choose another…": opens the search over the expenses this row may return.
  public func beginRefundPicker(forRow id: String) {
    guard let preview, let row = preview.row(id), row.canBeRefund else { return }
    let probe =
      preview.refundProbe(forRow: id)
      ?? RefundProbe(accountID: UUID(), amountMinor: row.amountMinor, payee: row.source.payee, occurredAt: row.source.occurredAt)
    let source = ImportRefundOptions(pipeline: pipeline, preview: preview, rowID: id)
    let currency = preview.accountCurrency(ofRow: id)?.rawValue ?? row.source.account.currency.rawValue
    let model = RefundPickerModel(
      kind: .chooseOriginal, subjectID: nil, probe: probe, title: "This is a refund of…",
      subtitle: [
        row.source.payee.isEmpty ? "Incoming payment" : row.source.payee,
        format.money.string(minor: row.amountMinor, code: currency), format.day(row.day),
      ].joined(separator: " · "),
      repository: source, accountNames: Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
      calendar: format.calendar)
    refundPicker = ImportRefundPicker(rowID: id, model: model, source: source)
  }

  public func cancelRefundPicker() {
    refundPicker = nil
  }

  /// A pick in the sheet: the row is accepted as a refund of that expense.
  public func chooseRefundOption(_ option: RefundPickerModel.Option) {
    guard let picker = refundPicker else { return }
    guard let original = picker.source.original(for: option.id) else {
      picker.model.errorMessage = "That expense isn't available any more."
      return
    }
    var accepted = false
    update { accepted = $0.acceptRefund(original, forRow: picker.rowID) }
    if accepted {
      refundPicker = nil
    } else {
      picker.model.errorMessage = "Together with the refunds already chosen, that's more than the expense cost."
    }
  }
}

/// The picker's candidate source for an import row: existing expenses (through the pipeline's
/// refund repository) and expenses of the same file, shown as `RefundCandidate`s. An expense of the
/// file gets a made-up transaction id (from its row id) that `original(for:)` maps back.
final class ImportRefundOptions: RefundRepository, @unchecked Sendable {
  private let pipeline: ImportPipeline
  private let preview: ImportPreview
  private let rowID: String
  private let lock = NSLock()
  private var originals: [Txn.ID: ImportRefundOriginal] = [:]

  init(pipeline: ImportPipeline, preview: ImportPreview, rowID: String) {
    self.pipeline = pipeline
    self.preview = preview
    self.rowID = rowID
  }

  func original(for id: Txn.ID) -> ImportRefundOriginal? {
    lock.lock()
    defer { lock.unlock() }
    return originals[id]
  }

  private func remember(_ option: ImportRefundOriginal, as id: Txn.ID) {
    lock.lock()
    defer { lock.unlock() }
    originals[id] = option
  }

  private static func id(ofRow rowID: String) -> Txn.ID {
    let hex = Fingerprint.sha256Hex("c35|" + rowID).prefix(32)
    var text = String(hex)
    for position in [8, 13, 18, 23] { text.insert("-", at: text.index(text.startIndex, offsetBy: position)) }
    return UUID(uuidString: text) ?? UUID()
  }

  func refundCandidates(probe: RefundProbe, matching search: String, limit: Int) async throws -> [RefundCandidate] {
    let options = try await pipeline.refundOptions(for: preview, row: rowID, matching: search, limit: limit)
    var candidates: [RefundCandidate] = []
    for option in options {
      let id: Txn.ID
      switch option.ref {
      case .existing(let existing): id = existing
      case .row(let other): id = Self.id(ofRow: other)
      }
      remember(option, as: id)
      let txn = Txn(
        id: id, type: .expense, occurredAt: option.occurredAt, accountID: probe.accountID, amountMinor: option.amountMinor,
        categoryID: option.categoryID, payee: option.payee, note: "")
      candidates.append(
        RefundCandidate(
          txn: txn, currency: option.currency, refundedMinor: option.amountMinor - option.remainingMinor,
          score: option.score, isSameAmount: option.isSameAmount))
    }
    return candidates
  }

  func refundCandidates(for refund: Txn.ID, matching search: String, limit: Int) async throws -> [RefundCandidate] {
    throw RefundError.notFound
  }

  func linkRefund(_ refund: Txn.ID, to original: Txn.ID) async throws { throw RefundError.notFound }
  func unlinkRefund(_ refund: Txn.ID) async throws { throw RefundError.notFound }
  func refundTargets(for original: Txn.ID, matching search: String, limit: Int) async throws -> [RefundTargetCandidate] { [] }
  func refundLinks(for ids: [Txn.ID]) async throws -> RefundLinkSummary { RefundLinkSummary() }
}
