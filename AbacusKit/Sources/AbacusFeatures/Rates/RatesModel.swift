import AbacusDomain
import AbacusFX
import Foundation
import Observation

/// The Exchange rates screen (R-FX-2, R-FX-4, R-FX-5): today's rates in a chosen currency with
/// day change, 30-day series and source; refresh + "updated" label; offline banner; manual rates
/// list and the add form.
@MainActor
@Observable
public final class RatesModel {
  public enum ApplyMode: String, Hashable, Sendable, CaseIterable {
    /// "On one day": `untilDay == fromDay`.
    case oneDay
    /// "From <day> until changed": `untilDay == nil`.
    case fromDay
  }

  public enum Trend: Hashable, Sendable { case up, down, flat }

  public struct Row: Identifiable, Hashable, Sendable {
    public var id: Currency { currency }
    public var currency: Currency
    /// "1 EUR = 48.5012 UAH"
    public var rateText: String
    /// "▲ 0.21%"; empty without a previous official day.
    public var changeText: String
    public var trend: Trend
    public var series: [RatePoint]
    /// "NBU" / "Manual".
    public var badge: String
    public var isManual: Bool
  }

  public struct OverrideRow: Identifiable, Hashable, Sendable {
    public var id: FXOverride.ID
    /// "1 EUR = 48.20 UAH"
    public var pair: String
    /// "Manual · on 15 Oct 2026 only" / "Manual · from 1 Oct 2026 until changed"
    public var applies: String
    public var note: String
    /// Accessibility label of the Remove button.
    public var removeLabel: String
  }

  // MARK: State

  /// "Show in".
  public var showIn: Currency = .UAH {
    didSet { if oldValue != showIn { rebuildRows() } }
  }
  public private(set) var rows: [Row] = []
  public private(set) var overrideRows: [OverrideRow] = []
  public private(set) var status = RatesStatus()
  public private(set) var isRefreshing = false
  /// The last store/service error, shown under the form.
  public private(set) var errorMessage: String?
  public private(set) var isLoaded = false

  // MARK: Add form

  public var formFrom: Currency = .EUR {
    didSet { if oldValue != formFrom { prefillRate() } }
  }
  public var formTo: Currency = .UAH {
    didSet { if oldValue != formTo { prefillRate() } }
  }
  public var formRateText = "" {
    didSet { if !isPrefilling { rateEdited = true } }
  }
  public var formMode: ApplyMode = .oneDay {
    didSet { if oldValue != formMode { prefillRate() } }
  }
  public var formOneDay: Day {
    didSet { if oldValue != formOneDay { prefillRate() } }
  }
  public var formFromDay: Day {
    didSet { if oldValue != formFromDay { prefillRate() } }
  }
  public var formNote = ""

  @ObservationIgnored private var isPrefilling = false
  @ObservationIgnored private var rateEdited = false

  // MARK: Dependencies

  @ObservationIgnored private var table = RateTable()
  @ObservationIgnored let store: any RateStore
  @ObservationIgnored let service: any RatesService
  @ObservationIgnored let today: @Sendable () -> Day
  @ObservationIgnored let now: @Sendable () -> Date
  @ObservationIgnored public let formats: Formats
  /// Told about every status change (the shell's "NBU rates · <day>" label).
  @ObservationIgnored public var onStatusChange: (@MainActor (RatesStatus) -> Void)?

  public init(
    store: any RateStore, service: any RatesService, today: @escaping @Sendable () -> Day,
    now: @escaping @Sendable () -> Date = { Date() }, formats: Formats = Formats()
  ) {
    self.store = store
    self.service = service
    self.today = today
    self.now = now
    self.formats = formats
    let day = today()
    formOneDay = day
    formFromDay = day
  }

  // MARK: Loading

  /// Days of cached rates read for the table: the 30-day series plus room for the previous
  /// official day before a long holiday.
  static let historyDays = 45

  public func load() async {
    let day = today()
    do {
      async let rates = store.rates(from: day.adding(days: -Self.historyDays), to: day)
      async let overrides = store.overrides()
      table = RateTable(rates: try await rates, overrides: try await overrides, today: day)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't read the rates: \(error.localizedDescription)"
    }
    status = await service.status()
    if status.latestDay == nil { status.latestDay = table.latestDay }
    rebuildRows()
    rebuildOverrides()
    prefillRate()
    isLoaded = true
    onStatusChange?(status)
  }

  /// "Refresh rates" / "Try again" (R-FX-1 on demand). Disabled while running.
  public func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    status.isRefreshing = true
    await service.refreshNow()
    await load()
    isRefreshing = false
    status.isRefreshing = false
  }

  // MARK: Labels

  /// "Updated today 09:00 · NBU rates for 21 Oct 2026" / "Updated just now · …" (R-FX-5).
  public var updatedLabel: String {
    var parts: [String] = []
    if let last = status.lastUpdate {
      let current = now()
      let calendar = formats.calendar
      if current.timeIntervalSince(last) < 60 && current >= last {
        parts.append("Updated just now")
      } else if calendar.isDate(last, inSameDayAs: current) {
        parts.append("Updated today \(formats.time(last))")
      } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: current),
        calendar.isDate(last, inSameDayAs: yesterday)
      {
        parts.append("Updated yesterday \(formats.time(last))")
      } else {
        parts.append("Updated \(formats.day(of: last))")
      }
    } else {
      parts.append("Not updated yet")
    }
    if let latest = status.latestDay {
      parts.append("NBU rates for \(formats.day(latest))")
    }
    return parts.joined(separator: " · ")
  }

  public var refreshLabel: String { isRefreshing ? "Refreshing…" : "Refresh rates" }

  /// The amber banner after a failed fetch (R-FX-4); nil while fetching works.
  public var offlineMessage: String? {
    guard status.isOffline else { return nil }
    guard let latest = status.latestDay else {
      return "Couldn't reach the rate service. No rates are known yet."
    }
    return "Couldn't reach the rate service. Amounts use the last known rates, from \(formats.day(latest))."
  }

  public static let ratesNote =
    "Official National Bank of Ukraine rates. Monthly totals use each transaction's own day; net worth uses today's rate. Weekends and holidays use the last published rate."
  public static let manualNote =
    "A manual rate wins over the fetched one for its days and is marked “Manual”. Remove it to go back to the official rate."
  public static let noOverridesText = "No manual rates. Fetched rates are used everywhere."

  // MARK: Add form

  /// The first day the new manual rate applies to.
  public var formStartDay: Day { formMode == .oneDay ? formOneDay : formFromDay }

  /// The fetched rate for the form's pair on its day, ignoring manual rates.
  public var fetchedFormRate: Decimal? {
    table.quote(from: formFrom, to: formTo, on: formStartDay, includeOverrides: false)?.rate
  }

  /// "fetched: 48.5012".
  public var fetchedHint: String {
    guard formFrom != formTo else { return "" }
    guard let rate = fetchedFormRate else { return "no fetched rate" }
    return "fetched: \(formats.rate(rate))"
  }

  /// Why "Add manual rate" is disabled; nil when the form is valid or still empty.
  public var formError: String? {
    if formFrom == formTo { return "Pick two different currencies." }
    let text = formRateText.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return nil }
    guard let rate = formats.parseDecimal(text), rate > 0 else { return "Enter a rate above zero." }
    return nil
  }

  public var canAddOverride: Bool {
    guard formFrom != formTo, let rate = formats.parseDecimal(formRateText), rate > 0 else { return false }
    return true
  }

  /// The override the form describes, nil while invalid.
  public var formOverride: FXOverride? {
    guard canAddOverride, let rate = formats.parseDecimal(formRateText) else { return nil }
    let start = formStartDay
    return FXOverride(
      base: formFrom, quote: formTo, rateE8: RateScale.scaled(rate), fromDay: start.string,
      untilDay: formMode == .oneDay ? start.string : nil,
      note: formNote.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// "Add manual rate" (R-FX-2). Returns whether it was saved.
  @discardableResult
  public func addOverride() async -> Bool {
    guard let override = formOverride else { return false }
    do {
      try await service.saveOverride(override)
      formNote = ""
      rateEdited = false
      await load()
      return true
    } catch {
      errorMessage = "Couldn't save the manual rate: \(error.localizedDescription)"
      return false
    }
  }

  /// "Remove": back to the fetched rate for those days (R-FX-2).
  public func removeOverride(_ id: FXOverride.ID) async {
    do {
      try await service.deleteOverride(id)
      await load()
    } catch {
      errorMessage = "Couldn't remove the manual rate: \(error.localizedDescription)"
    }
  }

  // MARK: Building

  private func rebuildRows() {
    rows = RatesOverview.rows(table, showIn: showIn, on: today()).map { row in
      let trend: Trend =
        switch row.change?.direction {
        case .up?: .up
        case .down?: .down
        case .flat?, nil: .flat
        }
      return Row(
        currency: row.currency,
        rateText: "1 \(row.currency.rawValue) = \(formats.rate(row.quote.rate)) \(row.showIn.rawValue)",
        changeText: row.change.map { formats.change($0.percent) } ?? "",
        trend: trend, series: row.series, badge: row.badge, isManual: row.quote.source.isManual)
    }
  }

  private func rebuildOverrides() {
    overrideRows = table.overrides
      .sorted { ($0.fromDay, $0.base.rawValue) > ($1.fromDay, $1.base.rawValue) }
      .map { override in
        OverrideRow(
          id: override.id,
          pair:
            "1 \(override.base.rawValue) = \(formats.manualRate(RateScale.decimal(override.rateE8))) \(override.quote.rawValue)",
          applies: appliesText(override), note: override.note,
          removeLabel: "Remove manual rate \(override.base.rawValue)/\(override.quote.rawValue)")
      }
  }

  func appliesText(_ override: FXOverride) -> String {
    switch override.scope {
    case .singleDay(let day)?: "Manual · on \(formats.day(day)) only"
    case .fromDay(let day)?: "Manual · from \(formats.day(day)) until changed"
    case .range(let from, let until)?: "Manual · \(formats.day(from)) – \(formats.day(until))"
    case nil: "Manual"
    }
  }

  private func prefillRate() {
    guard !rateEdited else { return }
    isPrefilling = true
    formRateText = fetchedFormRate.map { formats.rate($0) } ?? ""
    isPrefilling = false
  }
}
