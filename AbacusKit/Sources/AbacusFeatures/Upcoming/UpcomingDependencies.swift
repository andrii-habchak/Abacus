import AbacusDomain
import AbacusFX
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData

/// Everything the scheduled-items store offers the Upcoming screen (N5a contracts).
public typealias ScheduledStoreAccess =
  ScheduledItemRepository & ScheduledOccurrenceRepository & SuggestionDismissalRepository & ScheduledMaintenance

/// What the Upcoming screen (R-REC-10…12, 16) and its dashboard widget (R-REC-11) read and write.
public struct UpcomingDependencies: Sendable {
  public var scheduled: any ScheduledStoreAccess
  public var accounts: any AccountRepository
  public var categories: any CategoryRepository
  public var events: any EventRepository
  public var transactions: any TxnRepository
  public var settings: any SettingsRepository
  /// R-REC-6 (`ScheduledMatch.rule`): probes for "Link existing…".
  public var matcher: any ScheduledMatching
  public var converter: @Sendable () async -> any CurrencyConverter
  public var today: @Sendable () -> Day
  public var format: ManageFormat

  public init(
    scheduled: any ScheduledStoreAccess, accounts: any AccountRepository, categories: any CategoryRepository,
    events: any EventRepository, transactions: any TxnRepository, settings: any SettingsRepository,
    matcher: any ScheduledMatching = ScheduledMatch.rule,
    converter: @escaping @Sendable () async -> any CurrencyConverter, today: @escaping @Sendable () -> Day,
    format: ManageFormat = ManageFormat()
  ) {
    self.scheduled = scheduled
    self.accounts = accounts
    self.categories = categories
    self.events = events
    self.transactions = transactions
    self.settings = settings
    self.matcher = matcher
    self.converter = converter
    self.today = today
    self.format = format
  }

  public var calendar: Calendar { format.calendar }

  public static func live(
    database: any DatabaseWriter, refresher: RateRefresher, format: ManageFormat = ManageFormat()
  ) -> UpcomingDependencies {
    let calendar = format.calendar
    return UpcomingDependencies(
      scheduled: SQLiteScheduledStore(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database),
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      settings: SQLiteSettingsRepository(database: database),
      converter: { await refresher.snapshot.table }, today: { Day(Date(), calendar: calendar) }, format: format)
  }

  /// `PreviewData` plus `UpcomingSample` items in memory; "today" is the preview day.
  public static func preview(format: ManageFormat = ManageFormat()) -> UpcomingDependencies {
    let database = (try? UpcomingSample.database()) ?? (try! AbacusDatabase.open(at: nil))
    return onDatabase(database, today: PreviewData.today, format: format)
  }

  /// On any database with fixed rates (`PreviewData.fxRates`) and a fixed day (tests, previews).
  public static func onDatabase(
    _ database: any DatabaseWriter, today: Day, format: ManageFormat = ManageFormat()
  ) -> UpcomingDependencies {
    let calendar = format.calendar
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    return UpcomingDependencies(
      scheduled: SQLiteScheduledStore(database: database, calendar: calendar),
      accounts: SQLiteAccountRepository(database: database, calendar: calendar),
      categories: SQLiteCategoryRepository(database: database),
      events: SQLiteEventRepository(database: database),
      transactions: SQLiteTxnRepository(database: database, calendar: calendar),
      settings: SQLiteSettingsRepository(database: database),
      converter: { rates }, today: { today }, format: format)
  }
}
