import AbacusDomain
import AbacusImport
import Foundation
import Observation

// C40: the transfer popup of the import review, opened by double-clicking a transfer row.
//
// It shows the From and To accounts (searchable pickers; the statement's side only offers accounts
// in the statement's currency), what made the row a transfer (the transaction it takes over, a
// typed or estimated amount, paired halves, an account number, a rule, the user's choice) and,
// under each account, the transactions of that account on the transfer's day (stored ones and the
// rows of this file). "Change transaction…" opens "Find the other side…" for the other account,
// limited to the transfer's day. The rules live in `ImportTransferEdit.swift` (AbacusImport).

/// The model of the transfer popup.
@MainActor
@Observable
public final class ImportTransferEditor {
  /// One transaction listed under an account.
  public struct Line: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// "Income · stored" / "In this file · New".
    public var subtitle: String
    public var amountText: String
    public var isInflow: Bool
    /// "This transfer", "Becomes this transfer": the lines tied to the transfer.
    public var badge: String?
  }

  public let rowID: String
  /// "Transfer · JAN PRZYKLAD".
  public let title: String
  /// "−$100.00 on PKO USD · 10.03.2026".
  public let subtitle: String
  /// The end the statement's account is on.
  public let statementEnd: ImportTransferEnd
  /// The draft choice; Save applies it.
  public var fromAccountID: Account.ID? { didSet { if fromAccountID != oldValue { errorMessage = nil } } }
  public var toAccountID: Account.ID? { didSet { if toAccountID != oldValue { errorMessage = nil } } }
  /// What each picker offers.
  public let fromItems: [AccountPickerItem]
  public let toItems: [AccountPickerItem]
  /// "This statement's account · USD accounts only" / "The other account".
  public let fromNote: String
  public let toNote: String
  /// What made the row a transfer ("Takes over “Salary” of 11.03.2026 …").
  public let relations: [String]
  /// The transaction of the other account tied to the transfer, or what stands in for it.
  public let relatedTransaction: String
  /// "Change transaction…" is offered (the other side can be searched for this row).
  public let canChangeTransaction: Bool
  /// The transfer's day.
  public let day: Day
  public let dayText: String
  public private(set) var fromLines: [Line] = []
  public private(set) var toLines: [Line] = []
  public private(set) var isLoading = false
  public var errorMessage: String?

  @ObservationIgnored let originalFrom: Account.ID?
  @ObservationIgnored let originalTo: Account.ID?
  @ObservationIgnored private let lines: @MainActor (Account.ID) async -> [Line]
  @ObservationIgnored private var generation = 0

  init(
    rowID: String, title: String, subtitle: String, statementEnd: ImportTransferEnd, from: Account.ID?, to: Account.ID?,
    fromItems: [AccountPickerItem], toItems: [AccountPickerItem], fromNote: String, toNote: String, relations: [String],
    relatedTransaction: String, canChangeTransaction: Bool, day: Day, dayText: String,
    lines: @escaping @MainActor (Account.ID) async -> [Line]
  ) {
    self.rowID = rowID
    self.title = title
    self.subtitle = subtitle
    self.statementEnd = statementEnd
    self.fromAccountID = from
    self.toAccountID = to
    self.originalFrom = from
    self.originalTo = to
    self.fromItems = fromItems
    self.toItems = toItems
    self.fromNote = fromNote
    self.toNote = toNote
    self.relations = relations
    self.relatedTransaction = relatedTransaction
    self.canChangeTransaction = canChangeTransaction
    self.day = day
    self.dayText = dayText
    self.lines = lines
  }

  /// The draft differs from the row.
  public var hasChanges: Bool { fromAccountID != originalFrom || toAccountID != originalTo }

  /// The accounts the lists are loaded for; the popup reloads when it changes.
  public var listKey: [Account.ID?] { [fromAccountID, toAccountID] }

  /// Loads the transactions of both accounts on the transfer's day. A newer call supersedes an
  /// older one.
  public func load() async {
    generation += 1
    let current = generation
    isLoading = true
    let from = fromAccountID
    let to = toAccountID
    let fromFound = if let from { await lines(from) } else { [Line]() }
    let toFound = if let to { await lines(to) } else { [Line]() }
    guard current == generation else { return }
    fromLines = fromFound
    toLines = toFound
    isLoading = false
  }
}

extension ImportWizardModel {
  /// A row the transfer popup opens for (double click).
  public func canEditTransfer(row id: String) -> Bool {
    preview?.canEditTransfer(row: id) ?? false
  }

  /// Opens the transfer popup of a transfer row; nothing for other rows.
  public func openTransferEditor(forRow id: String) {
    guard let editor = makeTransferEditor(forRow: id) else { return }
    transferEditor = editor
  }

  public func cancelTransferEditor() {
    transferEditor = nil
    counterpartPicker = nil
  }

  /// "Save": the From and To of the draft. When the amount on the new other account is unknown,
  /// "Find the other side…" opens for it (the popup stays and shows the result).
  public func saveTransferEditor() {
    guard let editor = transferEditor else { return }
    guard let from = editor.fromAccountID, let to = editor.toAccountID else {
      editor.errorMessage = "Choose both accounts."
      return
    }
    guard editor.hasChanges else {
      transferEditor = nil
      return
    }
    guard let preview else { return }
    var changed = preview
    let outcome = changed.setTransferAccounts(from: from, to: to, forRow: editor.rowID)
    switch outcome {
    case .refused(let reason):
      editor.errorMessage = reason
    case .done:
      update { $0 = changed }
      transferEditor = nil
    case .needsCounterpart(let accountID):
      update { $0 = changed }
      refreshTransferEditor()
      beginCounterpart(forRow: editor.rowID, to: accountID)
    }
  }

  /// "Change transaction…": "Find the other side…" for the other account, on the transfer's day.
  public func changeTransferTransaction() {
    guard let editor = transferEditor, let sides = preview?.transferSides(forRow: editor.rowID),
      case .existing(let other) = sides.otherAccount
    else { return }
    beginCounterpart(forRow: editor.rowID, to: other, days: sides.day...sides.day)
  }

  /// Rebuilds the open popup from the preview (after the other side was chosen or the search was
  /// closed); closes it when the row is no longer a transfer.
  func refreshTransferEditor() {
    guard let editor = transferEditor else { return }
    transferEditor = makeTransferEditor(forRow: editor.rowID)
  }

  private func makeTransferEditor(forRow id: String) -> ImportTransferEditor? {
    guard let preview, let row = preview.row(id), let sides = preview.transferSides(forRow: id) else { return nil }
    let format = self.format
    let accounts = self.accounts
    let code = sides.statementCurrency?.rawValue ?? row.source.account.currency.rawValue
    let amount = format.money.string(minor: row.amountMinor, code: code)
    let subtitle = "\(row.isInflow ? "+" : "−")\(amount) on \(preview.name(of: row.account)) · \(format.day(row.day))"
    func pickerItems(_ list: [Account]) -> [AccountPickerItem] {
      AccountPickerItem.items(from: AccountOrder.pickerSections(list, groups: accountGroups))
    }
    let statementItems = pickerItems(preview.statementAccountOptions(forRow: id))
    let otherItems = pickerItems(accounts.filter { !$0.isArchived })
    let statementNote = "This statement's account · \(code) accounts only"
    let otherNote = "The other own account"
    func accountID(_ ref: AccountRef) -> Account.ID? { if case .existing(let id) = ref { id } else { nil } }

    let otherCode = accountID(sides.otherAccount).flatMap { id in accounts.first { $0.id == id }?.currency.rawValue } ?? ""
    let relations = sides.relations.map { relationText($0, preview: preview, otherCode: otherCode) }
    var related = "No transaction of the other account is tied to this transfer yet."
    if let absorbed = sides.relations.first(where: { $0.kind == .absorbs || $0.kind == .completesImported })?.txn {
      related = txnText(absorbed)
    }
    let other = accountID(sides.otherAccount)
    let canChange = other.map { preview.counterpartProbe(forRow: id, to: $0) != nil } ?? false
    let pipeline = self.pipeline
    let absorbedID = row.absorbedTxn?.id
      ?? sides.relations.first { $0.kind == .completesImported }?.txn?.id
    let fileRows = preview.rows.filter { Day($0.source.occurredAt, calendar: format.calendar) == sides.day }
    let day = sides.day
    let lines: @MainActor (Account.ID) async -> [ImportTransferEditor.Line] = { accountID in
      let currency = accounts.first { $0.id == accountID }?.currency.rawValue ?? code
      var result: [ImportTransferEditor.Line] = []
      for fileRow in fileRows {
        let onAccount = fileRow.account == .existing(accountID)
        let onCounter = fileRow.type == .transfer && fileRow.counterAccount == .existing(accountID)
        guard onAccount || onCounter else { continue }
        let minor = onAccount ? fileRow.amountMinor : (fileRow.counterAmountMinor ?? fileRow.amountMinor)
        let inflow = onAccount ? fileRow.isInflow : !fileRow.isInflow
        result.append(
          ImportTransferEditor.Line(
            id: "row:" + fileRow.id, title: fileRow.source.payee.isEmpty ? "No description" : fileRow.source.payee,
            subtitle: "In this file", amountText: format.amount(minor, currency, inflow: inflow), isInflow: inflow,
            badge: fileRow.id == id ? "This transfer" : nil))
      }
      let stored = (try? await pipeline.transactions(onAccount: accountID, day: day)) ?? []
      for candidate in stored {
        let txn = candidate.txn
        let minor = (txn.type == .transfer && txn.toAccountID == accountID && txn.accountID != accountID)
          ? (txn.toAmountMinor ?? txn.amountMinor) : txn.amountMinor
        let inflow = Flow.of(txn, on: accountID) == .in
        let kind = switch txn.type {
        case .income: "Income"
        case .expense: "Expense"
        case .transfer: "Transfer"
        }
        result.append(
          ImportTransferEditor.Line(
            id: "txn:" + txn.id.uuidString, title: txn.payee.isEmpty ? "No description" : txn.payee,
            subtitle: "\(kind) · already in Abacus", amountText: format.amount(minor, candidate.currency.rawValue, inflow: inflow),
            isInflow: inflow, badge: txn.id == absorbedID ? "Becomes this transfer" : nil))
      }
      return result
    }
    return ImportTransferEditor(
      rowID: id, title: "Transfer · " + (row.source.payee.isEmpty ? "No description" : row.source.payee), subtitle: subtitle,
      statementEnd: sides.statementEnd, from: accountID(sides.from), to: accountID(sides.to),
      fromItems: sides.statementEnd == .from ? statementItems : otherItems,
      toItems: sides.statementEnd == .to ? statementItems : otherItems,
      fromNote: sides.statementEnd == .from ? statementNote : otherNote,
      toNote: sides.statementEnd == .to ? statementNote : otherNote,
      relations: relations.isEmpty ? ["A transfer given by the file."] : relations, relatedTransaction: related,
      canChangeTransaction: canChange, day: sides.day, dayText: format.longDay(sides.day), lines: lines)
  }

  /// "“Salary” · 11.03.2026 · zł 398.00 on PKO PLN".
  private func txnText(_ txn: Txn) -> String {
    let account = accounts.first { $0.id == txn.accountID }
    let amount = format.money.string(minor: txn.amountMinor, code: account?.currency.rawValue ?? "")
    let payee = txn.payee.isEmpty ? "A transaction" : "“\(txn.payee)”"
    return "\(payee) · \(format.day(txn.occurredAt)) · \(amount) on \(account?.name ?? "?")"
  }

  private func relationText(_ relation: ImportTransferRelation, preview: ImportPreview, otherCode: String) -> String {
    switch relation.kind {
    case .absorbs:
      return "Takes over " + (relation.txn.map(txnText) ?? "a transaction") + " (it becomes this transfer)"
    case .typedAmount:
      return "Amount on the other account typed by you" + amountSuffix(relation.amountMinor, otherCode)
    case .estimatedAmount:
      return "Amount on the other account estimated at the day's rate" + amountSuffix(relation.amountMinor, otherCode)
    case .completesImported:
      return "Completes " + (relation.txn.map(txnText) ?? "a transaction") + ", imported from the other account's statement"
    case .pairedHalves:
      return "Two transfer halves of this file were paired"
    case .pairedRow:
      let other = relation.rowID.flatMap { preview.row($0) }
      return "Paired with " + (other.map { "“\($0.source.payee)” of \(format.day($0.day)) in this file" } ?? "another row of this file")
    case .accountNumber:
      return "The other account was recognised by its account number in the file"
    case .rule:
      return "Made a transfer by the rule “\(relation.ruleLabel ?? "")”"
    case .chosen:
      return "The other account was chosen by you"
    }
  }

  private func amountSuffix(_ minor: Int64?, _ code: String) -> String {
    guard let minor, !code.isEmpty else { return "" }
    return ": " + format.money.string(minor: minor, code: code)
  }
}
