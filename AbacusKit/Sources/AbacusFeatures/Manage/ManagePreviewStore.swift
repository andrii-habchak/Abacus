import AbacusDomain
import Foundation
import Synchronization

/// In-memory fakes of every repository the management screens use, for previews, screenshots
/// and tests until the store is wired. They follow the A5 store's rules where the screens rely
/// on them: an account with transactions cannot be deleted (R-ACC-5), deleting a used category
/// needs a same-kind target and moves its transactions, attached records, budget limits and
/// rules there (R-CAT-3), deleting an event clears it from its transactions, a budget saved for
/// a month replaces that month's plan only (R-BUD-3, D29).
public final class ManagePreviewStore: Sendable {
  struct State: Sendable {
    var accounts: [Account]
    var groups: [AccountGroup]
    var categories: [AbacusDomain.Category]
    var events: [Event]
    var txns: [TxnWithLines]
    var plans: [BudgetPlan]
    var allocations: [BudgetAllocation]
    var rules: [CategoryRule]
    var ruleApplications: [RuleApplication] = []
    var settings: [String: String]
  }

  let state: Mutex<State>

  public init(
    accounts: [Account], categories: [AbacusDomain.Category], events: [Event] = [], txns: [Txn] = [],
    attachedRecords: [AttachedRecord] = [], plans: [BudgetPlan] = [], allocations: [BudgetAllocation] = [],
    rules: [CategoryRule] = [], settings: [AppSetting] = [], groups: [AccountGroup] = []
  ) {
    let lines = Dictionary(grouping: attachedRecords, by: \.txnID)
    state = Mutex(State(
      accounts: accounts, groups: groups, categories: categories, events: events,
      txns: txns.map { TxnWithLines(txn: $0, lines: (lines[$0.id] ?? []).sorted { $0.position < $1.position }) },
      plans: plans, allocations: allocations, rules: rules,
      settings: Dictionary(settings.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })))
  }

  /// `PreviewData` exactly (it has no rules).
  public static func previewData() -> ManagePreviewStore {
    ManagePreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, events: PreviewData.events,
      txns: PreviewData.txns, attachedRecords: PreviewData.attachedRecords, plans: [PreviewData.budgetPlan],
      allocations: PreviewData.budgetAllocations, settings: PreviewData.settings,
      groups: PreviewData.accountGroups)
  }

  /// `PreviewData` plus what the prototype shows and `PreviewData` lacks: categorisation rules,
  /// a budget on the Lyon trip and an ongoing "Car" event (`ManageSample`).
  public static func sample() -> ManagePreviewStore {
    ManagePreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, events: ManageSample.events,
      txns: PreviewData.txns + ManageSample.extraTxns, attachedRecords: PreviewData.attachedRecords,
      plans: [PreviewData.budgetPlan], allocations: PreviewData.budgetAllocations, rules: ManageSample.rules,
      settings: PreviewData.settings, groups: PreviewData.accountGroups)
  }

  public var accountRepository: Accounts { Accounts(store: self) }
  public var categoryRepository: Categories { Categories(store: self) }
  public var txnRepository: Txns { Txns(store: self) }
  public var budgetRepository: Budget { Budget(store: self) }
  public var eventRepository: Events { Events(store: self) }
  public var ruleRepository: Rules { Rules(store: self) }
  public var settingsRepository: Settings { Settings(store: self) }

  // MARK: Accounts

  public struct Accounts: AccountRepository {
    let store: ManagePreviewStore

    public func accounts(includeArchived: Bool) async throws -> [Account] {
      store.state.withLock { state in
        state.accounts.filter { includeArchived || !$0.isArchived }.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
      }
    }

    public func save(_ account: Account) async throws {
      store.state.withLock { state in
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
          state.accounts[index] = account
        } else {
          state.accounts.append(account)
        }
      }
    }

    public func setArchived(_ id: Account.ID, _ isArchived: Bool) async throws {
      try store.state.withLock { state in
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.accounts[index].isArchived = isArchived
      }
    }

    public func delete(_ id: Account.ID) async throws {
      try store.state.withLock { state in
        guard state.accounts.contains(where: { $0.id == id }) else { throw RepositoryError.notFound }
        if state.txns.contains(where: { $0.txn.accountID == id || $0.txn.toAccountID == id }) {
          throw RepositoryError.accountHasTransactions
        }
        state.accounts.removeAll { $0.id == id }
        state.rules.removeAll { $0.accountID == id || $0.transferAccountID == id }
      }
    }

    public func groups() async throws -> [AccountGroup] {
      store.state.withLock { state in
        state.groups.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
      }
    }

    public func saveGroup(_ group: AccountGroup) async throws {
      store.state.withLock { state in
        if let index = state.groups.firstIndex(where: { $0.id == group.id }) {
          state.groups[index] = group
        } else {
          state.groups.append(group)
        }
      }
    }

    public func deleteGroup(_ id: AccountGroup.ID) async throws {
      try store.state.withLock { state in
        guard state.groups.contains(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.groups.removeAll { $0.id == id }
        for index in state.accounts.indices where state.accounts[index].groupID == id {
          state.accounts[index].groupID = nil
        }
      }
    }
  }

  // MARK: Categories

  public struct Categories: CategoryRepository {
    let store: ManagePreviewStore

    public func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [AbacusDomain.Category] {
      store.state.withLock { state in
        state.categories
          .filter { (kind == nil || $0.kind == kind) && (includeArchived || !$0.isArchived) }
          .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
      }
    }

    public func save(_ category: AbacusDomain.Category) async throws {
      try store.state.withLock { state in
        if let parentID = category.parentID {
          guard parentID != category.id, !state.categories.contains(where: { $0.parentID == category.id }),
            let parent = state.categories.first(where: { $0.id == parentID }), parent.parentID == nil
          else { throw ManageError.invalidParent }
          guard parent.kind == category.kind else { throw RepositoryError.kindMismatch }
        }
        if let index = state.categories.firstIndex(where: { $0.id == category.id }) {
          state.categories[index] = category
        } else {
          state.categories.append(category)
        }
      }
    }

    public func setArchived(_ id: AbacusDomain.Category.ID, _ isArchived: Bool) async throws {
      try store.state.withLock { state in
        guard let index = state.categories.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.categories[index].isArchived = isArchived
        if isArchived {
          for child in state.categories.indices where state.categories[child].parentID == id {
            state.categories[child].isArchived = true
          }
        } else if let parentID = state.categories[index].parentID,
          let parent = state.categories.firstIndex(where: { $0.id == parentID })
        {
          state.categories[parent].isArchived = false
        }
      }
    }

    public func delete(_ id: AbacusDomain.Category.ID, reassignTo: AbacusDomain.Category.ID?) async throws {
      try store.state.withLock { state in
        guard let category = state.categories.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
        let target = reassignTo == id ? nil : reassignTo
        let inUse =
          state.txns.contains { $0.txn.categoryID == id || $0.lines.contains { $0.categoryID == id } }
          || state.allocations.contains { $0.categoryID == id }
        if let target {
          guard let targetCategory = state.categories.first(where: { $0.id == target }) else {
            throw RepositoryError.notFound
          }
          guard targetCategory.kind == category.kind else { throw RepositoryError.kindMismatch }
        } else if inUse {
          throw RepositoryError.categoryInUse
        }
        for index in state.categories.indices where state.categories[index].parentID == id {
          state.categories[index].parentID = nil
        }
        if let target {
          for index in state.txns.indices {
            if state.txns[index].txn.categoryID == id { state.txns[index].txn.categoryID = target }
            for line in state.txns[index].lines.indices where state.txns[index].lines[line].categoryID == id {
              state.txns[index].lines[line].categoryID = target
            }
          }
          for index in state.rules.indices where state.rules[index].categoryID == id {
            state.rules[index].categoryID = target
          }
          // A plan holds at most one allocation per category: add the limits up when they share a
          // currency, else the target keeps its own (as the store does).
          for moving in state.allocations.filter({ $0.categoryID == id }) {
            if let existing = state.allocations.firstIndex(where: { $0.planID == moving.planID && $0.categoryID == target }) {
              if state.allocations[existing].currency == moving.currency {
                state.allocations[existing].limitMinor += moving.limitMinor
              }
              state.allocations.removeAll { $0.id == moving.id }
            } else if let index = state.allocations.firstIndex(where: { $0.id == moving.id }) {
              state.allocations[index].categoryID = target
            }
          }
        } else {
          state.rules.removeAll { $0.categoryID == id }
        }
        state.categories.removeAll { $0.id == id }
      }
    }

    private static func sources(_ id: AbacusDomain.Category.ID, _ state: State) -> Set<AbacusDomain.Category.ID> {
      Set([id] + state.categories.filter { $0.parentID == id }.map(\.id))
    }

    private static func impact(_ ids: Set<AbacusDomain.Category.ID>, _ state: State) -> CategoryReassignImpact {
      CategoryReassignImpact(
        transactions: state.txns.filter { $0.txn.categoryID.map(ids.contains) ?? false }.count,
        attachedRecords: state.txns.flatMap(\.lines).filter { $0.categoryID.map(ids.contains) ?? false }.count,
        rules: state.rules.filter { $0.categoryID.map(ids.contains) ?? false }.count,
        budgetLimits: state.allocations.filter { ids.contains($0.categoryID) }.count)
    }

    public func reassignImpact(of id: AbacusDomain.Category.ID) async throws -> CategoryReassignImpact {
      try store.state.withLock { state in
        guard state.categories.contains(where: { $0.id == id }) else { throw RepositoryError.notFound }
        return Self.impact(Self.sources(id, state), state)
      }
    }

    public func reassign(
      from id: AbacusDomain.Category.ID, to target: AbacusDomain.Category.ID?, repointRules: Bool, archiveAfterwards: Bool
    ) async throws -> CategoryReassignImpact {
      try store.state.withLock { state in
        guard let source = state.categories.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
        if let target {
          guard let targetCategory = state.categories.first(where: { $0.id == target }) else { throw RepositoryError.notFound }
          guard targetCategory.kind == source.kind else { throw RepositoryError.kindMismatch }
        }
        let ids = Self.sources(id, state)
        if let target { guard !ids.contains(target) else { throw RepositoryError.invalidReassignTarget } }
        var moved = Self.impact(ids, state)
        for index in state.txns.indices {
          if let current = state.txns[index].txn.categoryID, ids.contains(current) { state.txns[index].txn.categoryID = target }
          for line in state.txns[index].lines.indices {
            if let current = state.txns[index].lines[line].categoryID, ids.contains(current) {
              state.txns[index].lines[line].categoryID = target
            }
          }
        }
        if repointRules, let target {
          for index in state.rules.indices {
            if let current = state.rules[index].categoryID, ids.contains(current) { state.rules[index].categoryID = target }
          }
        } else {
          moved.rules = 0
        }
        if archiveAfterwards {
          for index in state.categories.indices where ids.contains(state.categories[index].id) {
            state.categories[index].isArchived = true
          }
        }
        return moved
      }
    }
  }

  // MARK: Transactions

  public struct Txns: TxnRepository {
    let store: ManagePreviewStore

    public func transactions(matching query: TxnQuery) async throws -> [TxnWithLines] {
      store.state.withLock { state in
        TransactionQueryMatcher(query: query, categories: state.categories).apply(state.txns)
      }
    }

    public func save(_ txn: Txn, lines: [AttachedRecord]) async throws {
      store.state.withLock { state in
        state.txns.removeAll { $0.txn.id == txn.id }
        state.txns.append(TxnWithLines(txn: txn, lines: lines))
      }
    }

    public func delete(_ id: Txn.ID) async throws {
      store.state.withLock { state in state.txns.removeAll { $0.txn.id == id } }
    }
  }

  // MARK: Budget

  public struct Budget: BudgetRepository {
    let store: ManagePreviewStore

    public func plan(for month: Month) async throws -> (plan: BudgetPlan, allocations: [BudgetAllocation])? {
      store.state.withLock { state in
        guard let plan = Calc.planInEffect(for: month, plans: state.plans) else { return nil }
        return (plan, state.allocations.filter { $0.planID == plan.id })
      }
    }

    public func save(_ plan: BudgetPlan, allocations: [BudgetAllocation]) async throws {
      store.state.withLock { state in
        let replaced = Set(state.plans.filter { $0.id == plan.id || $0.effectiveMonth == plan.effectiveMonth }.map(\.id))
        state.plans.removeAll { replaced.contains($0.id) }
        state.allocations.removeAll { replaced.contains($0.planID) }
        state.plans.append(plan)
        state.allocations += allocations.map {
          BudgetAllocation(
            id: $0.id, planID: plan.id, categoryID: $0.categoryID, limitMinor: $0.limitMinor, currency: $0.currency)
        }
      }
    }

    /// Every plan, oldest first (tests).
    public func plans() -> [BudgetPlan] {
      store.state.withLock { $0.plans.sorted { $0.effectiveMonth < $1.effectiveMonth } }
    }
  }

  // MARK: Events

  public struct Events: EventRepository {
    let store: ManagePreviewStore

    /// Newest first by start day; events without dates last, by name (as the store).
    public func events(includeArchived: Bool) async throws -> [Event] {
      store.state.withLock { state in
        state.events.filter { includeArchived || !$0.isArchived }.sorted { a, b in
          switch (a.startDay, b.startDay) {
          case (let x?, let y?): x != y ? x > y : a.name < b.name
          case (.some, nil): true
          case (nil, .some): false
          case (nil, nil): a.name < b.name
          }
        }
      }
    }

    public func save(_ event: Event) async throws {
      store.state.withLock { state in
        if let index = state.events.firstIndex(where: { $0.id == event.id }) {
          state.events[index] = event
        } else {
          state.events.append(event)
        }
      }
    }

    public func setArchived(_ id: Event.ID, _ isArchived: Bool) async throws {
      try store.state.withLock { state in
        guard let index = state.events.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.events[index].isArchived = isArchived
      }
    }

    public func delete(_ id: Event.ID) async throws {
      try store.state.withLock { state in
        guard state.events.contains(where: { $0.id == id }) else { throw RepositoryError.notFound }
        for index in state.txns.indices where state.txns[index].txn.eventID == id {
          state.txns[index].txn.eventID = nil
        }
        state.events.removeAll { $0.id == id }
      }
    }
  }

  // MARK: Rules

  public struct Rules: RuleRepository {
    let store: ManagePreviewStore

    /// In evaluation order: `position`, then the most used first (as the store).
    public func rules() async throws -> [CategoryRule] {
      store.state.withLock { state in
        state.rules.sorted { ($0.position, -$0.hitCount, $0.pattern) < ($1.position, -$1.hitCount, $1.pattern) }
      }
    }

    public func save(_ rule: CategoryRule) async throws {
      store.state.withLock { state in
        if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
          state.rules[index] = rule
        } else {
          state.rules.append(rule)
        }
      }
    }

    public func save(_ rule: CategoryRule?, updating txns: [Txn]) async throws {
      try store.state.withLock { state in
        let indices = try txns.map { txn in
          guard let index = state.txns.firstIndex(where: { $0.txn.id == txn.id }) else { throw RepositoryError.notFound }
          return index
        }
        for (index, txn) in zip(indices, txns) { state.txns[index].txn = txn }
        guard let rule else { return }
        if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
          state.rules[index] = rule
        } else {
          state.rules.append(rule)
        }
      }
    }

    public func apply(_ rule: CategoryRule, records: [RuleApplication]) async throws {
      try store.state.withLock { state in
        let indices = try records.map { record in
          guard let index = state.txns.firstIndex(where: { $0.txn.id == record.txnID }) else { throw RepositoryError.notFound }
          return index
        }
        for (index, record) in zip(indices, records) {
          state.txns[index].txn = record.after.applied(to: state.txns[index].txn)
        }
        if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
          state.rules[index] = rule
        } else {
          state.rules.append(rule)
        }
        state.ruleApplications.append(contentsOf: records)
      }
    }

    public func applications(of ruleID: CategoryRule.ID) async throws -> [RuleApplication] {
      store.state.withLock { state in
        state.ruleApplications.filter { $0.ruleID == ruleID }.sorted { $0.appliedAt > $1.appliedAt }
      }
    }

    /// As the store: newest first, only transactions still as the rule left them.
    public func rollBack(_ ruleID: CategoryRule.ID) async throws -> RuleRollback {
      store.state.withLock { state in
        var result = RuleRollback()
        let records = state.ruleApplications.enumerated().filter { $0.element.ruleID == ruleID }
          .sorted { ($0.element.appliedAt, $0.offset) > ($1.element.appliedAt, $1.offset) }.map(\.element)
        let categoryIDs = Set(state.categories.map(\.id))
        let accountIDs = Set(state.accounts.map(\.id))
        for record in records {
          guard let index = state.txns.firstIndex(where: { $0.txn.id == record.txnID }),
            let restored = record.restoring(state.txns[index].txn),
            restored.categoryID.map(categoryIDs.contains) ?? true, accountIDs.contains(restored.accountID),
            restored.toAccountID.map(accountIDs.contains) ?? true
          else {
            result.skipped += 1
            continue
          }
          state.txns[index].txn = restored
          result.restored += 1
        }
        state.ruleApplications.removeAll { $0.ruleID == ruleID }
        return result
      }
    }

    public func delete(_ id: CategoryRule.ID) async throws {
      try store.state.withLock { state in
        guard state.rules.contains(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.rules.removeAll { $0.id == id }
        state.ruleApplications.removeAll { $0.ruleID == id }
      }
    }

    public func recordHit(_ id: CategoryRule.ID) async throws {
      try store.state.withLock { state in
        guard let index = state.rules.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.rules[index].hitCount += 1
      }
    }
  }

  // MARK: Settings

  public struct Settings: SettingsRepository {
    let store: ManagePreviewStore

    public func value(_ key: SettingKey) async throws -> String? {
      store.state.withLock { $0.settings[key.rawValue] }
    }

    public func set(_ key: SettingKey, _ value: String) async throws {
      store.state.withLock { $0.settings[key.rawValue] = value }
    }
  }
}

/// Errors of the fakes that the store reports with its own `StoreError`.
public enum ManageError: Error, Equatable, Sendable {
  /// R-CAT-2: the parent must be a top-level category, and a category with children stays top level.
  case invalidParent
}
