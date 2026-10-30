import AbacusDomain
import Foundation

/// The dashboard Debts widget (R-DEBT-6, R-DEBT-21): "You lent" (negative, red) and "You borrowed"
/// (positive, green) in the display currency at the latest rate, then people with open balances,
/// largest first, each with their per-currency balances (never netted across currencies). Settled
/// debts and zero balances are left out. Built by `DashboardModel` (it follows the display currency
/// and the rates); the view is `DashboardDebtsCard` in the app. The sign flip is `DebtSign`.
public struct DashboardDebts: Hashable, Sendable {
  public struct Person: Hashable, Sendable, Identifiable {
    public let id: String
    /// The person's debt (context menu: edit, transactions, settle, delete).
    public let debtID: Debt.ID
    public let name: String
    /// Per currency in the display sign: "−₴1,200" you lent / "+$300" you borrowed.
    public let balances: [Balance]
    /// The person's balances summed in the display currency ("≈ −₴3,400"); nil without a rate.
    public let convertedText: String?
  }

  public struct Balance: Hashable, Sendable, Identifiable {
    public let money: Money
    /// "−₴1,200" (you lent) / "+$300" (you borrowed), see `DebtSign`.
    public let amountText: String
    /// "you lent" / "you borrowed".
    public let directionText: String
    /// Stored sign: they owe me (shown negative, red).
    public var owesMe: Bool { money.minorUnits > 0 }
    public var id: Currency { money.currency }
  }

  public let currency: Currency
  public let owedToMe: Money
  public let iOwe: Money
  /// "−₴1,200": what people owe me, shown negative ("You lent").
  public let lentText: String
  /// "+₴300": what I owe, shown positive ("You borrowed").
  public let borrowedText: String
  public let people: [Person]
  public let missing: DashboardMissingRates

  public var isEmpty: Bool { people.isEmpty }

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
        convertedText: person.balances.count > 1 || person.balances.first?.currency != currency
          ? person.converted.map { "≈ " + DebtSign.text(stored: $0, magnitude: format.money) } : nil)
    }
    return DashboardDebts(
      currency: currency, owedToMe: summary.owedToMe, iOwe: summary.iOwe,
      lentText: DebtSign.lentTotalText(summary.owedToMe, magnitude: format.money),
      borrowedText: DebtSign.borrowedTotalText(summary.iOwe, magnitude: format.money), people: people,
      missing: missing)
  }
}
