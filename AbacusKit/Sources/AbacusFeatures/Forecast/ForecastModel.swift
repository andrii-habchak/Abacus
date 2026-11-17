import AbacusDomain
import AbacusStore
import Foundation
import Observation

/// The Forecast tab of Upcoming (R-REC-13…15, R-REC-19, R-REC-20; approved prototype
/// `N5-forecast`): today's balance plus the scheduled items only, per day, for 30/60/90 days, as
/// net worth (display currency, today's rates, debts held flat) or one account (its currency);
/// the lowest point and below-zero warnings; a past forecast over what happened; the accuracy of
/// every scheduled item with "Update amount to X".
@MainActor
@Observable
public final class ForecastModel {
  public enum Phase: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
  }

  /// What the chart shows (R-REC-14).
  public enum Series: Hashable, Sendable {
    case netWorth
    case account(Account.ID)
  }

  /// The accuracy panel's period (R-REC-20).
  public enum AccuracyScope: Hashable, Sendable {
    /// The chosen snapshot's day to today (all time without a snapshot).
    case sinceSnapshot
    case allTime
  }

  public private(set) var phase: Phase = .idle
  public var displayCurrency: Currency {
    didSet { if oldValue != displayCurrency { recompute() } }
  }
  /// 30, 60 or 90 (R-REC-14); the default is the `forecastHorizonDays` setting, else 90.
  public var horizonDays: Int = ForecastEngine.defaultHorizonDays {
    didSet { if oldValue != horizonDays { rebuildForecast() } }
  }
  public var series: Series = .netWorth {
    didSet { if oldValue != series { recompute() } }
  }
  public var accuracyScope: AccuracyScope = .sinceSnapshot {
    didSet { if oldValue != accuracyScope { recomputeAccuracy() } }
  }
  /// Accuracy rows with their occurrences shown.
  public var expandedItems: Set<UUID> = []
  public private(set) var selectedSnapshotID: ForecastSnapshot.ID?
  /// The last failed write ("Update amount to X"), shown under the panel.
  public var actionError: String?
  /// Called after this screen changed data (an item's amount), so other screens can reload.
  @ObservationIgnored public var onDataChange: (@MainActor () async -> Void)?

  // Loaded.
  public private(set) var today: Day
  /// The accounts the forecast covers: non-archived, not linked to a debt (their value counts
  /// through the debt, R-DEBT-18), in the store's order.
  public private(set) var accounts: [Account] = []
  public private(set) var items: [ScheduledItem] = []
  public private(set) var occurrences: [ScheduledOccurrence] = []
  public private(set) var snapshots: [ForecastSnapshotSummary] = []
  public private(set) var ratesAsOf: Day?
  public private(set) var forecast: Forecast?

  // Derived.
  public private(set) var projection: ForecastProjection?
  public private(set) var warnings: [ForecastWarningRow] = []
  public private(set) var overlay: ForecastOverlay?
  public private(set) var accuracy: ForecastAccuracy?

  public let format: ForecastFormat
  @ObservationIgnored private let dependencies: ForecastDependencies
  @ObservationIgnored private var balancesToday: [Account.ID: Int64] = [:]
  @ObservationIgnored private var currencies: [Account.ID: Currency] = [:]
  @ObservationIgnored private var resolved: Set<OccurrenceKey> = []
  @ObservationIgnored private var book: DebtBook = .empty
  @ObservationIgnored private var debtTermsToday: [Currency: Int64] = [:]
  @ObservationIgnored private var rates = SnapshotRates(asOf: nil, base: .UAH, toBase: [:])
  @ObservationIgnored private var snapshotContent: ForecastSnapshotContent?
  @ObservationIgnored private var actual: ActualDailyBalances?
  @ObservationIgnored private var loadedHorizonSetting = false

  public init(dependencies: ForecastDependencies, displayCurrency: Currency = .UAH) {
    self.dependencies = dependencies
    self.displayCurrency = displayCurrency
    self.format = ForecastFormat(dependencies.format)
    today = dependencies.today()
  }

  // MARK: Loading

  /// Reads everything and recomputes; keeps the chosen series, horizon and snapshot.
  public func load() async {
    if phase != .loaded { phase = .loading }
    do {
      today = dependencies.today()
      if !loadedHorizonSetting, let settings = dependencies.settings {
        loadedHorizonSetting = true
        if let text = try? await settings.value(.forecastHorizonDays), let days = Int(text),
          ForecastEngine.horizonChoices.contains(days)
        {
          horizonDays = days
        }
      }
      let all = try await dependencies.accounts()
      book = try await dependencies.debts?.book() ?? .empty
      let linked = book.linkedAccountIDs
      accounts = all.filter { !$0.isArchived && !linked.contains($0.id) }
      currencies = Dictionary(all.map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })
      let series = try await dependencies.balances([today])
      balancesToday = series.balances.compactMapValues(\.first)
      debtTermsToday = ForecastDebtTerms.terms(
        book: book, accountBalances: balancesToday, currencies: currencies, day: today)
      items = try await dependencies.items.items()
      occurrences = try await dependencies.occurrences.occurrences(itemID: nil)
      resolved = try await dependencies.occurrences.resolvedKeys()
      let converter = await dependencies.rates()
      var used = Set(all.map(\.currency)).union(debtTermsToday.keys)
      used.formUnion(Currency.displayOrder)
      if let converter {
        rates = SnapshotRates.latest(from: converter, currencies: used)
      } else {
        rates = SnapshotRates(asOf: nil, base: .UAH, toBase: [:])
      }
      ratesAsOf = rates.asOf
      snapshots = try await dependencies.snapshots?.snapshots() ?? []
      if case .account(let id) = self.series, !accounts.contains(where: { $0.id == id }) { self.series = .netWorth }
      if let id = selectedSnapshotID, snapshots.contains(where: { $0.id == id }) {
        try await loadSnapshot(id)
      } else {
        selectedSnapshotID = nil
        snapshotContent = nil
        actual = nil
      }
      rebuildForecast()
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// "Compare with a past forecast" (R-REC-19); nil = today's forecast only.
  public func selectSnapshot(_ id: ForecastSnapshot.ID?) async {
    selectedSnapshotID = id
    accuracyScope = .sinceSnapshot
    do {
      if let id { try await loadSnapshot(id) } else {
        snapshotContent = nil
        actual = nil
      }
    } catch {
      snapshotContent = nil
      actual = nil
      actionError = error.localizedDescription
    }
    recompute()
  }

  private func loadSnapshot(_ id: ForecastSnapshot.ID) async throws {
    guard let repository = dependencies.snapshots, let content = try await repository.snapshot(id),
      let taken = content.takenDay
    else {
      selectedSnapshotID = nil
      snapshotContent = nil
      actual = nil
      return
    }
    selectedSnapshotID = id
    snapshotContent = content
    let end = min(today, taken.plusDays(max(0, content.snapshot.horizonDays)))
    let days = taken <= end ? (0...taken.daysUntil(end)).map { taken.plusDays($0) } : []
    let series = try await dependencies.balances(days)
    let linked = book.linkedAccountIDs
    let included = Set(accounts.map(\.id)).subtracting(linked)
    var balances: [Account.ID: [Int64]] = [:]
    var accountCurrencies: [Account.ID: Currency] = [:]
    for (account, values) in series.balances where included.contains(account) {
      balances[account] = values
      accountCurrencies[account] = currencies[account]
    }
    let debts = ForecastDebtTerms.terms(
      book: book,
      series: .init(days: series.days, currencies: currencies, balances: series.balances))
    actual = ActualDailyBalances(days: series.days, currencies: accountCurrencies, balances: balances, debts: debts)
  }

  // MARK: Actions

  public var selectedSnapshot: ForecastSnapshotSummary? {
    snapshots.first { $0.id == selectedSnapshotID }
  }

  public func toggleExpanded(_ itemID: UUID) {
    if expandedItems.contains(itemID) { expandedItems.remove(itemID) } else { expandedItems.insert(itemID) }
  }

  /// "Update amount to X" (R-REC-20): the item's template amount becomes the suggested amount
  /// (future occurrences only; resolved ones keep theirs, R-REC-4). A same-currency transfer's
  /// received amount follows.
  public func applySuggestion(itemID: ScheduledItem.ID) async {
    guard let row = accuracy?.items.first(where: { $0.itemID == itemID }), let amount = row.suggestedAmountMinor,
      var item = items.first(where: { $0.id == itemID })
    else { return }
    if item.type == .transfer, let to = item.toAccountID, currencies[to] == currencies[item.accountID] {
      item.toAmountMinor = nil
    }
    item.amountMinor = amount
    do {
      try await dependencies.items.save(item)
      actionError = nil
      await load()
      await onDataChange?()
    } catch {
      actionError = "Could not update “\(item.payee)”: \(error.localizedDescription)"
    }
  }

  // MARK: Computing

  private func rebuildForecast() {
    forecast = ForecastEngine.run(
      accounts: accounts, balances: balancesToday, items: items, resolved: resolved, today: today,
      horizonDays: horizonDays)
    recompute()
  }

  private func recompute() {
    guard let forecast else {
      projection = nil
      warnings = []
      overlay = nil
      recomputeAccuracy()
      return
    }
    projection = makeProjection(forecast)
    warnings = makeWarnings(forecast)
    if let snapshotContent, let actual {
      overlay = ForecastOverlay.make(
        snapshot: snapshotContent, actual: actual, occurrences: occurrences, selection: selection, today: today)
    } else {
      overlay = nil
    }
    recomputeAccuracy()
  }

  private func recomputeAccuracy() {
    var period: ClosedRange<Day>?
    if accuracyScope == .sinceSnapshot, let taken = snapshotContent?.takenDay, taken <= today {
      period = taken...today
    }
    accuracy = ForecastAccuracy.report(items: items, occurrences: occurrences, period: period)
  }

  /// The overlay's selection for the current series.
  public var selection: ForecastSeriesSelection {
    switch series {
    case .netWorth: .netWorth(displayCurrency)
    case .account(let id): .account(id)
    }
  }

  /// The currency of every value on the page.
  public var seriesCurrency: Currency {
    switch series {
    case .netWorth: displayCurrency
    case .account(let id): accounts.first { $0.id == id }?.currency ?? displayCurrency
    }
  }

  private func makeProjection(_ forecast: Forecast) -> ForecastProjection {
    switch series {
    case .account(let id):
      return ForecastProjection(
        currency: seriesCurrency, points: forecast.series(for: id).map(ForecastDayValue.init), unconverted: [])
    case .netWorth:
      let currency = displayCurrency
      let (points, missing) = forecast.netWorth(convert: rates.converter(to: currency))
      var unconverted = missing
      var debts: Int64 = 0
      for (debtCurrency, minor) in debtTermsToday {
        if let value = rates.convert(minor, from: debtCurrency, to: currency) {
          debts += value
        } else {
          unconverted.insert(debtCurrency)
        }
      }
      let shifted = points.map { ForecastDayValue(day: $0.day, valueMinor: $0.valueMinor + debts) }
      return ForecastProjection(currency: currency, points: shifted, unconverted: unconverted)
    }
  }

  private func makeWarnings(_ forecast: Forecast) -> [ForecastWarningRow] {
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return forecast.warnings.compactMap { warning in
      guard let account = accounts.first(where: { $0.id == warning.accountID }),
        let values = forecast.balances[warning.accountID],
        let start = forecast.days.firstIndex(of: warning.day)
      else { return nil }
      var lowest = values[start]
      var end = start
      while end < values.count, values[end] < 0 {
        lowest = min(lowest, values[end])
        end += 1
      }
      let backAbove = end < values.count ? forecast.days[end] : nil
      // The occurrences that take it below zero: those on that day first, else the latest ones.
      let onDay = warning.causes.filter { max($0.expectedDay, forecast.today) == warning.day }
      let causes = (onDay.isEmpty ? Array(warning.causes.suffix(1)) : onDay).map { occurrence in
        ForecastWarningRow.Cause(
          itemID: occurrence.itemID, name: byID[occurrence.itemID]?.payee ?? "Scheduled item",
          day: occurrence.expectedDay, isOverdue: occurrence.isOverdue)
      }
      return ForecastWarningRow(
        accountID: account.id, accountName: account.name, currency: account.currency, day: warning.day,
        balanceMinor: warning.balanceMinor, lowestMinor: lowest, backAboveZero: backAbove, causes: causes,
        allCauses: warning.causes.count)
    }
  }

  // MARK: Text

  /// "Main account goes below 0 on 18 Dec, −120.00 zł (lowest −340.00 zł, back above 0 on 10 Jan) after “Rent”."
  public func text(_ warning: ForecastWarningRow) -> String {
    var text = "\(warning.accountName) goes below 0 on \(format.day(warning.day)), \(format.money(warning.balanceMinor, warning.currency))"
    var extras: [String] = []
    if warning.lowestMinor < warning.balanceMinor {
      extras.append("lowest \(format.money(warning.lowestMinor, warning.currency))")
    }
    if let back = warning.backAboveZero { extras.append("back above 0 on \(format.day(back))") }
    if !extras.isEmpty { text += " (" + extras.joined(separator: ", ") + ")" }
    if !warning.causes.isEmpty {
      text += " after " + warning.causes.map { "“\($0.name)”" }.joined(separator: ", ")
    }
    return text + "."
  }

  /// "3 Nov · 14 days ago · 48,250.00 zł" (R-REC-19 picker row).
  public func label(_ snapshot: ForecastSnapshotSummary) -> String {
    let ago = snapshot.daysAgo(today: today)
    let when = ago == 0 ? "today" : (ago == 1 ? "1 day ago" : "\(ago) days ago")
    var text = "\(format.day(snapshot.takenDay)) · \(when)"
    switch series {
    case .netWorth:
      if let end = snapshot.endNetWorth(in: displayCurrency) { text += " · ends \(format.money(end, displayCurrency))" }
    case .account(let id):
      if let account = snapshot.start.balance(of: id) {
        text += " · ends \(format.money(snapshot.endBalances[id] ?? account.balanceMinor, account.currency))"
      }
    }
    return text
  }

  /// The series picker's rows: net worth first, then the accounts (R-REC-14).
  public var seriesChoices: [(series: Series, title: String)] {
    [(.netWorth, "Net worth (\(displayCurrency.rawValue))")]
      + accounts.map { (.account($0.id), "\($0.name) (\($0.currency.rawValue))") }
  }

  /// The day's values under the chart ("Tue 5 Nov · forecast 1,200.00 zł · scheduled: Rent").
  public func detail(for day: Day) -> String {
    let currency = seriesCurrency
    var parts: [String] = []
    if let overlay {
      if let actual = overlay.actual.first(where: { $0.day == day }) {
        parts.append("actual \(format.money(actual.valueMinor, currency))")
      }
      if let past = overlay.forecast.first(where: { $0.day == day }), let taken = selectedSnapshot?.takenDay {
        parts.append("forecast of \(format.day(taken)) \(format.money(past.valueMinor, currency))")
      }
    }
    if let point = projection?.points.first(where: { $0.day == day }) {
      parts.append((overlay == nil ? "forecast " : "today’s forecast ") + format.money(point.valueMinor, currency))
    }
    let names = (forecast?.occurrences ?? [])
      .filter { $0.expectedDay == day && !$0.isOverdue && affectsSeries($0) }
      .compactMap { occurrence in items.first { $0.id == occurrence.itemID }?.payee }
    var text = format.longDay(day)
    if !parts.isEmpty { text += " · " + parts.joined(separator: " · ") }
    if !names.isEmpty { text += " · scheduled: " + names.joined(separator: ", ") }
    return text
  }

  private func affectsSeries(_ occurrence: ExpectedOccurrence) -> Bool {
    switch series {
    case .netWorth: true
    case .account(let id): occurrence.effects.contains { $0.accountID == id }
    }
  }

  /// Average |Δ day| over paid occurrences of a row; nil without any.
  public func averageDayShift(_ rows: [OccurrenceAccuracy]) -> Double? {
    let shifts = rows.compactMap(\.dayDelta).map { Double(abs($0)) }
    return shifts.isEmpty ? nil : shifts.reduce(0, +) / Double(shifts.count)
  }

  /// The currency of an item's amounts (its account's).
  public func currency(of item: ScheduledItem?) -> Currency {
    item.flatMap { currencies[$0.accountID] } ?? displayCurrency
  }

  /// Gap split per day of the period ("everything else averages X per day").
  public var otherPerDayMinor: Int64? {
    guard let overlay, let split = overlay.split, let gapDay = overlay.gapDay, let taken = selectedSnapshot?.takenDay
    else { return nil }
    let days = taken.daysUntil(gapDay)
    guard days > 0 else { return nil }
    return split.otherMinor / Int64(days)
  }
}

/// Today's forecast for the chosen series in one currency.
public struct ForecastProjection: Hashable, Sendable {
  public let currency: Currency
  /// Index 0 = today.
  public let points: [ForecastDayValue]
  /// Currencies left out of net worth for lack of a rate (D27).
  public let unconverted: Set<Currency>

  public init(currency: Currency, points: [ForecastDayValue], unconverted: Set<Currency>) {
    self.currency = currency
    self.points = points
    self.unconverted = unconverted
  }

  public var now: ForecastDayValue? { points.first }
  public var end: ForecastDayValue? { points.last }
  /// The lowest projected point (R-REC-15); the earliest of equal ones.
  public var lowest: ForecastDayValue? {
    points.reduce(nil) { best, point in
      guard let best else { return point }
      return point.valueMinor < best.valueMinor ? point : best
    }
  }
  public var changeMinor: Int64? {
    guard let now, let end else { return nil }
    return end.valueMinor - now.valueMinor
  }
}

/// One day's value of a line (the domain's `ForecastPoint` has no public initialiser).
public struct ForecastDayValue: Hashable, Sendable {
  public let day: Day
  public let valueMinor: Int64

  public init(day: Day, valueMinor: Int64) {
    self.day = day
    self.valueMinor = valueMinor
  }

  public init(_ point: ForecastPoint) {
    self.init(day: point.day, valueMinor: point.valueMinor)
  }
}

/// One below-zero warning (R-REC-15).
public struct ForecastWarningRow: Hashable, Sendable, Identifiable {
  public struct Cause: Hashable, Sendable {
    public let itemID: ScheduledItem.ID
    public let name: String
    public let day: Day
    public let isOverdue: Bool
  }

  public let accountID: Account.ID
  public let accountName: String
  public let currency: Currency
  /// The first day below zero and the balance that day.
  public let day: Day
  public let balanceMinor: Int64
  /// The lowest balance of that below-zero stretch.
  public let lowestMinor: Int64
  /// The first day back at or above zero, nil when it stays below to the horizon.
  public let backAboveZero: Day?
  /// The occurrences that take it below zero (on that day).
  public let causes: [Cause]
  /// How many outgoing occurrences of that account lie up to that day.
  public let allCauses: Int

  public var id: Account.ID { accountID }
}
