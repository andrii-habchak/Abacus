import AbacusDomain
import AbacusImport
import Foundation

/// C41: checks of the PKO "Import into" account. A statement names no account of its own, so the
/// default is the account the last statement in its currency went into; with more than one
/// account in that currency the default can be wrong, and a file already imported into one
/// account would be imported a second time into another.
extension ImportWizardModel {
  /// Under "Import into": the file's rows already sit in another account, or the remembered
  /// account is one of several in the file's currency. Nil when there is nothing to check.
  public var targetWarning: String? {
    guard let file, file.source == .pko else { return nil }
    var parts: [String] = []
    let elsewhere = targetOverlaps
      .filter { $0.key != targetAccountID }
      .sorted { ($0.value, name(ofAccount: $0.key)) > ($1.value, name(ofAccount: $1.key)) }
    for (id, count) in elsewhere {
      parts.append(
        ImportFormat.count(count, "row") + " of this file " + (count == 1 ? "is" : "are")
          + " already imported into “\(name(ofAccount: id))”. Undo that import in History first, or "
          + (count == 1 ? "it" : "they") + " will be in both accounts.")
    }
    if parts.isEmpty, preview != nil, targetRemembered, targetOptions.count > 1 {
      let currency = file.currency?.rawValue ?? "this currency"
      parts.append(
        "\(targetOptions.count) accounts are in \(currency). The account is remembered per currency; "
          + "check that this statement belongs to it.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// Reads where the open PKO file's rows are already imported, among the accounts it can go into
  /// (and the current target). Called after the file is opened or its target changes.
  func refreshTargetOverlaps() async {
    guard let file, file.source == .pko else {
      targetOverlaps = [:]
      return
    }
    var ids = targetOptions.map(\.id)
    if let targetAccountID, !ids.contains(targetAccountID) { ids.append(targetAccountID) }
    targetOverlaps = (try? await pipeline.alreadyImportedRows(of: file.data, in: ids)) ?? [:]
  }

  /// After an undo from History while a PKO file is under review: when the undone batch went
  /// into the file's account (or one its rows were found in), the preview is built again, so rows
  /// that were "Already imported" show as new and the target can be changed. Choices made in
  /// the review so far are dropped, as with a change of "Import into".
  func reviewAfterUndo(of batch: ImportBatch) async {
    guard let file, file.source == .pko, step == .review else { return }
    let touched = batch.accountID.map { $0 == targetAccountID || targetOverlaps[$0] != nil } ?? false
    if touched, preview != nil, let targetAccountID {
      await buildPreview(file, target: targetAccountID)
    } else {
      await refreshTargetOverlaps()
    }
  }

  private func name(ofAccount id: Account.ID) -> String {
    accounts.first { $0.id == id }?.name ?? "another account"
  }
}
