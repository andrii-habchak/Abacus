import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// Names for ids and ids for names: the model speaks in names, the database in UUIDs.
struct Directory: Sendable {
  let accounts: [Account]
  let categories: [AbacusDomain.Category]
  let events: [Event]

  func accountName(_ id: Account.ID) -> String { accounts.first { $0.id == id }?.name ?? "Unknown account" }

  /// `Parent › Child` for a subcategory.
  func categoryName(_ id: AbacusDomain.Category.ID) -> String {
    guard let category = categories.first(where: { $0.id == id }) else { return "Unknown category" }
    if let parent = category.parentID.flatMap({ parentID in categories.first { $0.id == parentID } }) {
      return "\(parent.name) › \(category.name)"
    }
    return category.name
  }

  func eventName(_ id: Event.ID) -> String? { events.first { $0.id == id }?.name }

  /// An account by id (UUID text) or exact name (case-insensitive).
  func account(_ reference: String) throws -> Account {
    if let id = UUID(uuidString: reference), let account = accounts.first(where: { $0.id == id }) { return account }
    let matches = accounts.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
    guard let first = matches.first else { throw ToolError("No account “\(reference)”. Use list_accounts for names.") }
    guard matches.count == 1 else {
      throw ToolError("“\(reference)” matches \(matches.count) accounts; use the id from list_accounts")
    }
    return first
  }

  /// A category by id, exact name, or `Parent › Child` / `Parent > Child`.
  func category(_ reference: String) throws -> AbacusDomain.Category {
    if let id = UUID(uuidString: reference), let category = categories.first(where: { $0.id == id }) { return category }
    let normalized = reference.replacing(" > ", with: " › ")
    let matches = categories.filter {
      $0.name.caseInsensitiveCompare(reference) == .orderedSame
        || categoryName($0.id).caseInsensitiveCompare(normalized) == .orderedSame
    }
    guard let first = matches.first else { throw ToolError("No category “\(reference)”. Use list_categories for names.") }
    guard matches.count == 1 else {
      throw ToolError("“\(reference)” matches \(matches.count) categories; use “Parent › Child” or the id")
    }
    return first
  }

  func event(_ reference: String) throws -> Event {
    if let id = UUID(uuidString: reference), let event = events.first(where: { $0.id == id }) { return event }
    guard let event = events.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
      throw ToolError("No event “\(reference)”")
    }
    return event
  }
}

public struct TransactionFilter: Sendable {
  public var from: String?
  public var to: String?
  public var accounts: [String] = []
  public var categories: [String] = []
  public var types: [String] = []
  public var event: String?
  public var text: String?
  public var uncategorisedOnly = false
  public var limit: Int?
  public var offset: Int = 0
  public var newestFirst = true

  public init() {}
}

extension AbacusQueries {
  func directory() async throws -> Directory {
    async let accounts = accountsRepository.accounts(includeArchived: true)
    async let categories = categoriesRepository.categories(kind: nil, includeArchived: true)
    async let events = SQLiteEventRepository(database: database).events(includeArchived: true)
    return Directory(accounts: try await accounts, categories: try await categories, events: try await events)
  }

  public func categories(includeArchived: Bool = false) async throws -> [CategoryDTO] {
    let directory = try await directory()
    return directory.categories.filter { includeArchived || !$0.isArchived }.map {
      CategoryDTO(
        id: $0.id.uuidString, name: $0.name, kind: $0.kind.rawValue,
        parent: $0.parentID.map { directory.categoryName($0) }, isArchived: $0.isArchived)
    }
  }

  func query(for filter: TransactionFilter, directory: Directory) throws -> TxnQuery {
    var query = TxnQuery(newestFirst: filter.newestFirst)
    if let from = filter.from {
      guard let day = Day(from) else { throw ToolError("“from” must look like 2026-03-31") }
      query.fromDay = day
    }
    if let to = filter.to {
      guard let day = Day(to) else { throw ToolError("“to” must look like 2026-03-31") }
      query.toDay = day
    }
    query.accountIDs = Set(try filter.accounts.map { try directory.account($0).id })
    query.categoryIDs = Set(try filter.categories.map { try directory.category($0).id })
    query.types = Set(
      try filter.types.map {
        guard let type = TxnType(rawValue: $0) else { throw ToolError("Unknown type “\($0)”; use expense, income or transfer") }
        return type
      })
    if let event = filter.event { query.eventIDs = [try directory.event(event).id] }
    query.search = filter.text ?? ""
    query.includeUncategorised = filter.uncategorisedOnly
    return query
  }

  /// Transactions matching the filters, at most `searchCap` rows (R-LIST-1…6). `matching` says
  /// how many matched in all, so a model can narrow the filters instead of paging blindly.
  public func searchTransactions(_ filter: TransactionFilter) async throws -> TransactionSearchDTO {
    let directory = try await directory()
    let query = try query(for: filter, directory: directory)
    let limit = min(max(filter.limit ?? 50, 1), Self.searchCap)
    let repository = txnRepository
    async let count = repository.summary(matching: query).count
    let rows = try await repository.page(matching: query, offset: max(filter.offset, 0), limit: limit)
    let total = try await count
    return TransactionSearchDTO(
      matching: total, returned: rows.count, truncated: total > max(filter.offset, 0) + rows.count,
      transactions: rows.map { transaction($0, directory) })
  }

  /// One transaction by id.
  public func transaction(id: String) async throws -> TransactionDTO? {
    guard let uuid = UUID(uuidString: id) else { throw ToolError("“id” must be a transaction id") }
    guard let row = try await txnRepository.transaction(uuid) else { return nil }
    return transaction(row, try await directory())
  }

  func transaction(_ row: TxnWithLines, _ directory: Directory) -> TransactionDTO {
    let txn = row.txn
    let account = directory.accounts.first { $0.id == txn.accountID }
    let target = txn.toAccountID.flatMap { id in directory.accounts.first { $0.id == id } }
    let currency = account?.currency ?? .UAH
    return TransactionDTO(
      id: txn.id.uuidString, date: Day(txn.occurredAt, calendar: calendar).string, type: txn.type.rawValue,
      account: account?.name ?? "Unknown account", toAccount: target?.name,
      amount: MoneyDTO(minor: txn.amountMinor, currency: currency),
      toAmount: txn.toAmountMinor.map { MoneyDTO(minor: $0, currency: target?.currency ?? currency) },
      category: txn.categoryID.map { directory.categoryName($0) }, payee: txn.payee, note: txn.note,
      event: txn.eventID.flatMap { directory.eventName($0) }, isRefund: txn.isRefund,
      refundOf: txn.refundOfID?.uuidString, isBalanceCorrection: txn.isBalanceCorrection,
      originalAmount: txn.originalAmountMinor.flatMap { minor in
        txn.originalCurrencyCode.map { MoneyDTO(minor: minor, code: $0) }
      },
      source: txn.source.rawValue, importBatchID: txn.importBatchID?.uuidString,
      attachedRecords: row.lines.map {
        TransactionDTO.Line(
          kind: $0.kind.rawValue, category: $0.categoryID.map { directory.categoryName($0) },
          amount: MoneyDTO(minor: $0.amountMinor, currency: currency), note: $0.note)
      })
  }

  /// Expenses and income without a category (transfers excluded): what is left to sort.
  public func uncategorised(from: String?, to: String?, limit: Int?) async throws -> TransactionSearchDTO {
    var filter = TransactionFilter()
    filter.from = from
    filter.to = to
    filter.limit = limit
    filter.uncategorisedOnly = true
    return try await searchTransactions(filter)
  }
}
