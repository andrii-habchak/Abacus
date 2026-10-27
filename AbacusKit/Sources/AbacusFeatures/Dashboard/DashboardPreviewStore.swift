import AbacusDomain
import Foundation
import Synchronization

/// In-memory fakes of the repositories the dashboard reads, for previews and tests until the
/// store is wired. Writes work too, so a test can change the data and reload.
public final class DashboardPreviewStore: Sendable {
  struct State: Sendable {
    var accounts: [Account]
    var groups: [AccountGroup] = []
    var categories: [AbacusDomain.Category]
    var txns: [TxnWithLines]
    var plans: [BudgetPlan]
    var allocations: [BudgetAllocation]
    var settings: [String: String]
  }

  let state: Mutex<State>

  public init(
    accounts: [Account], categories: [AbacusDomain.Category], txns: [Txn], attachedRecords: [AttachedRecord] = [],
    plans: [BudgetPlan] = [], allocations: [BudgetAllocation] = [], settings: [AppSetting] = [],
    groups: [AccountGroup] = []
  ) {
    let lines = Dictionary(grouping: attachedRecords, by: \.txnID)
    state = Mutex(State(
      accounts: accounts, groups: groups, categories: categories,
      txns: txns.map { TxnWithLines(txn: $0, lines: (lines[$0.id] ?? []).sorted { $0.position < $1.position }) },
      plans: plans, allocations: allocations,
      settings: Dictionary(settings.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })))
  }

  /// Everything in `PreviewData`.
  public static func previewData() -> DashboardPreviewStore {
    DashboardPreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, txns: PreviewData.txns,
      attachedRecords: PreviewData.attachedRecords, plans: [PreviewData.budgetPlan],
      allocations: PreviewData.budgetAllocations, settings: PreviewData.settings,
      groups: PreviewData.accountGroups)
  }

  public var accountRepository: Accounts { Accounts(store: self) }
  public var categoryRepository: Categories { Categories(store: self) }
  public var txnRepository: Txns { Txns(store: self) }
  public var budgetRepository: Budget { Budget(store: self) }
  public var settingsRepository: Settings { Settings(store: self) }

  public struct Accounts: AccountRepository {
    let store: DashboardPreviewStore

    public func accounts(includeArchived: Bool) async throws -> [Account] {
      store.state.withLock { state in
        state.accounts.filter { includeArchived || !$0.isArchived }.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
      }
    }

    public func save(_ account: Account) async throws {
      store.state.withLock { state in
        state.accounts.removeAll { $0.id == account.id }
        state.accounts.append(account)
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
        if state.txns.contains(where: { $0.txn.accountID == id || $0.txn.toAccountID == id }) {
          throw RepositoryError.accountHasTransactions
        }
        state.accounts.removeAll { $0.id == id }
      }
    }

    public func groups() async throws -> [AccountGroup] {
      store.state.withLock { $0.groups }
    }
  }

  public struct Categories: CategoryRepository {
    let store: DashboardPreviewStore

    public func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [AbacusDomain.Category] {
      store.state.withLock { state in
        state.categories
          .filter { (kind == nil || $0.kind == kind) && (includeArchived || !$0.isArchived) }
          .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
      }
    }

    public func save(_ category: AbacusDomain.Category) async throws {
      store.state.withLock { state in
        state.categories.removeAll { $0.id == category.id }
        state.categories.append(category)
      }
    }

    public func setArchived(_ id: AbacusDomain.Category.ID, _ isArchived: Bool) async throws {
      try store.state.withLock { state in
        guard let index = state.categories.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
        state.categories[index].isArchived = isArchived
      }
    }

    public func delete(_ id: AbacusDomain.Category.ID, reassignTo: AbacusDomain.Category.ID?) async throws {
      try store.state.withLock { state in
        let used = state.txns.contains { item in
          item.txn.categoryID == id || item.lines.contains { $0.categoryID == id }
        }
        if used, reassignTo == nil { throw RepositoryError.categoryInUse }
        for index in state.txns.indices {
          if state.txns[index].txn.categoryID == id { state.txns[index].txn.categoryID = reassignTo }
          for line in state.txns[index].lines.indices where state.txns[index].lines[line].categoryID == id {
            state.txns[index].lines[line].categoryID = reassignTo
          }
        }
        for index in state.categories.indices where state.categories[index].parentID == id {
          state.categories[index].parentID = nil
        }
        state.categories.removeAll { $0.id == id }
      }
    }
  }

  public struct Txns: TxnRepository {
    let store: DashboardPreviewStore

    /// Every `TxnQuery` filter as the store applies it (`TransactionQueryMatcher`, R-LIST-2…6).
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

  public struct Budget: BudgetRepository {
    let store: DashboardPreviewStore

    public func plan(for month: Month) async throws -> (plan: BudgetPlan, allocations: [BudgetAllocation])? {
      store.state.withLock { state in
        guard let plan = Calc.planInEffect(for: month, plans: state.plans) else { return nil }
        return (plan, state.allocations.filter { $0.planID == plan.id })
      }
    }

    public func save(_ plan: BudgetPlan, allocations: [BudgetAllocation]) async throws {
      store.state.withLock { state in
        state.plans.removeAll { $0.id == plan.id || $0.effectiveMonth == plan.effectiveMonth }
        state.allocations.removeAll { $0.planID == plan.id }
        state.plans.append(plan)
        state.allocations += allocations
      }
    }
  }

  public struct Settings: SettingsRepository {
    let store: DashboardPreviewStore

    public func value(_ key: SettingKey) async throws -> String? {
      store.state.withLock { $0.settings[key.rawValue] }
    }

    public func set(_ key: SettingKey, _ value: String) async throws {
      store.state.withLock { $0.settings[key.rawValue] = value }
    }
  }
}
