import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Builds a transaction (create) or a changed copy of one (update) from tool arguments and
/// checks it against the rules the editor enforces (R-TX, R-EDIT).
struct TransactionBuilder {
  let directory: Directory
  let calendar: Calendar

  func build(_ a: Arguments, base: TxnWithLines?) throws -> (txn: Txn, lines: [AttachedRecord]) {
    let creating = base == nil
    var txn = base?.txn ?? Txn(type: .expense, occurredAt: Date(), accountID: UUID(), amountMinor: 0, source: .manual)
    if let base, base.txn.debtRecordID != nil {
      throw ToolError("This transaction is a debt record's leg; edit debts in the Abacus app.")
    }
    if let base, base.txn.isBalanceCorrection { throw ToolError("Balance corrections are not edited through MCP.") }

    if let type = a.string("type") {
      guard let parsed = TxnType(rawValue: type) else { throw ToolError("“type” must be expense, income or transfer") }
      txn.type = parsed
    } else if creating {
      throw ToolError("Missing argument “type”")
    }
    if let date = a.string("date") {
      guard let day = Day(date) else { throw ToolError("“date” must look like 2026-03-31") }
      txn.occurredAt = day.date(calendar: calendar)
    } else if creating {
      throw ToolError("Missing argument “date”")
    }
    let previousAccount = base?.txn.accountID
    if let reference = a.string("account") {
      txn.accountID = try directory.account(reference).id
    } else if creating {
      throw ToolError("Missing argument “account”")
    }
    guard let account = directory.accounts.first(where: { $0.id == txn.accountID }) else {
      throw ToolError("The transaction's account no longer exists")
    }
    if txn.accountID != previousAccount, account.isArchived {
      throw ToolError("“\(account.name)” is archived; unarchive it first or pick another account.")
    }
    if let amount = a.string("amount") {
      txn.amountMinor = try positive(amount, "amount", currency: account.currency)
    } else if creating {
      throw ToolError("Missing argument “amount”")
    }
    if a.present("payee") { txn.payee = a.string("payee") ?? "" }
    if a.present("note") { txn.note = a.string("note") ?? "" }
    if a.present("event") { txn.eventID = try a.string("event").map { try directory.event($0).id } }

    switch txn.type {
    case .transfer:
      if a.present("to_account") || creating {
        guard let to = a.string("to_account") else { throw ToolError("A transfer needs “to_account”") }
        txn.toAccountID = try directory.account(to).id
      }
      guard let toID = txn.toAccountID, let target = directory.accounts.first(where: { $0.id == toID }) else {
        throw ToolError("A transfer needs “to_account”")
      }
      guard toID != txn.accountID else { throw ToolError("A transfer needs two different accounts") }
      if toID != base?.txn.toAccountID, target.isArchived { throw ToolError("“\(target.name)” is archived.") }
      if target.currency == account.currency {
        txn.toAmountMinor = txn.amountMinor
      } else if let received = a.string("to_amount") {
        txn.toAmountMinor = try positive(received, "to_amount", currency: target.currency)
      } else if base?.txn.toAmountMinor == nil || toID != base?.txn.toAccountID {
        throw ToolError("The accounts use different currencies; give “to_amount” in \(target.currency.rawValue)")
      }
      if txn.amountMinor != base?.txn.amountMinor || toID != base?.txn.toAccountID || txn.accountID != previousAccount {
        txn.isEstimatedTransferAmount = false
      }
      txn.categoryID = nil
      txn.isRefund = false
      txn.refundOfID = nil
      txn.originalAmountMinor = nil
      txn.originalCurrencyCode = nil
    case .expense, .income:
      txn.toAccountID = nil
      txn.toAmountMinor = nil
      txn.isEstimatedTransferAmount = false
      if a.present("category") {
        txn.categoryID = try a.string("category").map { try directory.category($0).id }
      }
      if let id = txn.categoryID, let category = directory.categories.first(where: { $0.id == id }) {
        guard category.kind.rawValue == txn.type.rawValue else {
          throw ToolError("“\(directory.categoryName(id))” is an \(category.kind.rawValue) category; this is an \(txn.type.rawValue)")
        }
      }
      if let refund = a.bool("is_refund") { txn.isRefund = refund }
      if a.present("refund_of") {
        if let original = a.string("refund_of") {
          guard let id = UUID(uuidString: original) else { throw ToolError("“refund_of” must be a transaction id") }
          txn.refundOfID = id
          txn.isRefund = true
        } else {
          txn.refundOfID = nil
        }
      }
      if txn.refundOfID != nil, txn.type != .expense { throw ToolError("Only an expense refund can be linked to its original") }
      if a.present("original_amount") || a.present("original_currency") {
        if let code = a.string("original_currency"), let amount = a.string("original_amount") {
          let digits = CurrencyDigits.minorUnits(code)
          guard let minor = Amounts.minor(from: amount, digits: digits), minor > 0 else {
            throw ToolError("“original_amount” must be a positive amount with at most \(digits) decimals")
          }
          txn.originalAmountMinor = minor
          txn.originalCurrencyCode = code.uppercased()
        } else if a.string("original_currency") == nil, a.string("original_amount") == nil {
          txn.originalAmountMinor = nil
          txn.originalCurrencyCode = nil
        } else {
          throw ToolError("Give “original_amount” and “original_currency” together, or neither")
        }
      }
    }
    if txn.type != .expense { txn.refundOfID = nil }

    var lines = base?.lines ?? []
    if a.present("attached_records") {
      lines = try (a.raw["attached_records"]?.arrayValue ?? []).enumerated().map { index, item in
        let line = Arguments(item)
        let kind = CategoryKind(rawValue: line.string("kind") ?? "expense")
        guard let kind else { throw ToolError("An attached record's kind must be expense or income") }
        return AttachedRecord(
          txnID: txn.id, kind: kind, categoryID: try line.string("category").map { try directory.category($0).id },
          amountMinor: try positive(try line.requiredString("amount"), "attached record amount", currency: account.currency),
          note: line.string("note") ?? "", position: index)
      }
    }
    return (txn, lines)
  }

  func positive(_ text: String, _ field: String, currency: Currency) throws -> Int64 {
    guard let minor = Amounts.minor(from: text), minor > 0 else {
      throw ToolError("“\(field)” must be a positive amount with at most 2 decimals, like 12.50 (direction comes from the type)")
    }
    return minor
  }

  /// "expense 50.00 PLN “Corner shop” on 2026-03-05 in Main".
  func describe(_ txn: Txn) -> String {
    let account = directory.accounts.first { $0.id == txn.accountID }
    var text = "\(txn.type.rawValue)\(txn.isRefund ? " refund" : "") \(Amounts.string(minor: txn.amountMinor)) \(account?.currency.rawValue ?? "")"
    if !txn.payee.isEmpty { text += " “\(txn.payee)”" }
    text += " on \(Day(txn.occurredAt, calendar: calendar)) in \(account?.name ?? "?")"
    if txn.type == .transfer, let to = txn.toAccountID { text += " → \(directory.accountName(to))" }
    if let category = txn.categoryID { text += " [\(directory.categoryName(category))]" }
    return text
  }

  /// What differs between two versions, for the confirmation text.
  func changes(from old: TxnWithLines, to new: (txn: Txn, lines: [AttachedRecord])) -> [String] {
    let a = old.txn
    let b = new.txn
    var out: [String] = []
    func note(_ name: String, _ x: String, _ y: String) { if x != y { out.append("\(name): \(x.isEmpty ? "–" : x) → \(y.isEmpty ? "–" : y)") } }
    note("type", a.type.rawValue, b.type.rawValue)
    note("date", Day(a.occurredAt, calendar: calendar).string, Day(b.occurredAt, calendar: calendar).string)
    note("account", directory.accountName(a.accountID), directory.accountName(b.accountID))
    note("amount", Amounts.string(minor: a.amountMinor), Amounts.string(minor: b.amountMinor))
    note("to account", a.toAccountID.map(directory.accountName) ?? "", b.toAccountID.map(directory.accountName) ?? "")
    note("category", a.categoryID.map(directory.categoryName) ?? "", b.categoryID.map(directory.categoryName) ?? "")
    note("payee", a.payee, b.payee)
    note("note", a.note, b.note)
    note("event", a.eventID.flatMap(directory.eventName) ?? "", b.eventID.flatMap(directory.eventName) ?? "")
    note("refund", a.isRefund ? "yes" : "no", b.isRefund ? "yes" : "no")
    note("refund of", a.refundOfID?.uuidString ?? "", b.refundOfID?.uuidString ?? "")
    if old.lines.map({ [$0.kind.rawValue, "\($0.amountMinor)", $0.categoryID?.uuidString ?? "", $0.note] })
      != new.lines.map({ [$0.kind.rawValue, "\($0.amountMinor)", $0.categoryID?.uuidString ?? "", $0.note] })
    {
      out.append("attached records: \(old.lines.count) → \(new.lines.count)")
    }
    return out
  }
}

extension Arguments {
  /// The key is given, even as null or an empty string (which clears a field on update).
  func present(_ key: String) -> Bool { raw[key] != nil }
}
