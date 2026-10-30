import AbacusDomain
import Foundation

/// The display sign of debts (R-DEBT-21, D61), in one place. Stored balances keep their sign
/// (positive = they owe me, R-DEBT-2); what the owner sees is flipped: money they owe me is
/// **negative and red** ("you lent", it left my pocket), money I owe is **positive and green**
/// ("you borrowed"). Nothing here touches stored data.
public enum DebtSign {
  public enum Tone: Sendable, Hashable {
    /// Stored positive: they owe me.
    case lent
    /// Stored negative: I owe them.
    case borrowed
    case settled
  }

  public static func tone(stored minor: Int64) -> Tone {
    minor > 0 ? .lent : minor < 0 ? .borrowed : .settled
  }

  public static func tone(_ stored: Money) -> Tone { tone(stored: stored.minorUnits) }

  /// "you lent" / "you borrowed" / "settled up".
  public static func label(_ tone: Tone) -> String {
    switch tone {
    case .lent: "you lent"
    case .borrowed: "you borrowed"
    case .settled: "settled up"
    }
  }

  public static func label(stored minor: Int64) -> String { label(tone(stored: minor)) }

  /// The amount as shown: the stored one with its sign flipped.
  public static func display(_ stored: Money) -> Money { stored.negated }
  public static func display(stored minor: Int64) -> Int64 { -minor }

  /// What a user types in a form (display sign) back to the stored sign, and the reverse.
  public static func stored(display minor: Int64) -> Int64 { -minor }

  /// "−€260.00" for money they owe me, "+€50.00" for money I owe, no sign for zero. `magnitude`
  /// formats a non-negative amount (the formatter of the screen).
  public static func text(stored money: Money, magnitude: (Money) -> String) -> String {
    let abs = money.minorUnits < 0 ? money.negated : money
    switch tone(money) {
    case .lent: return "−" + magnitude(abs)
    case .borrowed: return "+" + magnitude(abs)
    case .settled: return magnitude(abs)
    }
  }

  /// A header/widget total of one direction, given as a positive amount: "You lent" is shown
  /// negative, "You borrowed" positive; zero without a sign.
  public static func lentTotalText(_ amount: Money, magnitude: (Money) -> String) -> String {
    amount.minorUnits == 0 ? magnitude(amount) : "−" + magnitude(amount)
  }

  public static func borrowedTotalText(_ amount: Money, magnitude: (Money) -> String) -> String {
    amount.minorUnits == 0 ? magnitude(amount) : "+" + magnitude(amount)
  }

  /// The small secondary caption of a debt row (R-DEBT-21): the per-currency amounts in the display
  /// sign, no "lent/borrowed" labels, joined by " · ". Only when the debt has more than one
  /// non-zero currency; nil otherwise.
  public static func caption(_ balances: [Money], magnitude: (Money) -> String) -> String? {
    let open = balances.filter { $0.minorUnits != 0 }
    guard open.count > 1 else { return nil }
    return open.map { text(stored: $0, magnitude: magnitude) }.joined(separator: " · ")
  }

  public static let lentTitle = "You lent"
  public static let borrowedTitle = "You borrowed"
}
