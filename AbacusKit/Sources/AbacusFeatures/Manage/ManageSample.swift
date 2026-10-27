import AbacusDomain
import Foundation

/// Synthetic additions to `PreviewData` for the management screens, mirroring the approved
/// prototype: categorisation rules, an event budget, an ongoing "Car" event and a few tagged
/// transactions. Never real data (R-NF-6). Ids 9xx.
public enum ManageSample {
  static func id(_ n: Int) -> UUID { PreviewData.id(n) }

  static func at(_ day: String) -> Date {
    Day(day)!.date().addingTimeInterval(12 * 3600)
  }

  /// The Lyon trip with a €300 budget, Relocation and Car without dates.
  public static let lyonTrip: Event = {
    var event = PreviewData.lyonTrip
    event.budgetMinor = 300_00
    event.budgetCurrency = .EUR
    return event
  }()

  public static let car = Event(id: id(901), name: "Car")
  public static let events = [lyonTrip, PreviewData.relocation, car]

  public static let extraTxns: [Txn] = [
    Txn(
      id: id(911), type: .expense, occurredAt: at("2026-09-12"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 850_00, categoryID: PreviewData.id(206), payee: "Car service", eventID: car.id, createdAt: at("2026-09-12")),
    Txn(
      id: id(912), type: .expense, occurredAt: at("2026-10-02"), accountID: PreviewData.pkoCreditCard.id,
      amountMinor: 180_00, categoryID: PreviewData.id(208), payee: "Orlen", eventID: car.id, createdAt: at("2026-10-02")),
    Txn(
      id: id(913), type: .expense, occurredAt: at("2026-09-05"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 1_420_00, categoryID: PreviewData.id(205), payee: "Moving company", eventID: PreviewData.relocation.id,
      createdAt: at("2026-09-05")),
    Txn(
      id: id(914), type: .expense, occurredAt: at("2026-09-06"), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 40_00, categoryID: PreviewData.id(213), payee: "Registration fee", eventID: PreviewData.relocation.id,
      createdAt: at("2026-09-06")),
  ]

  /// "Description contains" rules as in the prototype (R-IMP-8), first match wins.
  public static let rules: [CategoryRule] = [
    CategoryRule(id: id(951), pattern: "biedronka", categoryID: PreviewData.id(202), origin: .imported, hitCount: 41, position: 0),
    CategoryRule(id: id(952), pattern: "lidl", categoryID: PreviewData.id(202), origin: .imported, hitCount: 18, position: 1),
    CategoryRule(id: id(953), pattern: "bolt.eu", categoryID: PreviewData.id(207), origin: .imported, hitCount: 26, position: 2),
    CategoryRule(
      id: id(954), pattern: "orlen", accountID: PreviewData.pkoCreditCard.id, categoryID: PreviewData.id(208), origin: .manual,
      hitCount: 9, position: 3),
    CategoryRule(id: id(955), pattern: "orange", categoryID: PreviewData.id(211), origin: .imported, hitCount: 12, position: 4),
    CategoryRule(id: id(956), pattern: "farmacja", categoryID: PreviewData.id(209), origin: .imported, hitCount: 7, position: 5),
    // Saldo-like rules (D44): an amount condition, an exact match, a transfer action.
    CategoryRule(
      id: id(957), pattern: "zalando", amountComparison: .biggerThan, amountMinor: 100_00,
      categoryID: PreviewData.id(212), origin: .manual, hitCount: 2, position: 6),
    CategoryRule(
      id: id(958), pattern: "pizzeria napoli", matchKind: .exactly, accountID: PreviewData.monobank.id,
      categoryID: PreviewData.id(203), origin: .manual, hitCount: 1, position: 7),
    CategoryRule(
      id: id(959), pattern: "friend", action: .transfer, transferAccountID: PreviewData.loanFromFriend.id,
      origin: .manual, position: 8),
  ]
}
