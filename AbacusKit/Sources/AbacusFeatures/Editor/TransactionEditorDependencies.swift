import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation

/// Looks one transaction up by id. `TxnRepository` has no such method yet (requested in
/// `docs/status/B4.md`); the SQLite store already implements it, other repositories fall back
/// to scanning `transactions(matching:)`.
public protocol TxnLookup: Sendable {
  func transaction(_ id: Txn.ID) async throws -> TxnWithLines?
}

extension SQLiteTxnRepository: TxnLookup {}

/// What the editor reads and writes, as repository protocols. The app passes the store's
/// repositories and the current `RateTable`; previews and tests use `preview()`.
public struct TransactionEditorDependencies: Sendable {
  public var transactions: any TxnRepository
  public var accounts: any AccountRepository
  public var categories: any CategoryRepository
  public var events: any EventRepository
  public var rules: any RuleRepository
  public var settings: any SettingsRepository
  /// Rates for the "Charged to account" estimate (R-CUR-4); replace it when rates change.
  public var converter: any CurrencyConverter
  /// Asks for the official rates of `days` (`RateRefresher.ensureRates(for:)`, which follows
  /// the auto-refresh flag) and answers the rates known afterwards. Nil: rates in memory only.
  public var requestRates: (@Sendable ([Day]) async -> (any CurrencyConverter)?)?
  public var calendar: Calendar
  /// Date and time a new transaction starts with.
  public var now: @Sendable () -> Date

  public init(
    transactions: any TxnRepository, accounts: any AccountRepository,
    categories: any CategoryRepository, events: any EventRepository, rules: any RuleRepository,
    settings: any SettingsRepository, converter: any CurrencyConverter, calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transactions = transactions
    self.accounts = accounts
    self.categories = categories
    self.events = events
    self.rules = rules
    self.settings = settings
    self.converter = converter
    self.calendar = calendar
    self.now = now
  }

  func transaction(_ id: Txn.ID) async throws -> TxnWithLines? {
    if let lookup = transactions as? any TxnLookup {
      return try await lookup.transaction(id)
    }
    return try await transactions.transactions(matching: TxnQuery()).first { $0.txn.id == id }
  }
}

// MARK: - Preview data

extension TransactionEditorDependencies {
  /// "Now" in the preview world: `PreviewData.today` at 15:30.
  public static var previewNow: Date {
    let today = PreviewData.today
    return Calendar.current.date(
      from: DateComponents(year: today.year, month: today.month, day: today.day, hour: 15, minute: 30))!
  }

  /// Last-used defaults of the approved prototype: EUR on Revolut EUR; last transfer
  /// Monobank Black → Revolut EUR.
  public static var previewSettings: [SettingKey: String] {
    [
      .lastTxnCurrency: "EUR",
      .lastAccountID: PreviewData.revolutEUR.id.uuidString,
      .lastTransferFromID: PreviewData.monobank.id.uuidString,
      .lastTransferToID: PreviewData.revolutEUR.id.uuidString,
    ]
  }

  /// The editor on the synthetic preview data, rules and rates. Pass `now` to start a new
  /// transaction on another day (e.g. inside the Lyon trip for the event pre-selection).
  public static func preview(
    settings: [SettingKey: String] = previewSettings, now: Date = previewNow,
    store: TransactionsPreviewStore = .preview()
  ) -> TransactionEditorDependencies {
    TransactionEditorDependencies(
      transactions: store.transactions, accounts: store.accounts, categories: store.categories,
      events: store.events, rules: EditorPreviewRules(EditorPreviewRules.sample),
      settings: EditorPreviewSettings(settings), converter: RateTable.transactionsPreview,
      now: { now })
  }
}

/// In-memory categorisation rules for previews and tests.
public actor EditorPreviewRules: RuleRepository {
  private var list: [CategoryRule]
  public private(set) var hits: [CategoryRule.ID: Int] = [:]

  public init(_ rules: [CategoryRule]) { list = rules }

  /// Synthetic rules matching the prototype: Biedronka, Lidl → Groceries; Bolt, Uber → Taxi;
  /// Orlen → Fuel; Orange → Mobile.
  public static let sample: [CategoryRule] = [
    ("biedronka", 202), ("lidl", 202), ("bolt", 207), ("uber", 207), ("orlen", 208), ("orange", 211),
  ].enumerated().map { index, rule in
    CategoryRule(
      id: PreviewData.id(901 + index), pattern: rule.0, categoryID: PreviewData.id(rule.1),
      origin: .imported, hitCount: 3, position: index)
  }

  public func rules() async throws -> [CategoryRule] { list }

  public func save(_ rule: CategoryRule) async throws {
    if let index = list.firstIndex(where: { $0.id == rule.id }) { list[index] = rule } else { list.append(rule) }
  }

  /// Rules only: the editor's fake has no transactions.
  public func save(_ rule: CategoryRule?, updating txns: [Txn]) async throws {
    if let rule { try await save(rule) }
  }

  /// Rules only (no transactions here); nothing to roll back.
  public func apply(_ rule: CategoryRule, records: [RuleApplication]) async throws { try await save(rule) }

  public func applications(of ruleID: CategoryRule.ID) async throws -> [RuleApplication] { [] }

  public func rollBack(_ ruleID: CategoryRule.ID) async throws -> RuleRollback { RuleRollback() }

  public func delete(_ id: CategoryRule.ID) async throws { list.removeAll { $0.id == id } }

  public func recordHit(_ id: CategoryRule.ID) async throws {
    hits[id, default: 0] += 1
    if let index = list.firstIndex(where: { $0.id == id }) { list[index].hitCount += 1 }
  }
}

/// In-memory settings for previews and tests.
public actor EditorPreviewSettings: SettingsRepository {
  public private(set) var values: [SettingKey: String]

  public init(_ values: [SettingKey: String] = [:]) { self.values = values }

  public func value(_ key: SettingKey) async throws -> String? { values[key] }

  public func set(_ key: SettingKey, _ value: String) async throws { values[key] = value }
}
