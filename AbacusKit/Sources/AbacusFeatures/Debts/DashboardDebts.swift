import AbacusDomain
import Foundation

/// The dashboard Debts widget (R-DEBT-6, R-DEBT-21): ONE total debt sum in the display currency at
/// the latest rate (signed and coloured by D61), then people with open balances, largest first,
/// each with one main figure (their total in the display currency) and, for a debt in several
/// currencies, a small per-currency caption. Settled debts and zero balances are left out. Built by
/// `DashboardModel` (it follows the display currency and the rates); the view is
/// `DashboardDebtsCard` in the app. The sign flip is `DebtSign`.
public struct DashboardDebts: Hashable, Sendable {
  public struct Person: Hashable, Sendable, Identifiable {
    public let id: String
    /// The person's debt (context menu: edit, transactions, settle, delete).
    public let debtID: Debt.ID
    public let name: String
    /// Per currency, stored sign (kept for the caption and tests).
    public let balances: [Balance]
    /// The person's total in the display currency (stored sign; nil without a rate).
    public let total: Money?
    /// "−₴3,400" in the display sign; nil without a rate ("No rate").
    public let totalText: String?
    /// Some balance was converted, so the figure is approximate ("≈").
    public let isApproximate: Bool
    /// Per-currency amounts without lent/borrowed labels; only for a debt with several currencies.
    public let secondaryText: String?
    /// Stored sign: they owe me (shown negative, red).
    public var owesMe: Bool { (total?.minorUnits ?? 0) > 0 }
  }

  public struct Balance: Hashable, Sendable, Identifiable {
    public let money: Money
    /// "−₴1,200" (you lent) / "+$300" (you borrowed), see `DebtSign`.
    public let amountText: String
    /// "you lent" / "you borrowed".
    public let directionText: String
    public var owesMe: Bool { money.minorUnits > 0 }
    public var id: Currency { money.currency }
  }

  public let currency: Currency
  public let owedToMe: Money
  public let iOwe: Money
  /// ONE total debt sum in the display currency (stored sign: positive = people owe me); nil when a
  /// rate is missing ("No rate").
  public let total: Money?
  /// The total in the display sign ("−₴900"); nil without a rate.
  public let totalText: String?
  /// Some balance was converted: shown as "≈ total".
  public let isApproximate: Bool
  public let people: [Person]
  public let missing: DashboardMissingRates

  public var isEmpty: Bool { people.isEmpty }
  /// Stored sign: people owe me (shown negative, red).
  public var totalOwesMe: Bool { (total?.minorUnits ?? 0) > 0 }

  public static func make(
    book: DebtBook, currency: Currency, converter: any CurrencyConverter, format: DashboardFormat
  ) -> DashboardDebts {
    let summary = Calc.debtSummary(book, currency: currency, converter: converter)
    var missing = DashboardMissingRates()
    missing.add(summary.unconverted)
    let people = summary.people.map { person in
      Person(
        id: person.personKey, debtID: person.debtID, name: person.personName,
        balances: person.balances.map { money in
          Balance(
            money: money, amountText: DebtSign.text(stored: money, magnitude: format.money),
            directionText: DebtSign.label(stored: money.minorUnits))
        },
        total: person.converted,
        totalText: person.converted.map { DebtSign.text(stored: $0, magnitude: format.money) },
        isApproximate: person.balances.contains { $0.currency != currency },
        secondaryText: DebtSign.caption(person.balances, magnitude: format.money))
    }
    let complete = summary.people.allSatisfy { $0.converted != nil }
    let total: Money? =
      complete
      ? Money(minorUnits: summary.people.reduce(0) { $0 + ($1.converted?.minorUnits ?? 0) }, currency: currency)
      : nil
    return DashboardDebts(
      currency: currency, owedToMe: summary.owedToMe, iOwe: summary.iOwe, total: total,
      totalText: total.map { DebtSign.text(stored: $0, magnitude: format.money) },
      isApproximate: summary.people.contains { $0.balances.contains { $0.currency != currency } },
      people: people, missing: missing)
  }
}
