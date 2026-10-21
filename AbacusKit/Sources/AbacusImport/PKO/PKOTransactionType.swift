import Foundation

/// `Typ transakcji` values from `docs/import/pko-format.md`.
public enum PKOTransactionType: Hashable, Sendable {
  /// `Płatność kartą`: expense, refund when positive.
  case cardPayment
  /// `Płatność web - kod mobilny` (BLIK online): expense, refund when positive.
  case webPayment
  /// `Przelew z rachunku`: outgoing transfer to someone; sign decides.
  case outgoingTransfer
  /// `Przelew na konto`: incoming transfer; sign decides.
  case incomingTransfer
  /// `Przelew na telefon …` (BLIK phone transfer): sign decides.
  case phoneTransfer
  /// `Wypłata w bankomacie …`: transfer to a cash account.
  case atmWithdrawal
  /// `WYMIANA W KANTORZE - …`: in-bank currency exchange, one half of a transfer.
  case currencyExchange
  /// `Blokada`: pending card hold (R-IMP-PKO-2).
  case hold
  /// Anything else: kind from the sign, flagged for review.
  case unknown(String)

  public init(_ raw: String) {
    let text = raw.pkoCollapsed
    let lower = text.lowercased()
    func starts(_ prefix: String) -> Bool { lower.hasPrefix(prefix) }
    if lower == "blokada" {
      self = .hold
    } else if starts("płatność kartą") {
      self = .cardPayment
    } else if starts("płatność web") {
      self = .webPayment
    } else if starts("przelew z rachunku") {
      self = .outgoingTransfer
    } else if starts("przelew na konto") {
      self = .incomingTransfer
    } else if starts("przelew na telefon") {
      self = .phoneTransfer
    } else if starts("wypłata w bankomacie") {
      self = .atmWithdrawal
    } else if starts("wymiana w kantorze") {
      self = .currencyExchange
    } else {
      self = .unknown(text)
    }
  }
}
