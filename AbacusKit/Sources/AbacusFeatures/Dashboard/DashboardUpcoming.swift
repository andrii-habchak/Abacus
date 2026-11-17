import AbacusDomain
import Foundation

/// The dashboard widget "Upcoming (30 days)" (R-REC-11, prototype `N5-forecast` dashboard):
/// the next up to six expected occurrences (overdue first), money out / in / net in the display
/// currency, "N more", and the empty state when no item exists. Built from `UpcomingModel`; the
/// view is `DashboardUpcomingCard` in the app.
public struct DashboardUpcoming: Hashable, Sendable {
  public static let rangeDays = 30
  public static let shown = 6

  public struct Row: Identifiable, Hashable, Sendable {
    public var id: String { occurrence.id }
    public let occurrence: UpcomingOccurrence
    public let title: String
    public let accountText: String
    /// "Today", "Thu 5 Nov", or "Overdue · 26 Oct".
    public let whenText: String
    public let isOverdue: Bool
    public let amountText: String
    public let convertedText: String?
    public let isIncome: Bool
    public let colorHex: String?

    public var initial: String { String(title.first.map { String($0).uppercased() } ?? "•") }
  }

  /// False: no scheduled item at all (the one-line empty state).
  public let hasItems: Bool
  public let rows: [Row]
  public let moreCount: Int
  public let overdueCount: Int
  public let totals: UpcomingTotals
  public let outText: String
  public let inText: String
  public let netText: String
  /// "3 more · rates as of 3 Nov 2026 · transfers not counted".
  public let footnote: String

  /// "1 overdue" / "On schedule".
  public var statusText: String { overdueCount > 0 ? "\(overdueCount) overdue" : "On schedule" }

  @MainActor
  public static func make(_ model: UpcomingModel) -> DashboardUpcoming {
    let today = model.today
    let all = UpcomingCalc.occurrences(
      items: model.items, stored: model.stored, accounts: model.accounts, today: today, rangeDays: rangeDays,
      graceDays: model.graceDays
    ).filter(\.isExpected)
    let ordered = all.filter { $0.day < today } + all.filter { $0.day >= today }
    let rows = ordered.prefix(shown).map { occurrence in
      let row = model.row(occurrence)
      let overdue = occurrence.day < today
      return Row(
        occurrence: occurrence, title: row.title, accountText: row.accountText,
        whenText: overdue ? "Overdue · \(model.dayText(occurrence.day))" : occurrence.day == today ? "Today" : row.dayText,
        isOverdue: overdue, amountText: row.amountText, convertedText: row.convertedText, isIncome: row.isIncome,
        colorHex: row.colorHex)
    }
    let totals = UpcomingCalc.totals(all, accounts: model.accounts, currency: model.displayCurrency, converter: model.converter)
    let currency = model.displayCurrency
    var notes = ["\(max(0, all.count - shown)) more"]
    if let day = model.converter.latestDay { notes.append("rates as of \(model.dayText(day, year: true))") }
    notes.append("transfers not counted")
    if !totals.unconverted.isEmpty {
      notes.append("no rate for \(totals.unconverted.map(\.rawValue).sorted().joined(separator: ", "))")
    }
    return DashboardUpcoming(
      hasItems: !model.items.isEmpty, rows: Array(rows), moreCount: max(0, all.count - shown),
      overdueCount: all.filter { $0.day < today }.count, totals: totals,
      outText: "−" + model.money(totals.outMinor, currency), inText: "+" + model.money(totals.inMinor, currency),
      netText: model.signedMoney(totals.netMinor, currency), footnote: notes.joined(separator: " · "))
  }
}

extension UpcomingModel {
  /// The dashboard widget's data (R-REC-11).
  public var dashboard: DashboardUpcoming { DashboardUpcoming.make(self) }
}
