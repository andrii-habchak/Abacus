import AbacusDomain
import Foundation
import Observation

/// Load state shared by the management screens.
public enum ManagePhase: Equatable, Sendable {
  case idle, loading, loaded
  case failed(String)
}

/// One row of the Accounts list (R-MGMT-1, R-MGMT-9): an account (tile, name, "Kind · CUR",
/// balance in the account currency) or a group (folder, name, "3 accounts", the sum of its
/// accounts in the display currency).
public struct AccountRow: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let name: String
  /// "Card · UAH"; for a group "3 accounts".
  public let detail: String
  public let symbol: String
  public let balanceText: String
  public let isNegative: Bool
  public let isLiability: Bool
  public let isArchived: Bool
  /// The account's (group's) colour (R-MGMT-7); nil falls back to blue / red by kind.
  public var colorHex: String? = nil
  /// A group (folder) row.
  public var isGroup = false
  /// An account inside a group (indented).
  public var isChild = false
  /// False for a group shown only because one of its accounts matches the search.
  public var matchesSearch = true
}

/// Where a dragged account or group lands (R-MGMT-9, like Reminders): `.before` / `.after` a
/// row reorders (the sort becomes "Custom order"), `.onto` a group (or an account in one) moves
/// an account into that group.
public typealias AccountDropPosition = CategoryDropPosition

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
  /// nil = top level (R-MGMT-9).
  public var groupID: AccountGroup.ID?
  public var iban: String
  /// `#RRGGBB` (R-MGMT-7).
  public var colorHex: String? = nil
  /// R-DEBT-17: the debt this account belongs to (at most one).
  public var debt: AccountDebtChoice = .none
}

/// The "Debt" section of the account editor (R-DEBT-17): no debt, an existing one, or a new one
/// created by name when the account is saved.
public enum AccountDebtChoice: Equatable, Sendable {
  case none
  case existing(Debt.ID)
  case new(name: String)
}

/// The confirmation sheet of "Archive…" for an account whose balance is not zero (R-ACC-4, C29):
/// the balance, Cancel / Archive and one checkbox. An account that is **not** in a debt can book a
/// compensation transaction that zeroes it; an account **in a debt** can instead forgive the debt
/// by its balance (a manual `forgive` record, R-DEBT-4).
public struct AccountArchiveSheet: Identifiable, Equatable, Sendable {
  public let id: Account.ID
  public let accountName: String
  /// The balance now, in the account currency; never zero.
  public let balance: Money
  public let balanceText: String
  /// Set when the account is linked to a debt (R-DEBT-17).
  public let debtID: Debt.ID?
  public let debtName: String?
  /// "Create a compensation transaction" (accounts outside a debt).
  public var createCompensation = false
  /// "Forgive the debt" (accounts in a debt).
  public var forgiveDebt = false
  /// R-DEBT-4: the forgive record counts as an expense; on by default, offered only when money
  /// owed to me is forgiven.
  public var countAsExpense = true

  public var isLinkedToDebt: Bool { debtID != nil }
  /// A positive balance of a debt account = they owe me (R-DEBT-18).
  public var offersCountAsExpense: Bool { isLinkedToDebt && balance.minorUnits > 0 }
  public var title: String { "Archive “\(accountName)”?" }
}

/// The inspector form of an account group (R-MGMT-9): name and an optional colour.
public struct AccountGroupDraft: Equatable, Sendable {
  public let id: AccountGroup.ID
  public let isNew: Bool
  public var name: String
  public var colorHex: String?
}

/// The editor sheet open on the Accounts page (D55): an account's or a group's form. The sheet
/// keeps its own copy of the draft; the model only sees it again on Save.
public enum AccountSheet: Identifiable, Equatable, Sendable {
  case account(AccountDraft)
  case group(AccountGroupDraft)

  public var id: UUID {
    switch self {
    case .account(let draft): draft.id
    case .group(let draft): draft.id
    }
  }
}

/// An account dropped onto an ungrouped account (D55, like folders on iOS): a new group will hold
/// both; the page asks for its name first (`defaultName`: the target's first word).
public struct AccountGroupPrompt: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// The dragged account (the first one of a multi-selection drag, C27).
  public let moving: Account.ID
  /// The other dragged accounts of a multi-selection drag, in list order (C27).
  public let alsoMoving: [Account.ID]
  /// The ungrouped account it was dropped onto; the group takes its place.
  public let target: Account.ID
  public let defaultName: String

  /// Every dragged account in order.
  public var allMoving: [Account.ID] { [moving] + alsoMoving }
}

/// The Accounts screen (approved prototype group 4, R-MGMT-1, R-MGMT-9, R-ACC-1…5, D48): page
/// search, sort (Name A–Z / Z–A / Custom order) and currency filter, groups as folders with the
/// sum of their accounts, drag and drop (between rows reorders, onto a group moves into it),
/// "Show archived accounts", an inspector to create and edit accounts and groups, archive with a
/// warning when the balance is not zero, unarchive, delete only without transactions.
@MainActor
@Observable
public final class AccountsModel {
  public private(set) var phase: ManagePhase = .idle
  public private(set) var accounts: [Account] = []
  public private(set) var groups: [AccountGroup] = []
  /// R-ACC-3, in the account currency, through today.
  public private(set) var balances: [Account.ID: Money] = [:]
  /// Transactions touching the account (either side of a transfer).
  public private(set) var txnCounts: [Account.ID: Int] = [:]
  /// R-DEBT-17: the debts (for the editor's "Debt" section) and which one each account is in.
  public private(set) var debts: [Debt] = []
  public private(set) var debtLinks: [Account.ID: DebtAccountLink] = [:]
  /// R-ACC-4: archived accounts are listed only on request.
  public var showArchived = false
  /// The page search: account and group names (R-MGMT-11).
  public var searchText = ""
  /// The currency filter; nil = all currencies.
  public var currencyFilter: Currency?
  /// The account-type filter (R-MGMT-9, C29); empty = every kind.
  public var kindFilter: Set<AccountKind> = []
  /// The page's order (R-MGMT-9); remembered in the settings.
  public private(set) var sort: AccountSort = .default
  /// Group sums are in this currency (the app's display currency).
  public private(set) var displayCurrency: Currency
  /// An account or a group id: the one selected row. nil while several rows are selected
  /// (`multiSelection`) or none is.
  public private(set) var selection: UUID? {
    didSet { if selection != nil { multiSelection = [] } }
  }
  /// Two or more selected rows (Cmd / Shift click, C27); empty otherwise. Only dragging uses it:
  /// the inspector, "New transaction" and the sheets work on `selection`.
  public private(set) var multiSelection: Set<UUID> = []
  /// Every selected row: `multiSelection`, or the single `selection`.
  public var selectedIDs: Set<UUID> {
    multiSelection.isEmpty ? Set(selection.map { [$0] } ?? []) : multiSelection
  }
  /// The account inspector's form; edits are kept until `save()` or `revert()`.
  public var draft: AccountDraft?
  /// The group inspector's form (a group selected or "New group").
  public var groupDraft: AccountGroupDraft?
  public private(set) var dialog: ManageDialog?
  /// The archive confirmation of an account with a balance (R-ACC-4, C29); its checkboxes are set
  /// through `setCreateCompensation` / `setForgiveDebt` / `setCountAsExpense`.
  public private(set) var archiveSheet: AccountArchiveSheet?
  public private(set) var errorMessage: String?
  /// The open editor sheet (D55); nil while none is open.
  public private(set) var sheet: AccountSheet?
  /// A drop of an account onto an ungrouped account waiting for the new group's name (D55).
  public private(set) var groupPrompt: AccountGroupPrompt?

  @ObservationIgnored public let dependencies: ManageDependencies
  /// Called after this screen changed data other screens show (names, colours: R-MGMT-7),
  /// so the transaction list and the dashboard re-read it.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?
  /// The selection before "New account" / "New group", given back when the sheet is cancelled.
  @ObservationIgnored private var selectionBeforeNew: UUID?
  @ObservationIgnored private var converter: (any CurrencyConverter)?
  @ObservationIgnored private var sortLoaded = false
  private var format: ManageFormat { dependencies.format }

  public init(dependencies: ManageDependencies, displayCurrency: Currency = .UAH) {
    self.dependencies = dependencies
    self.displayCurrency = displayCurrency
  }

  // MARK: Loading

  /// Reads every account (archived too), group and transaction; keeps the selection when it
  /// still exists.
  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      let accounts = try await dependencies.accounts.accounts(includeArchived: true)
      let groups = try await dependencies.accounts.groups()
      let txns = try await dependencies.allTransactions()
      self.accounts = accounts
      self.groups = groups
      dropChecks = [:]
      balances = Calc.balances(accounts: accounts, txns: txns, through: dependencies.today(), calendar: format.calendar)
      var counts: [Account.ID: Int] = [:]
      for item in txns {
        counts[item.txn.accountID, default: 0] += 1
        if let to = item.txn.toAccountID, to != item.txn.accountID { counts[to, default: 0] += 1 }
      }
      txnCounts = counts
      if !sortLoaded {
        sortLoaded = true
        let stored = try? await dependencies.settings.value(.accountSort)
        sort = stored.flatMap(AccountSort.init(rawValue:)) ?? .default
        dropChecks = [:]
      }
      converter = await dependencies.converter()
      if let repository = dependencies.debts, let book = try? await repository.book() {
        debts = book.debts
        debtLinks = Dictionary(book.links.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
      }
      phase = .loaded
    } catch {
      phase = .failed("Couldn't load accounts: \(error.localizedDescription)")
      return
    }
    if let selection, let group = group(selection) {
      if groupDraft?.id != selection { groupDraft = Self.groupDraft(group) }
    } else if let selection, let account = account(selection) {
      if draft?.id != selection || draft?.isNew == true { draft = makeDraft(account) }
    } else if multiSelection.count > 1 {
      // Several rows selected: keep those that still exist.
      let alive = multiSelection.filter { account($0) != nil || group($0) != nil }
      if alive.count > 1 { multiSelection = alive } else { select(alive.first) }
    } else if draft?.isNew != true && groupDraft?.isNew != true {
      select(firstAccountID)
    }
  }

  /// Re-reads the rates (after a refresh): group sums follow.
  public func refreshRates() async {
    converter = await dependencies.converter()
  }

  public func setDisplayCurrency(_ currency: Currency) {
    displayCurrency = currency
  }

  // MARK: List

  private var visibleAccounts: [Account] {
    accounts.filter { showArchived || !$0.isArchived }
  }

  private var firstAccountID: Account.ID? {
    rows.first { !$0.isGroup }?.id
  }

  private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }

  private func matches(_ name: String) -> Bool {
    trimmedSearch.isEmpty || name.localizedStandardContains(trimmedSearch)
  }

  /// The tree in the page's sort (R-MGMT-9), every account and group (archived too).
  public var ordered: [AccountTreeItem] {
    AccountOrder.tree(accounts, groups: groups, by: sort)
  }

  /// What the list shows: the tree in the page's sort, archived accounts only on request, the
  /// currency filter, the search (a matching account brings its group; a matching group shows
  /// its accounts). Empty groups show only without a search or filter.
  public var rows: [AccountRow] {
    let filtering = !trimmedSearch.isEmpty || currencyFilter != nil || !kindFilter.isEmpty
    var result: [AccountRow] = []
    var pendingGroup: (group: AccountGroup, matches: Bool)?
    var groupShown = false
    for item in AccountOrder.tree(visibleAccounts, groups: groups, by: sort) {
      switch item {
      case .group(let group):
        pendingGroup = (group, matches(group.name))
        groupShown = false
        if !filtering {
          result.append(groupRow(group))
          groupShown = true
        }
      case .account(let account):
        let inGroup = account.groupID.flatMap { id in groups.contains { $0.id == id } ? id : nil }
        if inGroup == nil { pendingGroup = nil }
        if let filter = currencyFilter, account.currency != filter { continue }
        if !kindFilter.isEmpty, !kindFilter.contains(account.kind) { continue }
        let groupMatches = inGroup != nil && pendingGroup?.matches == true
        guard matches(account.name) || groupMatches else { continue }
        if let pending = pendingGroup, inGroup != nil, !groupShown {
          var header = groupRow(pending.group)
          header.matchesSearch = pending.matches
          result.append(header)
          groupShown = true
        }
        result.append(row(account, isChild: inGroup != nil))
      }
    }
    // A group whose name matches but has no account left after the currency filter.
    if !trimmedSearch.isEmpty, currencyFilter == nil, kindFilter.isEmpty {
      let shown = Set(result.map(\.id))
      for group in groups where matches(group.name) && !shown.contains(group.id) {
        if let index = insertionIndex(for: group, in: result) { result.insert(groupRow(group), at: index) }
      }
    }
    return result
  }

  /// Keeps a matching empty group at its place in the sort.
  private func insertionIndex(for group: AccountGroup, in rows: [AccountRow]) -> Int? {
    let order = AccountOrder.tree(visibleAccounts, groups: groups, by: sort).map(\.id)
    guard let rank = order.firstIndex(of: group.id) else { return nil }
    return rows.firstIndex { row in (order.firstIndex(of: row.id) ?? .max) > rank } ?? rows.count
  }

  /// "No accounts match “xyz”." while the search or filter hides every row.
  public var emptySearchMessage: String? {
    guard rows.isEmpty, !accounts.isEmpty else { return nil }
    let search = trimmedSearch
    if !search.isEmpty { return "No accounts match “\(search)”." }
    if let currencyFilter, kindFilter.isEmpty { return "No \(currencyFilter.rawValue) accounts." }
    if hasActiveFilters { return "No accounts match the filters." }
    return nil
  }

  // MARK: Filters (R-MGMT-9, C29)

  /// The account-type filter's choices: the kinds that exist among the listed accounts under the
  /// current currency filter (so every choice finds something), in the order of
  /// `AccountKind.allCases`; a kind already selected stays so it can be removed.
  public var kindOptions: [AccountKind] {
    let present = Set(
      visibleAccounts.filter { currencyFilter == nil || $0.currency == currencyFilter }.map(\.kind)
    ).union(kindFilter)
    return AccountKind.allCases.filter(present.contains)
  }

  public func toggleKind(_ kind: AccountKind) {
    if kindFilter.contains(kind) { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
  }

  /// "All types" / "Bank account" / "Bank account +1" for the filter button.
  public var kindFilterLabel: String {
    let selected = AccountKind.allCases.filter(kindFilter.contains)
    guard let first = selected.first else { return "All types" }
    return selected.count == 1 ? ManageText.kindTitle(first) : "\(ManageText.kindTitle(first)) +\(selected.count - 1)"
  }

  /// The currency or the type filter is on (blue outline, "Clear filters").
  public var hasActiveFilters: Bool { currencyFilter != nil || !kindFilter.isEmpty }

  public func clearFilters() {
    currencyFilter = nil
    kindFilter = []
  }

  /// The currency filter's choices (`Currency.displayOrder`).
  public var currencyOptions: [Currency] { Currency.displayOrder }

  private func row(_ account: Account, isChild: Bool) -> AccountRow {
    let balance = balance(account)
    return AccountRow(
      id: account.id, name: account.name, detail: "\(ManageText.kindTitle(account.kind)) · \(account.currency.rawValue)",
      symbol: ManageText.symbol(account.currency), balanceText: format.money(balance),
      isNegative: balance.minorUnits < 0, isLiability: account.kind.isLiability, isArchived: account.isArchived,
      colorHex: account.colorHex, isChild: isChild)
  }

  private func groupRow(_ group: AccountGroup) -> AccountRow {
    let members = accounts.filter { $0.groupID == group.id && (showArchived || !$0.isArchived) }
    let sum = groupSum(group.id)
    let count = members.count
    return AccountRow(
      id: group.id, name: group.name, detail: count == 1 ? "1 account" : "\(count) accounts", symbol: "",
      balanceText: sum.map { format.money($0) } ?? "—", isNegative: (sum?.minorUnits ?? 0) < 0, isLiability: false,
      isArchived: false, colorHex: group.colorHex, isGroup: true)
  }

  /// R-MGMT-9: the sum of the group's non-archived accounts in the display currency at the
  /// latest rates (like net worth); nil when a non-zero balance has no rate.
  public func groupSum(_ id: AccountGroup.ID) -> Money? {
    var total = Money.zero(displayCurrency)
    for account in accounts where account.groupID == id && !account.isArchived {
      let balance = balance(account)
      if balance.minorUnits == 0 { continue }
      guard let converted = converter?.convertAtLatest(balance, to: displayCurrency)
        ?? (balance.currency == displayCurrency ? balance : nil)
      else { return nil }
      total = total + converted
    }
    return total
  }

  public func account(_ id: Account.ID) -> Account? { accounts.first { $0.id == id } }
  public func group(_ id: AccountGroup.ID) -> AccountGroup? { groups.first { $0.id == id } }

  public func balance(_ account: Account) -> Money {
    balances[account.id] ?? Money(minorUnits: account.openingBalanceMinor, currency: account.currency)
  }

  /// Picks an account or a group for the inspector, dropping unsaved edits.
  public func select(_ id: UUID?) {
    multiSelection = []
    selection = id
    errorMessage = nil
    draft = id.flatMap(account).map { makeDraft($0) }
    groupDraft = id.flatMap(group).map(Self.groupDraft)
  }

  /// The list's selection (C27): one row selects it as before; several rows (Cmd / Shift click)
  /// are kept as `multiSelection` with the inspector, drafts and `selection` cleared.
  public func select(ids: Set<UUID>) {
    let known = ids.filter { account($0) != nil || group($0) != nil }
    if known.count <= 1 { return select(known.first) }
    select(nil)
    multiSelection = known
  }

  public func setShowArchived(_ show: Bool) {
    showArchived = show
    if let selection, let account = account(selection), account.isArchived, !show {
      select(firstAccountID)
    }
  }

  /// The sort selector (R-MGMT-9); the choice is remembered.
  public func setSort(_ sort: AccountSort) async {
    guard sort != self.sort else { return }
    self.sort = sort
    sortLoaded = true
    dropChecks = [:]
    try? await dependencies.settings.set(.accountSort, sort.rawValue)
  }

  /// Groups A–Z for the account inspector's Group picker.
  public var groupOptions: [AccountGroup] { groups.sorted(by: AccountOrder.byName) }

  // MARK: Account inspector

  func makeDraft(_ account: Account) -> AccountDraft {
    AccountDraft(
      id: account.id, isNew: false, name: account.name, kind: account.kind, currency: account.currency,
      openingBalance: format.amountInput(account.openingBalanceMinor), openingDate: account.openingDate,
      groupID: account.groupID, iban: account.iban ?? "", colorHex: account.colorHex,
      debt: debtLinks[account.id].map { .existing($0.debtID) } ?? .none)
  }

  // MARK: Debt link (R-DEBT-17)

  /// The "Debt" section is offered when the app wires a debt repository.
  public var offersDebts: Bool { dependencies.debts != nil }

  public func debt(_ id: Debt.ID) -> Debt? { debts.first { $0.id == id } }

  /// The debt the account is in now (as stored), for "Currently in <debt>".
  public func linkedDebt(of accountID: Account.ID) -> Debt? {
    debtLinks[accountID].flatMap { debt($0.debtID) }
  }

  /// Debts for the editor's search, by person name (every debt for blank text), name order.
  public func debtOptions(matching text: String) -> [Debt] {
    let key = Debt.personKey(text)
    return debts.filter { key.isEmpty || $0.personKey.contains(key) }
      .sorted { $0.personName.localizedCaseInsensitiveCompare($1.personName) == .orderedAscending }
  }

  /// R-DEBT-17: the role of the link Save writes. **It stays as it is** (C29): an account already
  /// linked keeps its role when its kind changes, in particular external never flips to virtual.
  /// A new link takes the role from the account's *stored* kind (a new account: the chosen one):
  /// a "Debt (person)" account is the person's virtual account, any other (a bank account such as
  /// "Revolut Anna", also when it is turned into a Debt account in the same Save) is their external one.
  public func debtRole(_ draft: AccountDraft) -> DebtAccountRole {
    if !draft.isNew, let link = debtLinks[draft.id] { return link.role }
    let base = draft.isNew ? draft.kind : (account(draft.id)?.kind ?? draft.kind)
    return base == .debt ? .virtual : .external
  }

  /// The kinds the picker offers: the debt kind needs the debt section to link to (C29).
  public func liabilityKindOptions(for draft: AccountDraft) -> [AccountKind] {
    ManageText.liabilityKinds(offeredFor: draft.kind, debtsAvailable: offersDebts)
  }

  /// A short note when the kind change moves the account between assets and liabilities in net
  /// worth (C29); nil for a new account or when the class stays. Net worth is assets − liabilities
  /// of the signed balances, so the total does not change, only the side it is listed on; an
  /// account linked to a debt is counted only through the debt (R-DEBT-18).
  public func kindChangeNote(_ draft: AccountDraft) -> String? {
    guard !draft.isNew, let stored = account(draft.id), stored.kind.isLiability != draft.kind.isLiability else {
      return nil
    }
    if draft.debt != .none {
      return "This account is linked to a debt, so net worth counts its balance only through the debt; "
        + "changing the kind to \(ManageText.kindTitle(draft.kind)) does not move it."
    }
    let from = stored.kind.isLiability ? "Liabilities" : "Assets"
    let to = draft.kind.isLiability ? "Liabilities" : "Assets"
    return "Net worth: the balance moves from \(from) to \(to) (the total does not change)."
  }

  /// What the section says under the picker: where the account is now and what Save will do.
  public func debtNotice(_ draft: AccountDraft) -> String? {
    let current = debtLinks[draft.id].flatMap { draft.isNew ? nil : debt($0.debtID) }
    switch (current, draft.debt) {
    case (let current?, .none):
      return "Currently in \(current.personName). Saving removes it from that debt; its transactions stay."
    case (let current?, .existing(let id)) where id != current.id:
      let target = debt(id)?.personName ?? "the other debt"
      return "Currently in \(current.personName). Saving moves it to \(target); an account is in one debt only."
    case (let current?, .new(let name)):
      return "Currently in \(current.personName). Saving moves it to the new debt \(name.trimmingCharacters(in: .whitespaces))."
    case (let current?, _):
      return "Currently in \(current.personName)."
    case (nil, .new):
      return "A new debt is created for this person when you save."
    default:
      return nil
    }
  }

  /// A short line about the role the link will have.
  public func debtRoleHint(_ draft: AccountDraft) -> String? {
    guard draft.debt != .none else { return nil }
    switch debtRole(draft) {
    case .virtual: return "A \"Debt (person)\" account is the person's virtual account: no statement."
    case .external:
      return draft.kind == .debt
        ? "Linked as the person's own account (external): its transactions drive the debt; the role does not change with the kind."
        : "The person's own account (external): its transactions drive the debt; the account keeps its kind."
    }
  }

  func debtValidation(_ draft: AccountDraft) -> String? {
    switch draft.debt {
    case .none: return nil
    case .existing(let id): return debt(id) == nil ? "That debt no longer exists." : nil
    case .new(let name):
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { return "Enter a name for the new debt." }
      if let other = debts.first(where: { $0.personKey == Debt.personKey(trimmed) }) {
        return "A debt for \(other.personName) already exists: pick it from the list."
      }
      return nil
    }
  }

  private func debtChanged(_ draft: AccountDraft) -> Bool {
    let stored: AccountDebtChoice = draft.isNew ? .none : (debtLinks[draft.id].map { .existing($0.debtID) } ?? .none)
    return draft.debt != stored
  }

  /// Makes the stored link match the choice; the move is unlink then link, with the old link
  /// put back when the new one fails.
  private func applyDebt(_ choice: AccountDebtChoice, role: DebtAccountRole, to accountID: Account.ID) async throws {
    guard let repository = dependencies.debts else { return }
    let old = debtLinks[accountID]
    switch choice {
    case .none:
      if old != nil { try await repository.unlink(accountID) }
    case .existing(let id):
      if let old, old.debtID != id { try await repository.unlink(accountID) }
      do { try await repository.link(accountID, to: id, role: role) } catch {
        if let old, old.debtID != id { try? await repository.link(accountID, to: old.debtID, role: old.role) }
        throw error
      }
    case .new(let name):
      let debt = Debt(personName: name.trimmingCharacters(in: .whitespaces))
      try await repository.save(debt)
      if let old { try await repository.unlink(accountID) }
      do { try await repository.link(accountID, to: debt.id, role: role) } catch {
        if let old { try? await repository.link(accountID, to: old.debtID, role: old.role) }
        try? await repository.delete(debt.id)
        throw error
      }
    }
  }

  /// "New account": an empty form in the display currency, opening today; inside the selected
  /// group (or the selected account's group). Opens the editor sheet.
  public func newAccount(currency: Currency = .UAH) {
    let groupID = selection.flatMap { id in group(id)?.id ?? account(id)?.groupID }
    newAccount(currency: currency, inGroup: groupID)
  }

  /// "New account in <group>" (the split button's menu, D55); nil = top level.
  public func newAccount(currency: Currency = .UAH, inGroup groupID: AccountGroup.ID?) {
    selectionBeforeNew = selection ?? selectionBeforeNew
    selection = nil
    errorMessage = nil
    groupDraft = nil
    let draft = AccountDraft(
      id: UUID(), isNew: true, name: "", kind: .bank, currency: currency, openingBalance: format.amountInput(0),
      openingDate: dependencies.today().date(calendar: format.calendar),
      groupID: groupID.flatMap { group($0)?.id }, iban: "",
      colorHex: ColorPalette.pick(avoiding: accounts.map(\.colorHex)))
    self.draft = draft
    sheet = .account(draft)
  }

  // MARK: Editor sheet (D55)

  /// Opens the editor sheet on an account or a group (double-click, Return, "Edit…").
  public func edit(_ id: UUID) {
    guard account(id) != nil || group(id) != nil else { return }
    select(id)
    if let groupDraft {
      sheet = .group(groupDraft)
    } else if let draft {
      sheet = .account(draft)
    }
  }

  /// Cancel / Escape: closes the sheet without saving; a new item's sheet gives the selection
  /// back.
  public func dismissSheet() {
    let wasNew: Bool
    switch sheet {
    case .account(let draft): wasNew = draft.isNew
    case .group(let draft): wasNew = draft.isNew
    case nil: wasNew = false
    }
    sheet = nil
    if wasNew {
      let previous = selectionBeforeNew.flatMap { id in account(id) != nil || group(id) != nil ? id : nil }
      selectionBeforeNew = nil
      select(previous)
    } else {
      select(selection)
    }
  }

  /// Saves the sheet's account form; the sheet closes when the save worked.
  public func save(_ draft: AccountDraft) async {
    groupDraft = nil
    self.draft = draft
    if await save() {
      sheet = nil
      selectionBeforeNew = nil
    }
  }

  /// Saves the sheet's group form; the sheet closes when the save worked.
  public func save(_ draft: AccountGroupDraft) async {
    self.draft = nil
    groupDraft = draft
    if await save() {
      sheet = nil
      selectionBeforeNew = nil
    }
  }

  /// The account being edited (nil for a new one or a group).
  public var selectedAccount: Account? { selection.flatMap(account) }

  /// R-ACC-1: the currency is fixed after the first transaction.
  public var isCurrencyLocked: Bool {
    draft.map(isCurrencyLocked) ?? false
  }

  public func isCurrencyLocked(_ draft: AccountDraft) -> Bool {
    !draft.isNew && (txnCounts[draft.id] ?? 0) > 0
  }

  public var inspectorTitle: String {
    if let groupDraft {
      if groupDraft.isNew { return groupDraft.name.isEmpty ? "New group" : groupDraft.name }
      return selectedGroup?.name ?? groupDraft.name
    }
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

  /// What is wrong with the open form, or nil when it can be saved.
  public var validationMessage: String? {
    if let groupDraft { return validationMessage(groupDraft) }
    return draft.flatMap(validationMessage)
  }

  public func validationMessage(_ draft: AccountDraft) -> String? {
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
    if format.parseAmount(draft.openingBalance) == nil { return "The opening balance is not a number." }
    // C29: a Debt (person) account is always in a debt.
    if offersDebts, draft.kind == .debt, draft.debt == .none {
      return "Choose or create the debt for a Debt (person) account."
    }
    return debtValidation(draft)
  }

  public func validationMessage(_ draft: AccountGroupDraft) -> String? {
    draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name." : nil
  }

  public var isDirty: Bool {
    if let groupDraft { return isDirty(groupDraft) }
    return draft.map(isDirty) ?? false
  }

  public func isDirty(_ draft: AccountDraft) -> Bool {
    if draft.isNew { return true }
    guard let account = account(draft.id) else { return false }
    return built(from: draft, base: account) != account || debtChanged(draft)
  }

  public func isDirty(_ draft: AccountGroupDraft) -> Bool {
    if draft.isNew { return true }
    guard let group = group(draft.id) else { return false }
    return builtGroup(from: draft, base: group) != group
  }

  public var canSave: Bool { isDirty && validationMessage == nil }

  public func canSave(_ draft: AccountDraft) -> Bool { isDirty(draft) && validationMessage(draft) == nil }

  public func canSave(_ draft: AccountGroupDraft) -> Bool { isDirty(draft) && validationMessage(draft) == nil }

  /// After every group and top-level account (or last in a group): positions only order
  /// siblings, so one more than any position is last wherever the account lands.
  private var nextPosition: Int {
    ((accounts.map(\.position) + groups.map(\.position)).max() ?? -1) + 1
  }

  private func built(from draft: AccountDraft, base: Account?) -> Account? {
    guard let opening = format.parseAmount(draft.openingBalance) else { return nil }
    let iban = draft.iban.trimmingCharacters(in: .whitespaces)
    var account =
      base
      ?? Account(
        id: draft.id, name: "", currency: draft.currency, kind: draft.kind, openingDate: draft.openingDate,
        position: nextPosition)
    account.name = draft.name.trimmingCharacters(in: .whitespaces)
    account.kind = draft.kind
    account.currency = draft.currency
    account.openingBalanceMinor = opening
    account.openingDate = draft.openingDate
    account.groupID = draft.groupID
    account.iban = iban.isEmpty ? nil : iban
    account.colorHex = draft.colorHex
    return account
  }

  /// Saves the open form: the account (R-ACC-1) or the group (R-MGMT-9). True when it was saved.
  @discardableResult
  public func save() async -> Bool {
    if groupDraft != nil {
      return await saveGroup()
    }
    guard let draft, canSave else { return false }
    let base = draft.isNew ? nil : account(draft.id)
    guard var account = built(from: draft, base: base) else { return false }
    if isCurrencyLocked, let base { account.currency = base.currency }
    // Moved to another group (or out of one): last there.
    if let base, base.groupID != account.groupID { account.position = nextPosition }
    do {
      try await dependencies.accounts.save(account)
      try await applyDebt(draft.debt, role: debtRole(draft), to: account.id)
      await onDataChange?()
      selection = account.id
      self.draft = nil
      await load()
      self.draft = self.account(account.id).map { makeDraft($0) }
      return true
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the account")
      return false
    }
  }

  /// Drops the form's edits (a new account's or group's form closes).
  public func revert() {
    if draft?.isNew == true || groupDraft?.isNew == true {
      select(firstAccountID)
    } else {
      select(selection)
    }
  }

  // MARK: Group inspector (R-MGMT-9)

  static func groupDraft(_ group: AccountGroup) -> AccountGroupDraft {
    AccountGroupDraft(id: group.id, isNew: false, name: group.name, colorHex: group.colorHex)
  }

  public var selectedGroup: AccountGroup? { selection.flatMap(group) }

  /// "New group": an empty form; the group goes last at the top level.
  public func newGroup() {
    selectionBeforeNew = selection ?? selectionBeforeNew
    selection = nil
    errorMessage = nil
    draft = nil
    let draft = AccountGroupDraft(id: UUID(), isNew: true, name: "", colorHex: nil)
    groupDraft = draft
    sheet = .group(draft)
  }

  private func builtGroup(from draft: AccountGroupDraft, base: AccountGroup?) -> AccountGroup {
    var group = base ?? AccountGroup(id: draft.id, name: "", position: nextPosition)
    group.name = draft.name.trimmingCharacters(in: .whitespaces)
    group.colorHex = draft.colorHex
    return group
  }

  /// The selected group's accounts (archived too), for the inspector.
  public var selectedGroupSummary: String? {
    guard let group = selectedGroup else { return nil }
    let members = accounts.filter { $0.groupID == group.id }
    let active = members.filter { !$0.isArchived }.count
    let archived = members.count - active
    var text = active == 1 ? "1 account" : "\(active) accounts"
    if archived > 0 { text += " (+\(archived) archived)" }
    return text
  }

  /// The selected group's sum in the display currency (R-MGMT-9).
  public var selectedGroupSumText: String? {
    guard let group = selectedGroup else { return nil }
    return groupSum(group.id).map { format.money($0) } ?? "—"
  }

  private func saveGroup() async -> Bool {
    guard let groupDraft, canSave else { return false }
    let group = builtGroup(from: groupDraft, base: groupDraft.isNew ? nil : self.group(groupDraft.id))
    do {
      try await dependencies.accounts.saveGroup(group)
      await onDataChange?()
      selection = group.id
      self.groupDraft = nil
      await load()
      self.groupDraft = self.group(group.id).map(Self.groupDraft)
      return true
    } catch {
      errorMessage = ManageFailure.message(error, doing: "save the group")
      return false
    }
  }

  /// Delete… a group: after a confirmation; its accounts move to the top level.
  public func requestDeleteGroup() {
    guard let group = selectedGroup else { return }
    let count = accounts.filter { $0.groupID == group.id }.count
    let message =
      count == 0
      ? "It has no accounts."
      : "Its \(count == 1 ? "account moves" : "\(count) accounts move") to the top level; no account or transaction is deleted."
    dialog = ManageDialog(
      action: .deleteAccountGroup(group.id), title: "Delete group “\(group.name)”?", message: message,
      confirmTitle: "Delete group", isDestructive: true)
  }

  // MARK: Drag and drop (R-MGMT-9)

  /// Whether `moving` (an account or a group) may be dropped there.
  public func canDrop(_ moving: UUID, on target: UUID?, position: AccountDropPosition) -> Bool {
    // Asked on every mouse move of a drag: answered once per proposal until the data changes (S1).
    let key = DropCheck(moving: moving, target: target, position: position)
    if let known = dropChecks[key] { return known }
    let allowed =
      newGroupDrop(moving, on: target, position: position) != nil || plan(moving, on: target, position: position) != nil
    dropChecks[key] = allowed
    return allowed
  }

  /// A multi-selection drag (C27): what is really moved, in list order. A group carries its own
  /// accounts, so selected accounts of a selected group are left out (nothing is moved twice or
  /// taken out of its group); unknown ids are dropped.
  public func draggedItems(_ ids: [UUID]) -> [UUID] {
    let wanted = Set(ids)
    let carried = Set(groups.map(\.id)).intersection(wanted)
    return ordered.compactMap { item -> UUID? in
      guard wanted.contains(item.id) else { return nil }
      if case .account(let account) = item, let group = account.groupID, carried.contains(group) { return nil }
      return item.id
    }
  }

  /// Whether the whole selection may be dropped there (C27). All or nothing: one item that
  /// can't go there (a group into a group, a row onto itself, a group onto an account…) refuses
  /// the drop, which the outline shows as the no-drop cursor before release. Accounts already
  /// in the target group are skipped, as long as one account really moves.
  public func canDrop(_ moving: [UUID], on target: UUID?, position: AccountDropPosition) -> Bool {
    let items = draggedItems(moving)
    guard !items.isEmpty else { return false }
    if items.count == 1 { return canDrop(items[0], on: target, position: position) }
    if let pair = newGroupDrop(items, on: target, position: position) { return !pair.moving.isEmpty }
    var moves = 0
    for id in items {
      if isNoopJoin(id, on: target, position: position) { continue }
      guard canDrop(id, on: target, position: position) else { return false }
      moves += 1
    }
    return moves > 0
  }

  private struct DropCheck: Hashable {
    let moving: UUID
    let target: UUID?
    let position: AccountDropPosition
  }

  /// `canDrop` answers for the current accounts, groups and sort.
  @ObservationIgnored private var dropChecks: [DropCheck: Bool] = [:]

  /// After a drop: only names, groups and positions changed, so the accounts and groups are
  /// re-read without the transactions (balances and counts stay) (S1).
  private func reloadOrder() async {
    guard phase == .loaded,
      let accounts = try? await dependencies.accounts.accounts(includeArchived: true),
      let groups = try? await dependencies.accounts.groups()
    else { return await load() }
    self.accounts = accounts
    self.groups = groups
    dropChecks = [:]
  }

  /// An account in a group that still exists.
  private func isGrouped(_ account: Account) -> Bool {
    account.groupID.map { id in groups.contains { $0.id == id } } ?? false
  }

  /// `.onto` an ungrouped account (D55): the two accounts that go into a new group.
  private func newGroupDrop(_ movingID: UUID, on targetID: UUID?, position: AccountDropPosition)
    -> (moving: Account, target: Account)?
  {
    guard position == .onto, let targetID, movingID != targetID, let moving = account(movingID),
      let target = account(targetID), !isGrouped(target)
    else { return nil }
    return (moving, target)
  }

  /// `.onto` an ungrouped account with several dragged accounts (C27): they join the target in
  /// the new group. A group, or the target itself, among them refuses the drop.
  private func newGroupDrop(_ ids: [UUID], on targetID: UUID?, position: AccountDropPosition)
    -> (moving: [Account], target: Account)?
  {
    guard position == .onto, let targetID, let target = account(targetID), !isGrouped(target) else { return nil }
    let moving = ids.compactMap { account($0) }
    guard moving.count == ids.count, !ids.contains(targetID) else { return nil }
    return (moving, target)
  }

  /// `.onto` a group (or an account in it) for an account that is already there.
  private func isNoopJoin(_ id: UUID, on targetID: UUID?, position: AccountDropPosition) -> Bool {
    guard position == .onto, let targetID, let moving = account(id), let groupID = moving.groupID,
      isGrouped(moving)
    else { return false }
    return targetID == groupID || account(targetID)?.groupID == groupID
  }

  /// The new group's suggested name: the target's first word ("PKO Personal" → "PKO").
  public static func suggestedGroupName(for account: Account) -> String {
    let name = account.name.trimmingCharacters(in: .whitespaces)
    return name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
  }

  /// Applies a drop (like Reminders):
  /// - `.onto` a group (or an account in it): an account moves into that group, last; the sort
  ///   stays. Groups never nest (one level).
  /// - `.before` / `.after` a row: a reorder in what the page shows, so the sort becomes
  ///   "Custom order". Between top-level rows → top level (out of its group); next to an
  ///   account in a group → into that group there; right below a group whose accounts follow →
  ///   its first account.
  /// - `target` nil (the space below the list): top level, last.
  /// - `.onto` an ungrouped account (D55): asks for a name first (`groupPrompt`);
  ///   `confirmGroupPrompt(name:)` then creates a group in the target's place holding both.
  /// Balances and transactions never change. A group left empty by a move stays (a folder the
  /// user deletes, D48).
  public func drop(_ moving: UUID, on target: UUID?, position: AccountDropPosition) async {
    await drop([moving], on: target, position: position)
  }

  /// Applies a multi-selection drop (C27) with the same rules for every dragged row, in list
  /// order (after a row: they land in that order too). A refused drop (see `canDrop`) changes
  /// nothing. Onto an ungrouped account: one prompt, one group holding the target and all of
  /// them.
  public func drop(_ moving: [UUID], on target: UUID?, position: AccountDropPosition) async {
    guard canDrop(moving, on: target, position: position) else { return }
    let items = draggedItems(moving)
    if let pair = newGroupDrop(items, on: target, position: position) {
      groupPrompt = AccountGroupPrompt(
        id: UUID(), moving: pair.moving[0].id, alsoMoving: pair.moving.dropFirst().map(\.id), target: pair.target.id,
        defaultName: Self.suggestedGroupName(for: pair.target))
      return
    }
    // "After a row": last item first, so each one lands right below the row.
    let sequence = position == .after ? Array(items.reversed()) : items
    var changed = false
    var sorted = false
    do {
      for id in sequence where !isNoopJoin(id, on: target, position: position) {
        guard let plan = plan(id, on: target, position: position) else { continue }
        if plan.reorders, !sorted {
          sorted = true
          await setSort(.custom)
        }
        for group in plan.groups { try await dependencies.accounts.saveGroup(group) }
        for account in plan.accounts { try await dependencies.accounts.save(account) }
        if !plan.accounts.isEmpty || !plan.groups.isEmpty { changed = true }
        await reloadOrder()
      }
      if changed { await onDataChange?() }
    } catch {
      errorMessage = ManageFailure.message(error, doing: "move the account")
      await load()
    }
  }

  /// Creates the prompted group (D55): it takes the target account's place at the top level and
  /// holds the target, then the dragged account. The sort stays. Nothing happens with an empty
  /// name; nothing changes when either account is gone or the target joined a group meanwhile.
  public func confirmGroupPrompt(name: String) async {
    guard let prompt = groupPrompt else { return }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    groupPrompt = nil
    let movers = prompt.allMoving.compactMap { account($0) }
    guard !prompt.allMoving.contains(prompt.target), movers.count == prompt.allMoving.count,
      var target = account(prompt.target), !isGrouped(target)
    else { return }
    let group = AccountGroup(id: UUID(), name: trimmed, position: target.position)
    target.groupID = group.id
    target.position = 0
    do {
      try await dependencies.accounts.saveGroup(group)
      try await dependencies.accounts.save(target)
      for (index, var moving) in movers.enumerated() {
        moving.groupID = group.id
        moving.position = index + 1
        try await dependencies.accounts.save(moving)
      }
      await onDataChange?()
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "create the group")
      await load()
    }
  }

  /// The name prompt's Cancel: nothing moves.
  public func cancelGroupPrompt() { groupPrompt = nil }

  private struct DropPlan {
    var accounts: [Account]
    var groups: [AccountGroup]
    var reorders: Bool
  }

  private func plan(_ movingID: UUID, on targetID: UUID?, position: AccountDropPosition) -> DropPlan? {
    let current = ordered
    let groupIDs = Set(groups.map(\.id))
    func parent(_ item: AccountTreeItem) -> AccountGroup.ID? {
      guard case .account(let account) = item, let id = account.groupID, groupIDs.contains(id) else { return nil }
      return id
    }
    guard movingID != targetID, let moving = current.first(where: { $0.id == movingID }) else { return nil }
    let target = targetID.flatMap { id in current.first { $0.id == id } }
    if targetID != nil, target == nil { return nil }
    let movingIsGroup: Bool
    if case .group = moving { movingIsGroup = true } else { movingIsGroup = false }

    if position == .onto {
      guard case .account(var account) = moving, let target else { return nil }
      let groupID: AccountGroup.ID
      switch target {
      case .group(let group): groupID = group.id
      case .account:
        guard let id = parent(target) else { return nil }
        groupID = id
      }
      // Already in that group: nothing to do (between rows reorders inside it).
      guard account.groupID != groupID else { return nil }
      let siblings = accounts.filter { $0.groupID == groupID && $0.id != account.id }
      account.groupID = groupID
      account.position = (siblings.map(\.position).max() ?? -1) + 1
      return DropPlan(accounts: [account], groups: [], reorders: false)
    }

    // Reorder: blocks of the order shown (group + its accounts, or a top-level account).
    var blocks: [[AccountTreeItem]] = []
    for item in current {
      if parent(item) != nil, !blocks.isEmpty { blocks[blocks.count - 1].append(item) } else { blocks.append([item]) }
    }
    var movingBlock: [AccountTreeItem] = [moving]
    if let index = blocks.firstIndex(where: { $0[0].id == movingID }) {
      movingBlock = blocks.remove(at: index)
    } else {
      for index in blocks.indices { blocks[index].removeAll { $0.id == movingID } }
    }
    func withGroup(_ groupID: AccountGroup.ID?) -> AccountTreeItem {
      guard case .account(var account) = moving else { return moving }
      account.groupID = groupID
      return .account(account)
    }

    if let target {
      if let groupID = parent(target) {
        // Next to an account in a group: into that group, there.
        guard !movingIsGroup,
          let block = blocks.firstIndex(where: { $0.contains { $0.id == target.id } }),
          let at = blocks[block].firstIndex(where: { $0.id == target.id })
        else { return nil }
        blocks[block].insert(withGroup(groupID), at: position == .before ? at : at + 1)
      } else {
        guard let block = blocks.firstIndex(where: { $0[0].id == target.id }) else { return nil }
        if position == .after, case .group(let group) = target, blocks[block].count > 1, !movingIsGroup {
          // Right below a group whose accounts follow: its first account.
          blocks[block].insert(withGroup(group.id), at: 1)
        } else {
          movingBlock[0] = withGroup(nil)
          blocks.insert(movingBlock, at: position == .before ? block : block + 1)
        }
      }
    } else {
      movingBlock[0] = withGroup(nil)
      blocks.append(movingBlock)
    }

    var changedAccounts: [Account] = []
    var changedGroups: [AccountGroup] = []
    for (index, item) in blocks.flatMap({ $0 }).enumerated() {
      switch item {
      case .group(var group):
        group.position = index
        if group != self.group(group.id) { changedGroups.append(group) }
      case .account(var account):
        account.position = index
        if account != self.account(account.id) {
          if account.id == movingID { changedAccounts.insert(account, at: 0) } else { changedAccounts.append(account) }
        }
      }
    }
    return DropPlan(accounts: changedAccounts, groups: changedGroups, reorders: true)
  }

  // MARK: Archive and delete

  /// Archive… asks first. A zero balance: the one-line confirmation. A balance that is not zero
  /// (R-ACC-4, C29): the archive sheet with the balance and one checkbox (compensation
  /// transaction, or "Forgive the debt" for an account in a debt). Unarchive is direct.
  public func archiveOrUnarchive() async {
    guard let account = selectedAccount else { return }
    if account.isArchived {
      await setArchived(account.id, false)
      return
    }
    let balance = balance(account)
    if balance.minorUnits == 0 {
      dialog = ManageDialog(
        action: .archiveAccount(account.id), title: "Archive “\(account.name)”?",
        message: "It will be hidden from pickers and the dashboard. Its history stays.",
        confirmTitle: "Archive", isDestructive: false)
      return
    }
    let debt = linkedDebt(of: account.id)
    archiveSheet = AccountArchiveSheet(
      id: account.id, accountName: account.name, balance: balance, balanceText: format.money(balance),
      debtID: debt?.id, debtName: debt?.personName)
  }

  public func setCreateCompensation(_ on: Bool) { archiveSheet?.createCompensation = on }
  public func setForgiveDebt(_ on: Bool) { archiveSheet?.forgiveDebt = on }
  public func setCountAsExpense(_ on: Bool) { archiveSheet?.countAsExpense = on }

  public func cancelArchiveSheet() { archiveSheet = nil }

  /// What the compensation checkbox will book: "Books an expense of zł120.00 on this account today,
  /// category “Balance correction”. Reports and budgets ignore it."
  public func compensationHint(_ sheet: AccountArchiveSheet) -> String {
    let kind = sheet.balance.minorUnits < 0 ? "an income" : "an expense"
    let amount = format.money(Money(minorUnits: abs(sheet.balance.minorUnits), currency: sheet.balance.currency))
    return "Books \(kind) of \(amount) on this account today (category “\(Self.correctionCategoryName)”), so "
      + "the balance becomes 0. Reports, budgets and charts do not count it."
  }

  /// "Forgive the debt (€120.00)".
  public func forgiveTitle(_ sheet: AccountArchiveSheet) -> String {
    let amount = format.money(Money(minorUnits: abs(sheet.balance.minorUnits), currency: sheet.balance.currency))
    return "Forgive the debt (\(amount) \(sheet.balance.currency.rawValue))"
  }

  public func forgiveHint(_ sheet: AccountArchiveSheet) -> String {
    let who = sheet.debtName.map { "“\($0)”" } ?? "the debt"
    return "Adds a “Forgive” record to \(who) in \(sheet.balance.currency.rawValue) that closes this account's balance. "
      + "The archived account stays linked and keeps counting in the debt."
  }

  /// The category of the compensation transaction (R-ACC-4).
  public static let correctionCategoryName = "Balance correction"

  /// The note of the compensation transaction.
  public static let correctionNote = "Zeroes the account on archiving."

  /// Archive on the sheet's Archive button (R-ACC-4, C29): optionally the compensation
  /// transaction (account outside a debt) or the forgive record (account in a debt), then the
  /// archive. The account's balance is read again now; when it became zero meanwhile only the
  /// archive remains.
  public func confirmArchive() async {
    guard let sheet = archiveSheet else { return }
    archiveSheet = nil
    guard let account = account(sheet.id) else { return }
    let balance = balance(account)
    do {
      if balance.minorUnits != 0 {
        if sheet.isLinkedToDebt, sheet.forgiveDebt, let debtID = sheet.debtID {
          try await forgive(balance, of: account, in: debtID, countAsExpense: sheet.countAsExpense)
        } else if !sheet.isLinkedToDebt, sheet.createCompensation {
          try await compensate(balance, on: account)
        }
      }
      try await dependencies.accounts.setArchived(account.id, true)
      self.sheet = nil
      showArchived = true
      await onDataChange?()
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: "archive the account")
      await load()
    }
  }

  /// One transaction that zeroes the account: income when the balance is negative, expense when
  /// positive, |balance| in the account currency, today, category "Balance correction", flagged so
  /// no report counts it (R-ACC-4).
  private func compensate(_ balance: Money, on account: Account) async throws {
    let kind: CategoryKind = balance.minorUnits < 0 ? .income : .expense
    let category = try await correctionCategory(kind)
    let txn = Txn(
      type: kind == .income ? .income : .expense,
      occurredAt: dependencies.today().date(calendar: format.calendar), accountID: account.id,
      amountMinor: abs(balance.minorUnits), categoryID: category.id, payee: Self.correctionCategoryName,
      note: Self.correctionNote, source: .manual, isBalanceCorrection: true)
    try await dependencies.txns.save(txn, lines: [])
  }

  /// The "Balance correction" category of `kind`: an existing one (a live one first), else created.
  private func correctionCategory(_ kind: CategoryKind) async throws -> AbacusDomain.Category {
    let all = try await dependencies.categories.categories(kind: kind, includeArchived: true)
    let named = all.filter { $0.parentID == nil && $0.name.caseInsensitiveCompare(Self.correctionCategoryName) == .orderedSame }
    if let found = named.first(where: { !$0.isArchived }) ?? named.first { return found }
    let created = AbacusDomain.Category(
      name: Self.correctionCategoryName, kind: kind, colorHex: ColorPalette.pick(avoiding: all.map(\.colorHex)),
      position: (all.map(\.position).max() ?? -1) + 1)
    try await dependencies.categories.save(created)
    return created
  }

  /// A manual forgive record on the debt in the account's currency that closes this account's
  /// balance: positive (they owe me) = "Forgave", counted as an expense when asked (R-DEBT-4);
  /// negative (I owe them) = "Forgiven by them", no report flag.
  private func forgive(_ balance: Money, of account: Account, in debtID: Debt.ID, countAsExpense: Bool) async throws {
    guard let repository = dependencies.debts else { return }
    let owedToMe = balance.minorUnits > 0
    let record = DebtRecord(
      debtID: debtID, kind: owedToMe ? .forgaveThem : .forgivenByThem, day: dependencies.today().string,
      amountMinor: abs(balance.minorUnits), currency: balance.currency,
      note: "Forgiven when “\(account.name)” was archived.", reportKind: owedToMe && countAsExpense ? .expense : nil)
    try await repository.save(record)
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
      sheet = nil
      await setArchived(id, true)
      // The archived account stays visible and selected (prototype).
      showArchived = true
    case .deleteAccount(let id):
      do {
        try await dependencies.accounts.delete(id)
        sheet = nil
        await onDataChange?()
        selection = nil
        draft = nil
        await load()
      } catch {
        errorMessage = ManageFailure.message(error, doing: "delete the account")
      }
    case .deleteAccountGroup(let id):
      do {
        try await dependencies.accounts.deleteGroup(id)
        sheet = nil
        await onDataChange?()
        selection = nil
        groupDraft = nil
        await load()
      } catch {
        errorMessage = ManageFailure.message(error, doing: "delete the group")
      }
    default:
      break
    }
  }

  private func setArchived(_ id: Account.ID, _ archived: Bool) async {
    do {
      try await dependencies.accounts.setArchived(id, archived)
      await onDataChange?()
      await load()
    } catch {
      errorMessage = ManageFailure.message(error, doing: archived ? "archive the account" : "unarchive the account")
    }
  }
}
