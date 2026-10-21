import AbacusDomain
import Foundation
import Observation

/// Load state shared by the management screens.
public enum ManagePhase: Equatable, Sendable {
  case idle, loading, loaded
  case failed(String)
}

/// One account row (R-MGMT-1): tile, name, "Kind · CUR", balance in the account currency.
public struct AccountRow: Identifiable, Equatable, Sendable {
  public let id: Account.ID
  public let name: String
  /// "Card · UAH".
  public let detail: String
  public let symbol: String
  public let balanceText: String
  public let isNegative: Bool
  public let isLiability: Bool
  public let isArchived: Bool
}

/// Accounts under one group name ("Monobank", "PKO", …; ungrouped ones under "Other").
public struct AccountGroup: Identifiable, Equatable, Sendable {
  public let name: String
  public let rows: [AccountRow]
  public var id: String { name }
}

/// The inspector form of an account (R-ACC-1). Amounts stay text until saved.
public struct AccountDraft: Equatable, Sendable {
  public let id: Account.ID
  public let isNew: Bool
  public var name: String
  public var kind: AccountKind
  public var currency: Currency
  /// Signed: a liability normally opens negative.
  public var openingBalance: String
  public var openingDate: Date
  public var group: String
  public var iban: String
}

/// The Accounts screen (approved prototype group 4, R-MGMT-1, R-ACC-1…5): accounts grouped with
/// their balances, "Show archived accounts", an inspector to create and edit, archive with a
/// warning when the balance is not zero, unarchive, delete only without transactions.
@MainActor
@Observable
public final class AccountsModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var accounts: [Account] = []
  /// R-ACC-3, in the account currency, through today.
  public private(set) var balances: [Account.ID: Money] = [:]
  /// Transactions touching the account (either side of a transfer).
  public private(set) var txnCounts: [Account.ID: Int] = [:]
  /// R-ACC-4: archived accounts are listed only on request.
  public var showArchived = false
  public private(set) var selection: Account.ID?
  /// The inspector's form; edits are kept until `save()` or `revert()`.
  public var draft: AccountDraft?
  public private(set) var dialog: ManageDialog?
  public private(set) var errorMessage: String?

  @ObservationIgnored public let dependencies: ManageDependencies
  private var format: ManageFormat { dependencies.format }

  public init(dependencies: ManageDependencies) {
    self.dependencies = dependencies
  }

  // MARK: Loading

  /// Reads every account (archived too) and transaction; keeps the selection when it still exists.
  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      let accounts = try await dependencies.accounts.accounts(includeArchived: true)
      let txns = try await dependencies.allTransactions()
      self.accounts = accounts
      balances = Calc.balances(accounts: accounts, txns: txns, through: dependencies.today(), calendar: format.calendar)
      var counts: [Account.ID: Int] = [:]
      for item in txns {
        counts[item.txn.accountID, default: 0] += 1
        if let to = item.txn.toAccountID, to != item.txn.accountID { counts[to, default: 0] += 1 }
      }
      txnCounts = counts
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load accounts: \(error.localizedDescription)")
      return
    }
    if let selection, let account = account(selection) {
      if draft?.id != selection || draft?.isNew == true { draft = Self.draft(account, format: format) }
    } else if draft?.isNew != true {
      select(visibleAccounts.first?.id)
    }
  }

  // MARK: List

  private var visibleAccounts: [Account] {
    accounts.filter { showArchived || !$0.isArchived }
  }

  /// R-MGMT-1: groups in the order of their first account, ungrouped ("Other") last.
  public var groups: [AccountGroup] {
    var order: [String] = []
    var rows: [String: [AccountRow]] = [:]
    for account in visibleAccounts {
      let name = Self.groupName(account)
      if rows[name] == nil { order.append(name) }
      rows[name, default: []].append(row(account))
    }
    if let other = order.firstIndex(of: Self.otherGroup) { order.append(order.remove(at: other)) }
    return order.map { AccountGroup(name: $0, rows: rows[$0] ?? []) }
  }

  static let otherGroup = "Other"

  static func groupName(_ account: Account) -> String {
    let name = account.groupName?.trimmingCharacters(in: .whitespaces) ?? ""
    return name.isEmpty ? otherGroup : name
  }

  private func row(_ account: Account) -> AccountRow {
    let balance = balance(account)
    return AccountRow(
      id: account.id, name: account.name, detail: "\(ManageText.kindTitle(account.kind)) · \(account.currency.rawValue)",
      symbol: ManageText.symbol(account.currency), balanceText: format.money(balance),
      isNegative: balance.minorUnits < 0, isLiability: account.kind.isLiability, isArchived: account.isArchived)
  }

  public func account(_ id: Account.ID) -> Account? { accounts.first { $0.id == id } }

  public func balance(_ account: Account) -> Money {
    balances[account.id] ?? Money(minorUnits: account.openingBalanceMinor, currency: account.currency)
  }

  /// Picks an account for the inspector, dropping unsaved edits.
  public func select(_ id: Account.ID?) {
    selection = id
    errorMessage = nil
    draft = id.flatMap(account).map { Self.draft($0, format: format) }
  }

  public func setShowArchived(_ show: Bool) {
    showArchived = show
    if let selection, let account = account(selection), account.isArchived, !show {
      select(visibleAccounts.first?.id)
    }
  }

  // MARK: Inspector

  static func draft(_ account: Account, format: ManageFormat) -> AccountDraft {
    AccountDraft(
      id: account.id, isNew: false, name: account.name, kind: account.kind, currency: account.currency,
      openingBalance: format.amountInput(account.openingBalanceMinor), openingDate: account.openingDate,
      group: account.groupName ?? "", iban: account.iban ?? "")
  }

  /// "New account": an empty form in the display currency, opening today.
  public func newAccount(currency: Currency = .UAH) {
    selection = nil
    errorMessage = nil
    draft = AccountDraft(
      id: UUID(), isNew: true, name: "", kind: .bank, currency: currency, openingBalance: format.amountInput(0),
      openingDate: dependencies.today().date(calendar: format.calendar), group: "", iban: "")
  }

  /// The account being edited (nil for a new one).
  public var selectedAccount: Account? { selection.flatMap(account) }

  /// R-ACC-1: the currency is fixed after the first transaction.
  public var isCurrencyLocked: Bool {
    guard let draft, !draft.isNew else { return false }
    return (txnCounts[draft.id] ?? 0) > 0
  }

  public var inspectorTitle: String {
    guard let draft else { return "" }
    if draft.isNew { return draft.name.isEmpty ? "New account" : draft.name }
    return selectedAccount?.name ?? draft.name
  }

  public var balanceText: String? {
    selectedAccount.map { format.money(balance($0)) }
  }

  public var isBalanceNegative: Bool {
    selectedAccount.map { balance($0).minorUnits < 0 } ?? false
  }

  public var archiveTitle: String { selectedAccount?.isArchived == true ? "Unarchive" : "Archive…" }

  /// R-ACC-5.
  public var canDelete: Bool {
    guard let selectedAccount else { return false }
    return (txnCounts[selectedAccount.id] ?? 0) == 0
  }

  /// "Has 781 transactions — archive it instead." / "No transactions yet; it can be deleted."
  public var deleteHint: String {
    guard let selectedAccount else { return "" }
    let count = txnCounts[selectedAccount.id] ?? 0
    return count > 0
      ? "Has \(ManageText.transactions(count)) — archive it instead."
      : "No transactions yet; it can be deleted."
  }

  /// What is wrong with the form, or nil when it can be saved.
  public var validationMessage: String? {
    guard let draft else { return nil }
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
    if format.parseAmount(draft.openingBalance) == nil { return "The opening balance is not a number." }
    return nil
  }

  public var isDirty: Bool {
    guard let draft else { return false }
    if draft.isNew { return true }
    guard let account = account(draft.id) else { return false }
    return built(from: draft, base: account) != account
  }

  public var canSave: Bool { isDirty && validationMessage == nil }

  private func built(from draft: AccountDraft, base: Account?) -> Account? {
    guard let opening = format.parseAmount(draft.openingBalance) else { return nil }
    let group = draft.group.trimmingCharacters(in: .whitespaces)
    let iban = draft.iban.trimmingCharacters(in: .whitespaces)
    var account =
      base
      ?? Account(
        id: draft.id, name: "", currency: draft.currency, kind: draft.kind, openingDate: draft.openingDate,
        position: (accounts.map(\.position).max() ?? -1) + 1)
    account.name = draft.name.trimmingCharacters(in: .whitespaces)
    account.kind = draft.kind
    account.currency = draft.currency
    account.openingBalanceMinor = opening
    account.openingDate = draft.openingDate
    account.groupName = group.isEmpty ? nil : group
    account.iban = iban.isEmpty ? nil : iban
    return account
  }

  /// Creates or updates the account from the form (R-ACC-1).
  public func save() async {
    guard let draft, canSave else { return }
    let base = draft.isNew ? nil : account(draft.id)
    guard var account = built(from: draft, base: base) else { return }
    if isCurrencyLocked, let base { account.currency = base.currency }
    do {
      try await dependencies.accounts.save(account)
      selection = account.id
      self.draft = nil
      await load()
      self.draft = self.account(account.id).map { Self.draft($0, format: format) }
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the account")
    }
  }

  /// Drops the form's edits (a new account's form closes).
  public func revert() {
    if draft?.isNew == true {
      select(visibleAccounts.first?.id)
    } else {
      select(selection)
    }
  }

  // MARK: Archive and delete

  /// Archive… asks first; with a non-zero balance the dialog warns (R-ACC-4). Unarchive is direct.
  public func archiveOrUnarchive() async {
    guard let account = selectedAccount else { return }
    if account.isArchived {
      await setArchived(account.id, false)
    } else {
      let balance = balance(account)
      dialog =
        balance.minorUnits != 0
        ? ManageDialog(
          action: .archiveAccount(account.id), title: "Archive “\(account.name)”?",
          message:
            "Its balance is \(format.money(balance)), not zero. Archived accounts are hidden from pickers and the dashboard and are not counted in net worth. Its history stays.",
          confirmTitle: "Archive anyway", isDestructive: true)
        : ManageDialog(
          action: .archiveAccount(account.id), title: "Archive “\(account.name)”?",
          message: "It will be hidden from pickers and the dashboard. Its history stays.",
          confirmTitle: "Archive", isDestructive: false)
    }
  }

  /// Delete… (R-ACC-5): only an account without transactions, after a confirmation.
  public func requestDelete() {
    guard let account = selectedAccount, canDelete else { return }
    dialog = ManageDialog(
      action: .deleteAccount(account.id), title: "Delete “\(account.name)”?",
      message: "It has no transactions. This can't be undone.", confirmTitle: "Delete", isDestructive: true)
  }

  public func cancelDialog() { dialog = nil }

  public func confirmDialog() async {
    guard let dialog else { return }
    self.dialog = nil
    switch dialog.action {
    case .archiveAccount(let id):
      await setArchived(id, true)
      // The archived account stays visible and selected (prototype).
      showArchived = true
    case .deleteAccount(let id):
      do {
        try await dependencies.accounts.delete(id)
        selection = nil
        draft = nil
        await load()
      } catch {
        errorMessage = ManageFailure.message(error, doing: "delete the account")
      }
    default:
      break
    }
  }

  private func setArchived(_ id: Account.ID, _ archived: Bool) async {
    do {
      try await dependencies.accounts.setArchived(id, archived)
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: archived ? "archive the account" : "unarchive the account")
    }
  }
}
