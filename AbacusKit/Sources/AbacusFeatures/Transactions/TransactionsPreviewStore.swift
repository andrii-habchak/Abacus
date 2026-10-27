import AbacusDomain
import AbacusFX
import Foundation

/// In-memory repositories over `PreviewData` (or any given entities) for previews, screenshots
/// and tests, until the app is wired to the SQLite store. Each protocol gets its own actor
/// (the protocols share method signatures, all ids being UUIDs).
public struct TransactionsPreviewStore: Sendable {
  public let transactions: Transactions
  public let accounts: Accounts
  public let categories: Categories
  public let events: Events

  public init(
    accounts: [Account], categories: [AbacusDomain.Category], events: [Event], txns: [Txn],
    attachedRecords: [AttachedRecord], calendar: Calendar = .current, groups: [AccountGroup] = []
  ) {
    transactions = Transactions(
      txns: txns, attachedRecords: attachedRecords, categories: categories, calendar: calendar)
    self.accounts = Accounts(accounts, groups: groups)
    self.categories = Categories(categories)
    self.events = Events(events)
  }

  /// The synthetic preview data set (`PreviewData`).
  public static func preview(calendar: Calendar = .current) -> TransactionsPreviewStore {
    TransactionsPreviewStore(
      accounts: PreviewData.accounts, categories: PreviewData.categories, events: PreviewData.events,
      txns: PreviewData.txns, attachedRecords: PreviewData.attachedRecords, calendar: calendar,
      groups: PreviewData.accountGroups)
  }

  public actor Transactions: TxnRepository {
    private var txns: [Txn.ID: Txn]
    private var lines: [Txn.ID: [AttachedRecord]]
    private let categories: [AbacusDomain.Category]
    private let calendar: Calendar

    public init(
      txns: [Txn], attachedRecords: [AttachedRecord], categories: [AbacusDomain.Category],
      calendar: Calendar = .current
    ) {
      self.txns = Dictionary(txns.map { ($0.id, $0) }) { first, _ in first }
      self.lines = Dictionary(grouping: attachedRecords, by: \.txnID)
      self.categories = categories
      self.calendar = calendar
    }

    public func transactions(matching query: TxnQuery) async throws -> [TxnWithLines] {
      let rows = txns.values.map { txn in
        TxnWithLines(txn: txn, lines: (lines[txn.id] ?? []).sorted { $0.position < $1.position })
      }
      return TransactionQueryMatcher(query: query, categories: categories, calendar: calendar).apply(rows)
    }

    public func save(_ txn: Txn, lines: [AttachedRecord]) async throws {
      txns[txn.id] = txn
      self.lines[txn.id] = lines.map { line in
        var line = line
        line.txnID = txn.id
        return line
      }
    }

    public func delete(_ id: Txn.ID) async throws {
      guard txns.removeValue(forKey: id) != nil else { throw RepositoryError.notFound }
      lines[id] = nil
    }
  }

  public actor Accounts: AccountRepository {
    private var list: [Account]
    private let groupList: [AccountGroup]

    public init(_ accounts: [Account], groups: [AccountGroup] = []) {
      list = accounts
      groupList = groups
    }

    public func groups() async throws -> [AccountGroup] { groupList }

    public func accounts(includeArchived: Bool) async throws -> [Account] {
      list.filter { includeArchived || !$0.isArchived }
    }

    public func save(_ account: Account) async throws {
      if let index = list.firstIndex(where: { $0.id == account.id }) {
        list[index] = account
      } else {
        list.append(account)
      }
    }

    public func setArchived(_ id: Account.ID, _ isArchived: Bool) async throws {
      guard let index = list.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
      list[index].isArchived = isArchived
    }

    /// The fake does not know transactions: it always deletes.
    public func delete(_ id: Account.ID) async throws {
      list.removeAll { $0.id == id }
    }
  }

  public actor Categories: CategoryRepository {
    private var list: [AbacusDomain.Category]

    public init(_ categories: [AbacusDomain.Category]) { list = categories }

    public func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [AbacusDomain.Category] {
      list.filter { (kind == nil || $0.kind == kind) && (includeArchived || !$0.isArchived) }
    }

    public func save(_ category: AbacusDomain.Category) async throws {
      if let index = list.firstIndex(where: { $0.id == category.id }) {
        list[index] = category
      } else {
        list.append(category)
      }
    }

    public func setArchived(_ id: AbacusDomain.Category.ID, _ isArchived: Bool) async throws {
      guard let index = list.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
      list[index].isArchived = isArchived
    }

    /// The fake does not reassign transactions; children move up to top level.
    public func delete(_ id: AbacusDomain.Category.ID, reassignTo: AbacusDomain.Category.ID?) async throws {
      for index in list.indices where list[index].parentID == id { list[index].parentID = nil }
      list.removeAll { $0.id == id }
    }
  }

  public actor Events: EventRepository {
    private var list: [Event]

    public init(_ events: [Event]) { list = events }

    public func events(includeArchived: Bool) async throws -> [Event] {
      list.filter { includeArchived || !$0.isArchived }
    }

    public func save(_ event: Event) async throws {
      if let index = list.firstIndex(where: { $0.id == event.id }) {
        list[index] = event
      } else {
        list.append(event)
      }
    }

    public func setArchived(_ id: Event.ID, _ isArchived: Bool) async throws {
      guard let index = list.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
      list[index].isArchived = isArchived
    }

    /// The fake does not clear the event from transactions.
    public func delete(_ id: Event.ID) async throws {
      list.removeAll { $0.id == id }
    }
  }
}

extension RateTable {
  /// The preview rates (`PreviewData.fxRates`) as a converter, "today" = `PreviewData.today`.
  public static var transactionsPreview: RateTable {
    RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
  }
}
