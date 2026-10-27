import AbacusDomain
import Foundation

/// The dashboard Debts widget (R-DEBT-6): "Owed to you" and "You owe" in the display currency
/// at the latest rate, then people with open balances, largest first, each with their
/// per-currency balances (never netted across currencies). Settled debts and zero balances are
/// left out. Built by `DashboardModel` (it follows the display currency and the rates); the view
/// is `DashboardDebtsCard` in the app.
public struct DashboardDebts: Hashable, Sendable {
  public struct Person: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// "owes you ₴1,200 · €50" / "you owe $300"; per currency, sign = direction.
    public let balances: [Balance]
    /// The person's balances summed in the display currency ("≈ ₴3,400"); nil without a rate.
    public let convertedText: String?
  }

  public struct Balance: Hashable, Sendable, Identifiable {
    public let money: Money
    /// "₴1,200".
    public let amountText: String
    /// "owes you" / "you owe".
    public let directionText: String
    public var owesMe: Bool { money.minorUnits > 0 }
    public var id: Currency { money.currency }
  }

  public let currency: Currency
  public let owedToMe: Money
  public let iOwe: Money
  public let owedToMeText: String
  public let iOweText: String
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
        id: person.personKey, name: person.personName,
        balances: person.balances.map { money in
          Balance(
            money: money, amountText: format.magnitude(money), directionText: money.minorUnits > 0 ? "owes you" : "you owe")
        },
        convertedText: person.balances.count > 1 || person.balances.first?.currency != currency
          ? person.converted.map { "≈ " + format.signed($0) } : nil)
    }
    return DashboardDebts(
      currency: currency, owedToMe: summary.owedToMe, iOwe: summary.iOwe,
      owedToMeText: format.money(summary.owedToMe), iOweText: format.money(summary.iOwe), people: people,
      missing: missing)
  }
}
