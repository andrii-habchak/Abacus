import AbacusDomain
import Foundation

/// "12 Oct" (with the year when it is not the year of the refund's own date).
struct RefundNoteDates {
  let short: DateFormatter
  let long: DateFormatter

  init(calendar: Calendar, locale: Locale) {
    func make(_ pattern: String) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = pattern
      return formatter
    }
    short = make("d MMM")
    long = make("d MMM yyyy")
  }
}

extension TransactionListContent.Builder {
  /// Fills the refund text and jump target of a row from the links of its page (C30): an expense
  /// says how much of it came back (the refunds converted to its currency at each refund's date),
  /// a linked refund names its original.
  func refundNote(
    for txn: Txn, links: RefundLinkSummary, dates: RefundNoteDates, into row: inout TransactionListContent.Row
  ) {
    if txn.isLinkedRefund, let original = links.originalByRefund[txn.id] {
      let title = original.payee.isEmpty ? "an expense" : original.payee
      let sameYear = calendar.component(.year, from: original.occurredAt) == calendar.component(.year, from: txn.occurredAt)
      let day = (sameYear ? dates.short : dates.long).string(from: original.occurredAt)
      row.refundNote = "Refund of \(title) · \(day)"
      row.refundJumpID = original.originalID
      row.isLinkedRefund = true
      return
    }
    guard txn.type == .expense, !txn.isRefund, let refunds = links.refundsByOriginal[txn.id], !refunds.isEmpty,
      let currency = reference.accountsByID[txn.accountID]?.currency
    else { return }
    var refunded: Int64 = 0
    for refund in refunds {
      let money = Money(minorUnits: refund.amountMinor, currency: refund.currency)
      if let converted = converter.convert(money, to: currency, on: Day(refund.occurredAt, calendar: calendar)) {
        refunded += converted.minorUnits
      }
    }
    let code = currency.rawValue
    if refunded >= txn.amountMinor {
      row.refundNote = "Refunded " + format.string(minor: refunded, code: code)
    } else {
      row.refundNote =
        "Partly refunded " + format.string(minor: refunded, code: code) + " of "
        + format.string(minor: txn.amountMinor, code: code)
    }
    row.refundJumpID = refunds.first?.refundID
  }
}
