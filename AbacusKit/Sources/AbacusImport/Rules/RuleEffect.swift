import AbacusDomain
import Foundation

/// What a rule does to an existing transaction ("Update existing transactions", R-MGMT-6,
/// R-IMP-8). Pure: callers decide whether to save.
public enum RuleEffect {
  /// The transaction as `rule` would leave it, or nil when the rule does not match it or leaves
  /// it unchanged. A debt rule gives the transfer to the person's virtual account (R-DEBT-12,
  /// R-DEBT-19; the store makes it with `transferToDebt`), never for a transaction on an account
  /// that belongs to a debt. Transfers are never touched (neither by a category rule nor by a
  /// transfer rule: halves of a paired transfer stay as they are). A transfer rule is skipped when the
  /// amount in the other account's currency is unknown (different currency and no original
  /// amount in it), and for money coming in when the transaction has attached records (they
  /// would move to the other account).
  public static func apply(
    _ rule: CategoryRule, to item: TxnWithLines, accounts: [Account], categories: [AbacusDomain.Category],
    debts: DebtBook = .empty
  ) -> Txn? {
    var txn = item.txn
    guard txn.type != .transfer else { return nil }
    let kind: CategoryKind = txn.type == .income ? .income : .expense
    let subject = RuleSubject(description: txn.payee, accountID: txn.accountID, amountMinor: txn.amountMinor, kind: kind)
    // The rule is applied on its own, whatever its position (the user asked for it).
    var single = rule
    single.isEnabled = true
    guard RuleMatcher(rules: [single], categories: categories, accounts: accounts).match(subject) != nil else { return nil }

    switch rule.action {
    case .category:
      guard let categoryID = rule.categoryID, txn.categoryID != categoryID else { return nil }
      txn.categoryID = categoryID
      return txn

    case .debt:
      // R-DEBT-12/19: the transaction becomes a transfer between its account and the person's
      // virtual account in its currency. When the person has no such account yet it is made on
      // apply: the shape then has no destination (money in marked by `isRefund`).
      guard let person = rule.debtPerson, !debts.linkedAccountIDs.contains(txn.accountID) else { return nil }
      let inflow = (txn.type == .income) != txn.isRefund
      let own = accounts.first { $0.id == txn.accountID }
      let debt = debts.debt(person: person)
      let virtual = debt.flatMap { debt -> Account? in
        let roles = Set(debts.links(of: debt.id).filter { $0.role == .virtual }.map(\.accountID))
        return debts.accounts(of: debt.id).first { roles.contains($0.id) && $0.currency == own?.currency }
      }
      let mine = txn.accountID
      txn.type = .transfer
      txn.categoryID = nil
      txn.toAmountMinor = nil
      if let virtual {
        txn.isRefund = false
        txn.accountID = inflow ? virtual.id : mine
        txn.toAccountID = inflow ? mine : virtual.id
      } else {
        txn.toAccountID = nil
        txn.isRefund = inflow
      }
      return txn

    case .transfer:
      guard let targetID = rule.transferAccountID, let target = accounts.first(where: { $0.id == targetID }),
        let own = accounts.first(where: { $0.id == txn.accountID })
      else { return nil }
      let otherAmount: Int64
      if target.currency == own.currency {
        otherAmount = txn.amountMinor
      } else if let original = txn.originalAmountMinor, txn.originalCurrencyCode == target.currency.rawValue {
        otherAmount = original
      } else {
        return nil
      }
      let inflow = (txn.type == .income) != txn.isRefund
      if inflow, !item.lines.isEmpty { return nil }
      let ownAmount = txn.amountMinor
      txn.type = .transfer
      txn.categoryID = nil
      txn.isRefund = false
      txn.originalAmountMinor = nil
      txn.originalCurrencyCode = nil
      if inflow {
        txn.accountID = targetID
        txn.amountMinor = otherAmount
        txn.toAccountID = own.id
        txn.toAmountMinor = ownAmount
      } else {
        txn.toAccountID = targetID
        txn.toAmountMinor = otherAmount
      }
      return txn
    }
  }

  /// Every transaction `rule` would change, as changed.
  public static func changes(
    _ rule: CategoryRule, in items: [TxnWithLines], accounts: [Account], categories: [AbacusDomain.Category],
    debts: DebtBook = .empty
  ) -> [Txn] {
    items.compactMap { apply(rule, to: $0, accounts: accounts, categories: categories, debts: debts) }
  }
}
