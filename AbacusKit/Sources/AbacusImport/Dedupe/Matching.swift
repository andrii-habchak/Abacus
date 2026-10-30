import AbacusDomain
import Foundation

/// Bank account numbers as PKO writes them (`counterpartyIBAN`: 26 digits, no spaces, no `PL`)
/// and as users type them into `Account.iban` (R-ACC-1, R-IMP-PKO-3).
public enum AccountNumber {
  /// Uppercased, without spaces or dashes, without the `PL` country prefix.
  public static func normalized(_ raw: String) -> String {
    var compact = raw.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    if compact.hasPrefix("PL"), compact.dropFirst(2).allSatisfy(\.isNumber) {
      compact.removeFirst(2)
    }
    return compact
  }
}

/// "Similar description" for fuzzy dedupe (R-IMP-4). Sources describe the same purchase very
/// differently (Saldo: what the user typed, PKO: the card terminal's merchant string), so the
/// test is generous: one text contains the other, or they share a word of four or more
/// characters (or one such word starts the other).
public enum DescriptionSimilarity {
  /// Lowercased words without diacritics, split on anything that is not a letter or digit.
  public static func words(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }

  public static func isSimilar(_ a: String, _ b: String) -> Bool {
    let wa = words(a)
    let wb = words(b)
    // Nothing to compare: no evidence against.
    if wa.isEmpty || wb.isEmpty { return true }
    let ja = wa.joined(separator: " ")
    let jb = wb.joined(separator: " ")
    if ja.contains(jb) || jb.contains(ja) { return true }
    let significant = { (w: String) in w.count >= 4 && w.contains(where: \.isLetter) }
    let sa = Set(wa.filter(significant))
    let sb = Set(wb.filter(significant))
    if !sa.isDisjoint(with: sb) { return true }
    for x in sa {
      for y in sb where x.hasPrefix(y) || y.hasPrefix(x) { return true }
    }
    return false
  }
}

/// How a transaction moves money on one account.
public enum Flow: Equatable, Sendable {
  case out, `in`

  /// The flow of `txn` on `accountID`, or nil when it does not touch the account.
  public static func of(_ txn: Txn, on accountID: Account.ID) -> Flow? {
    if txn.accountID == accountID {
      switch txn.type {
      case .expense: return txn.isRefund ? .in : .out
      case .income: return txn.isRefund ? .out : .in
      // A debt leg without destination marked `isRefund` brings money in (C14); a transfer
      // between my accounts takes it out of its source.
      case .transfer: return txn.isOneSidedInflow ? .in : .out
      }
    }
    if txn.type == .transfer, txn.toAccountID == accountID { return .in }
    return nil
  }
}

/// Pending PKO hold → settled row (R-IMP-PKO-2): same account, value day ± 3, same merchant,
/// amount equal or within 5 %.
public enum PendingSettlement {
  public static let dayWindow = 3
  public static let amountTolerancePercent: Int64 = 5

  public static func amountMatches(pending: Int64, settled: Int64) -> Bool {
    abs(settled - pending) * 100 <= amountTolerancePercent * max(pending, settled)
  }

  /// Merchants match when their normalised texts are equal or similar; an empty one never does.
  public static func merchantMatches(_ a: String, _ b: String) -> Bool {
    let wa = DescriptionSimilarity.words(a)
    let wb = DescriptionSimilarity.words(b)
    if wa.isEmpty || wb.isEmpty { return false }
    return wa == wb || DescriptionSimilarity.isSimilar(a, b)
  }
}

/// Fuzzy cross-source duplicate rule (R-IMP-4): same account, same amount (same currency, as
/// the account fixes it), the other transaction from another source or typed by hand, dates at
/// most three days apart, and a similar description.
///
/// Descriptions of one payment differ a lot between sources ("ATM" typed in Saldo vs the
/// terminal's "BANKOMAT CENTRUM"), and a missed duplicate silently double-counts while a flagged
/// one is shown and can be imported with one click. So the description is not required when the
/// dates are the same day or the existing transaction is a transfer.
public enum FuzzyDuplicate {
  public static let dayWindow = 3

  public static func matches(
    rowSource: ImportSource, rowPayee: String, rowDay: Day, candidate: Txn, candidateDay: Day,
    calendar: Calendar
  ) -> Bool {
    guard candidate.source.rawValue != rowSource.rawValue else { return false }
    let gap = abs(rowDay.distance(to: candidateDay, calendar: calendar))
    guard gap <= dayWindow else { return false }
    return gap == 0 || candidate.type == .transfer || DescriptionSimilarity.isSimilar(rowPayee, candidate.payee)
  }
}

/// A bank row for a payment already entered as a transfer to a person's account (R-DEBT-13,
/// R-DEBT-19): a transfer between one of my accounts and a linked account of a debt, on the
/// account the row touches, same amount in that account's currency, same direction, at most
/// three days apart, any description. The transfer must come from another source than the row: one
/// made from this bank's own row carries its fingerprint (an exact match), and two equal
/// payments a day apart must not swallow each other.
public enum DebtLegMatch {
  public static let dayWindow = 3

  /// The debt a transfer moves money to or from: one side is a linked account of a debt, the
  /// other is not (mine). Nil for anything else.
  public static func debt(of txn: Txn, in book: DebtBook) -> Debt? {
    guard txn.type == .transfer, let toAccountID = txn.toAccountID else { return nil }
    let from = book.debtID(ofAccount: txn.accountID)
    let to = book.debtID(ofAccount: toAccountID)
    guard (from == nil) != (to == nil), let id = from ?? to else { return nil }
    return book.debt(id)
  }

  public static func matches(
    rowSource: ImportSource, rowDay: Day, candidate: Txn, candidateDay: Day, book: DebtBook, calendar: Calendar
  ) -> Bool {
    guard debt(of: candidate, in: book) != nil, candidate.source.rawValue != rowSource.rawValue else { return false }
    return abs(rowDay.distance(to: candidateDay, calendar: calendar)) <= dayWindow
  }
}

extension Day {
  /// Whole days from `self` to `other` (positive when `other` is later).
  func distance(to other: Day, calendar: Calendar) -> Int {
    calendar.dateComponents([.day], from: date(calendar: calendar), to: other.date(calendar: calendar)).day ?? 0
  }
}
