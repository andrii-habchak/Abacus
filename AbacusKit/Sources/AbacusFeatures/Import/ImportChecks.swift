import AbacusDomain
import AbacusImport
import Foundation

// N6 (R-CLR-8, R-CLR-9): the Needs review sub-tabs "Pending payments" and "Balance gaps", and the
// "Reconcile" offer on the Done step.

public enum ImportStaleChoice: String, Hashable, Sendable, CaseIterable {
  case keep, markSettled, delete, edit

  public var label: String {
    switch self {
    case .keep: "Keep pending"
    case .markSettled: "Mark settled"
    case .delete: "Delete"
    case .edit: "Edit"
    }
  }
}

/// The values of the inline "Edit" of a stale hold.
public struct ImportStaleEditDraft: Hashable, Sendable {
  public var amountText: String
  public var day: Date
  public var stillPending: Bool
}

public struct ImportStaleItem: Identifiable, Hashable, Sendable {
  /// The held transaction's id (string form, so it can sit in the wizard's row selection).
  public var id: String
  public var payee: String
  public var amount: String
  public var valueDay: String
  public var explanation: String
  public var choice: ImportStaleChoice?
  public var draft: ImportStaleEditDraft
  /// What will happen when the import runs.
  public var outcome: String
}

public struct ImportGapRowItem: Identifiable, Hashable, Sendable {
  public var id: String
  public var day: String
  public var payee: String
  public var amount: String
  public var balanceAfter: String
  public var startsFrom: String
  public var isRemoved: Bool
}

public struct ImportGapItem: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var missing: String
  public var before: ImportGapRowItem
  public var after: ImportGapRowItem
  public var advice: String
}

/// The statement's own closing balance, offered to Reconcile after the import (PKO).
public struct ImportReconcileOffer: Hashable, Sendable {
  public var accountID: Account.ID
  public var accountName: String
  public var day: Day
  public var closingMinor: Int64
  public var closingText: String
  public var dayText: String
}

extension ImportWizardModel {
  var staleCurrencyCode: String {
    preview?.targetAccountID.flatMap { id in accounts.first { $0.id == id }?.currency.rawValue } ?? ""
  }

  /// The stale pending holds with their decisions (PKO).
  public var staleItems: [ImportStaleItem] {
    guard let preview else { return [] }
    let code = staleCurrencyCode
    let lastBooked = preview.continuity.endDay.map { format.day($0.date(calendar: format.calendar)) } ?? "the file's last day"
    return preview.staleHolds.map { hold in
      let decision = preview.staleHoldDecision(hold.id)
      let choice: ImportStaleChoice? = switch decision {
      case nil: nil
      case .keep?: .keep
      case .markSettled?: .markSettled
      case .delete?: .delete
      case .edit?: .edit
      }
      let draft = staleEditDrafts[hold.id]
        ?? ImportStaleEditDraft(
          amountText: EditorAmount.text(minor: hold.txn.amountMinor, code: code), day: hold.txn.occurredAt, stillPending: true)
      let outcome: String = switch decision {
      case nil: "Needs a decision"
      case .keep?: "Stays pending and uncleared; asked again at the next import."
      case .markSettled?: "Stops being pending; stays uncleared until a bank row confirms it."
      case .delete?: "Will be deleted when you import (Undo import brings it back)."
      case .edit?: "Will be updated when you import; stays uncleared."
      }
      return ImportStaleItem(
        id: hold.id.uuidString, payee: hold.txn.payee.isEmpty ? "—" : hold.txn.payee,
        amount: format.amount(hold.txn.amountMinor, code, inflow: false), valueDay: format.day(hold.txn.occurredAt),
        explanation:
          "This file is booked up to \(lastBooked), \(hold.daysBehind) days after this hold, and no row of it matches. The bank has probably released it.",
        choice: choice, draft: draft, outcome: outcome)
    }
  }

  public var undecidedStaleCount: Int { preview?.undecidedStaleHolds.count ?? 0 }

  /// The stale holds selected in the list (the wizard's row selection holds their ids).
  public var selectedStaleIDs: [Txn.ID] {
    (preview?.staleHolds ?? []).map(\.id).filter { selection.contains($0.uuidString) }
  }

  /// Decides the given stale holds (a bulk action, or one item); `.edit` uses each draft.
  public func setStale(_ choice: ImportStaleChoice?, ids: [Txn.ID]) {
    guard let preview else { return }
    let code = staleCurrencyCode
    var decisions: [(Txn.ID, StaleHoldDecision?)] = []
    for id in ids {
      guard let hold = preview.staleHolds.first(where: { $0.id == id }) else { continue }
      switch choice {
      case nil: decisions.append((id, nil))
      case .keep?: decisions.append((id, .keep))
      case .markSettled?: decisions.append((id, .markSettled))
      case .delete?: decisions.append((id, .delete))
      case .edit?:
        let draft = staleEditDrafts[id]
          ?? ImportStaleEditDraft(
            amountText: EditorAmount.text(minor: hold.txn.amountMinor, code: code), day: hold.txn.occurredAt, stillPending: true)
        staleEditDrafts[id] = draft
        let minor = EditorAmount.minor(draft.amountText, code: code) ?? hold.txn.amountMinor
        decisions.append(
          (id, .edit(StaleHoldEdit(amountMinor: abs(minor), day: Day(draft.day, calendar: format.calendar), stillPending: draft.stillPending))))
      }
    }
    update(keepBulk: true) { preview in
      for (id, decision) in decisions { preview.setStaleHold(decision, for: [id]) }
    }
  }

  /// The inline edit changed: stored, and applied while "Edit" is the chosen decision.
  public func updateStaleEdit(_ id: Txn.ID, _ change: (inout ImportStaleEditDraft) -> Void) {
    guard let item = staleItems.first(where: { $0.id == id.uuidString }) else { return }
    var draft = item.draft
    change(&draft)
    staleEditDrafts[id] = draft
    if item.choice == .edit { setStale(.edit, ids: [id]) }
  }

  public func keepAllStale() {
    setStale(.keep, ids: (preview?.staleHolds ?? []).map(\.id))
  }

  /// Balance gaps in the file (PKO); warnings only.
  public var gapItems: [ImportGapItem] {
    guard let preview else { return [] }
    let code = staleCurrencyCode
    func item(_ row: GapRow) -> ImportGapRowItem {
      ImportGapRowItem(
        id: row.id, day: format.day(row.bookedDay.date(calendar: format.calendar)), payee: row.payee.isEmpty ? "—" : row.payee,
        amount: format.amount(abs(row.amountMinor), code, inflow: row.amountMinor > 0),
        balanceAfter: format.amount(abs(row.balanceAfterMinor), code, inflow: row.balanceAfterMinor >= 0),
        startsFrom: format.amount(abs(row.startsFromMinor), code, inflow: row.startsFromMinor >= 0),
        isRemoved: preview.isGapRowRemoved(row.id))
    }
    return preview.continuity.gaps.map { gap in
      let missing = format.amount(abs(gap.missingMinor), code, inflow: gap.missingMinor > 0)
      let from = format.day(gap.before.bookedDay.date(calendar: format.calendar))
      let to = format.day(gap.after.bookedDay.date(calendar: format.calendar))
      return ImportGapItem(
        id: gap.id, title: "Rows may be missing between \(from) and \(to)", missing: missing, before: item(gap.before),
        after: item(gap.after),
        advice:
          "The balance after \(item(gap.before).payee) is \(item(gap.before).balanceAfter), but the next row starts from \(item(gap.after).startsFrom): rows adding up to \(missing) are not in this file. Leave imports a row as the file says; Remove does not import it. This is a warning; it never blocks the import.")
    }
  }

  /// Whether the file's opening balance matches the account (PKO), as a line for the gaps list.
  public var startCheckNote: ImportToneNote? {
    guard let check = preview?.startCheck else { return nil }
    let code = staleCurrencyCode
    let name = preview?.targetAccountID.flatMap { id in accounts.first { $0.id == id }?.name } ?? "the account"
    if check.isMatch { return ImportToneNote("File start matches \(name).", .success) }
    return ImportToneNote(
      "The file starts at \(format.amount(abs(check.fileStartMinor), code, inflow: check.fileStartMinor >= 0)) but \(name) has \(format.amount(abs(check.accountClearedMinor), code, inflow: check.accountClearedMinor >= 0)) (difference \(format.amount(abs(check.differenceMinor), code, inflow: check.differenceMinor > 0))). Rows may be missing before this file, or hand-typed rows are not cleared yet.",
      .attention)
  }

  public func setGapRow(_ id: String, removed: Bool) {
    update(keepBulk: true) { $0.setGapRow(id, removed: removed) }
  }

  public func leaveAllGaps() {
    update(keepBulk: true) { preview in
      for gap in preview.continuity.gaps {
        preview.setGapRow(gap.before.id, removed: false)
        preview.setGapRow(gap.after.id, removed: false)
      }
    }
  }

  /// The offer after a PKO import: Reconcile the account with the statement's closing balance.
  public var reconcileOffer: ImportReconcileOffer? {
    guard summary != nil, let offer = reconcileOfferStore else { return nil }
    return offer
  }
}

/// A line with a tone, for the checks lists.
public struct ImportToneNote: Hashable, Sendable {
  public var text: String
  public var tone: ImportTone
  public init(_ text: String, _ tone: ImportTone) {
    self.text = text
    self.tone = tone
  }
}

extension ImportWizardModel {
  /// A PKO file with counterparties to map (own accounts, ATM cash account): the mapping tab stays.
  var hasCounterpartyMappings: Bool {
    guard preview?.source == .pko else { return false }
    return mappingGroups.dropFirst().first.map { !$0.items.isEmpty } ?? false
  }
}
