import AbacusDomain
import Foundation

/// What the editor sheet is opened for.
public enum TransactionEditorMode: Hashable, Sendable, Identifiable {
  case new
  case edit(Txn.ID)

  public var id: String {
    switch self {
    case .new: "new"
    case .edit(let id): "edit-\(id.uuidString)"
    }
  }
}

/// How the sheet was closed: the presenter reloads its list after `.saved` / `.deleted`.
public enum TransactionEditorResult: Hashable, Sendable {
  case saved(Txn.ID)
  case deleted(Txn.ID)
  case cancelled
}

/// A fee, cashback or split line in the form (R-TX-6), amount in the account currency.
public struct EditorLine: Identifiable, Hashable, Sendable {
  public var id: UUID
  /// `.expense` takes money out of the account, `.income` puts it in.
  public var kind: CategoryKind
  /// An `.income` line may use an expense category: a refund line (D22).
  public var categoryID: AbacusDomain.Category.ID?
  public var amountText: String
  public var note: String
  /// The stored record when editing; its original-currency fields are kept while the amount
  /// stays the same.
  public var stored: AttachedRecord?

  public init(
    id: UUID = UUID(), kind: CategoryKind = .expense, categoryID: AbacusDomain.Category.ID? = nil,
    amountText: String = "", note: String = "", stored: AttachedRecord? = nil
  ) {
    self.id = id
    self.kind = kind
    self.categoryID = categoryID
    self.amountText = amountText
    self.note = note
    self.stored = stored
  }
}

/// The form's raw state, as typed. Expense/income use `accountID` + `currencyCode`; transfers
/// use `fromID`/`toID` and the From account's currency. Both sets are kept so switching the
/// type back and forth loses nothing (approved prototype 3).
public struct EditorDraft: Hashable, Sendable {
  public var id: Txn.ID
  public var type: TxnType
  /// The amount in `currencyCode` (expense/income) or in the From currency (transfer).
  public var amountText: String
  /// Transaction currency: any ISO 4217 code (R-CUR-4, R-EDIT-4).
  public var currencyCode: String
  public var accountID: Account.ID?
  /// "Charged to account", typed by the user; when `chargedEdited` is false the field shows
  /// the estimate at the day's rate instead.
  public var chargedText: String
  public var chargedEdited: Bool
  /// The user's pick; while `categoryChosen` is false a rule suggestion wins (R-EDIT-3).
  public var categoryID: AbacusDomain.Category.ID?
  public var categoryChosen: Bool
  /// Expense refund / income reversal (R-TX-4).
  public var isRefund: Bool
  public var fromID: Account.ID?
  public var toID: Account.ID?
  /// "Amount received" in the To currency (cross-currency transfers, R-TX-5).
  public var toAmountText: String
  public var payee: String
  public var occurredAt: Date
  /// The user's pick; while `eventChosen` is false an active event is pre-selected (R-EVT-2).
  public var eventID: Event.ID?
  public var eventChosen: Bool
  public var note: String
  public var lines: [EditorLine]
  /// The stored transaction when editing (keeps source, import batch, pending flag, booking
  /// day and creation time); nil for a new one.
  public var stored: Txn?

  public init(
    id: Txn.ID = UUID(), type: TxnType = .expense, amountText: String = "", currencyCode: String = "UAH",
    accountID: Account.ID? = nil, chargedText: String = "", chargedEdited: Bool = false,
    categoryID: AbacusDomain.Category.ID? = nil, categoryChosen: Bool = false, isRefund: Bool = false,
    fromID: Account.ID? = nil, toID: Account.ID? = nil, toAmountText: String = "", payee: String = "",
    occurredAt: Date, eventID: Event.ID? = nil, eventChosen: Bool = false, note: String = "",
    lines: [EditorLine] = [], stored: Txn? = nil
  ) {
    self.id = id
    self.type = type
    self.amountText = amountText
    self.currencyCode = currencyCode
    self.accountID = accountID
    self.chargedText = chargedText
    self.chargedEdited = chargedEdited
    self.categoryID = categoryID
    self.categoryChosen = categoryChosen
    self.isRefund = isRefund
    self.fromID = fromID
    self.toID = toID
    self.toAmountText = toAmountText
    self.payee = payee
    self.occurredAt = occurredAt
    self.eventID = eventID
    self.eventChosen = eventChosen
    self.note = note
    self.lines = lines
    self.stored = stored
  }

  /// The form for a stored transaction (edit mode). Amounts become field text in their
  /// currency's digits; a foreign purchase shows the original amount and currency with the
  /// charged amount as typed (R-CUR-4).
  public init(editing row: TxnWithLines, accounts: [Account.ID: Account]) {
    let txn = row.txn
    let account = accounts[txn.accountID]
    let accountCode = account?.currency.rawValue ?? "UAH"
    self.init(id: txn.id, type: txn.type, occurredAt: txn.occurredAt)
    stored = txn
    payee = txn.payee
    note = txn.note
    eventID = txn.eventID
    eventChosen = true
    isRefund = txn.type != .transfer && txn.isRefund
    accountID = txn.accountID
    switch txn.type {
    case .transfer:
      fromID = txn.accountID
      toID = txn.toAccountID
      currencyCode = accountCode
      amountText = EditorAmount.text(minor: txn.amountMinor, code: accountCode)
      if let toAmount = txn.toAmountMinor {
        let toCode = txn.toAccountID.flatMap { accounts[$0] }?.currency.rawValue ?? accountCode
        toAmountText = EditorAmount.text(minor: toAmount, code: toCode)
      }
    case .expense, .income:
      categoryID = txn.categoryID
      categoryChosen = txn.categoryID != nil
      if let original = txn.originalAmountMinor, let code = txn.originalCurrencyCode?.uppercased(),
        code != accountCode
      {
        currencyCode = code
        amountText = EditorAmount.text(minor: original, code: code)
        chargedText = EditorAmount.text(minor: txn.amountMinor, code: accountCode)
        chargedEdited = true
      } else {
        currencyCode = accountCode
        amountText = EditorAmount.text(minor: txn.amountMinor, code: accountCode)
      }
    }
    lines = row.lines.sorted { $0.position < $1.position }.map { record in
      EditorLine(
        id: record.id, kind: record.kind, categoryID: record.categoryID,
        amountText: EditorAmount.text(minor: record.amountMinor, code: accountCode), note: record.note,
        stored: record)
    }
  }
}
