import AbacusDomain
import Foundation

// C38: the other side of a transfer to an own account in another currency.
//
// 1. A PKO row whose counterparty is an own account in another currency has no known amount on
//    the other account. When the user makes it a transfer, the preview takes the other side from
//    a `TransferCounterpart`: a transaction found on the other account (it is absorbed: it becomes
//    the transfer, undo restores it), an amount typed by hand, or an estimate at the day's rate
//    (the transfer is flagged `isEstimatedTransferAmount`).
// 2. A later import row on the other account that matches an existing estimated transfer is
//    offered as its real figure ("Looks like the other side of the transfer on …"); accepting it
//    completes that transfer and creates no second transaction.

/// The other side the user gave a transfer to an own account whose amount the file does not state.
public struct TransferCounterpart: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// A transaction already on the other account (imported from its statement as income/expense):
    /// it becomes the transfer.
    case existing(Txn)
    /// Typed by the user.
    case manual
    /// Computed at the rate of `rate` (1 unit of the row's currency in the other currency); the
    /// transfer is flagged as estimated.
    case estimated(rate: Decimal)
  }

  public var accountID: Account.ID
  public var kind: Kind
  /// Positive, in the other account's currency: what arrived on (outgoing row) or left (incoming
  /// row) the other account.
  public var amountMinor: Int64

  public init(accountID: Account.ID, kind: Kind, amountMinor: Int64) {
    self.accountID = accountID
    self.kind = kind
    self.amountMinor = amountMinor
  }
}

/// An existing transfer with an estimated amount a later import row may be the real figure of.
public struct ImportEstimatedTransfer: Hashable, Sendable {
  public var txn: Txn
  /// The estimated side's amount, in the row account's currency.
  public var estimatedMinor: Int64
  public var currency: Currency
  /// Name of the transfer's other account, for the line shown to the user.
  public var otherAccountName: String

  public init(txn: Txn, estimatedMinor: Int64, currency: Currency, otherAccountName: String = "") {
    self.txn = txn
    self.estimatedMinor = estimatedMinor
    self.currency = currency
    self.otherAccountName = otherAccountName
  }
}

public enum ImportEstimateDecision: Hashable, Sendable {
  /// The row is the real figure of the transfer.
  case accepted(ImportEstimatedTransfer)
  /// "Not this": an ordinary row, no offer again.
  case declined
}

/// The row's facts the counterpart search and the amount estimate need.
public struct CounterpartProbe: Hashable, Sendable {
  public var rowID: String
  /// The other account the row's transfer goes to or comes from.
  public var targetAccountID: Account.ID
  public var targetCurrency: Currency
  public var rowCurrency: Currency
  /// The row's amount in its own account's currency, positive.
  public var amountMinor: Int64
  /// Money comes into the row's account (so the counterpart on the other account is money out).
  public var isInflow: Bool
  public var occurredAt: Date
  public var payee: String
}

/// A candidate with the numbers it was ranked by.
public struct ImportCounterpartOption: Hashable, Identifiable, Sendable {
  public var candidate: TransferCounterpartCandidate
  /// The candidate's amount on the other account.
  public var amountMinor: Int64
  /// The rate the pair implies: 1 unit of the row's currency = this many of the other currency.
  public var impliedRate: Decimal
  /// The row's amount converted at the known rate; nil without a rate.
  public var expectedMinor: Int64?
  /// How far the candidate is from `expectedMinor`, as a fraction of it; nil without a rate.
  public var deviation: Double?
  /// Days between the row and the candidate.
  public var dayGap: Int
  public var id: Txn.ID { candidate.txn.id }
}

// MARK: - Ranking

/// Ranks the transactions of the other account as candidates for the other side of a row's
/// transfer: opposite direction, closest to the row's amount at the known rate, then closest in
/// time. Candidates that cannot be absorbed come last.
public enum TransferCounterpartRanker {
  /// Days either side of the row that are searched (a transfer posts a few days apart).
  public static let dayWindow = 5
  /// The wider window once the user types a search text.
  public static let searchDayWindow = 60

  public static func rank(
    _ candidates: [TransferCounterpartCandidate], probe: CounterpartProbe, converter: (any CurrencyConverter)?,
    calendar: Calendar, matching search: String = "", limit: Int = 30
  ) -> [ImportCounterpartOption] {
    let rowDay = Day(probe.occurredAt, calendar: calendar)
    let needle = fold(search)
    let numeric = Self.number(needle)
    let expected = expectedMinor(probe, converter: converter, day: rowDay)
    var options: [ImportCounterpartOption] = []
    for candidate in candidates {
      let txn = candidate.txn
      guard let flow = Flow.of(txn, on: probe.targetAccountID), flow == (probe.isInflow ? .out : .in) else { continue }
      let amount = side(of: txn, on: probe.targetAccountID)
      guard amount > 0 else { continue }
      if !needle.isEmpty {
        let text = fold(txn.payee + " " + txn.note)
        let amountText = String(format: "%lld.%02lld", amount / 100, amount % 100)
        guard text.contains(needle) || (numeric.map { amountText.contains($0) } ?? false) else { continue }
      }
      let rate = Decimal(amount) / Decimal(max(probe.amountMinor, 1))
      var deviation: Double?
      if let expected, expected > 0 {
        deviation = abs(Double(amount - expected)) / Double(expected)
      }
      options.append(
        ImportCounterpartOption(
          candidate: candidate, amountMinor: amount, impliedRate: rate, expectedMinor: expected, deviation: deviation,
          dayGap: abs(rowDay.distance(to: Day(txn.occurredAt, calendar: calendar), calendar: calendar))))
    }
    options.sort { a, b in
      let ka = (a.candidate.refusal == nil ? 0 : 1, a.deviation ?? .infinity, a.dayGap, a.candidate.txn.occurredAt)
      let kb = (b.candidate.refusal == nil ? 0 : 1, b.deviation ?? .infinity, b.dayGap, b.candidate.txn.occurredAt)
      if ka != kb { return ka < kb }
      return a.id.uuidString < b.id.uuidString
    }
    return Array(options.prefix(max(0, limit)))
  }

  /// The row's amount in the other currency at the day's rate (the latest known when the day has
  /// none); nil without a converter or a rate.
  static func expectedMinor(_ probe: CounterpartProbe, converter: (any CurrencyConverter)?, day: Day) -> Int64? {
    if probe.rowCurrency == probe.targetCurrency { return probe.amountMinor }
    return estimate(amountMinor: probe.amountMinor, from: probe.rowCurrency, to: probe.targetCurrency, day: day, converter: converter)?
      .amountMinor
  }

  /// `amountMinor` converted at the rate of `day`, with the rate used.
  public static func estimate(
    amountMinor: Int64, from: Currency, to: Currency, day: Day, converter: (any CurrencyConverter)?
  ) -> (amountMinor: Int64, rate: Decimal)? {
    guard let converter, let rate = converter.rate(from: from, to: to, on: day) ?? converter.latestRate(from: from, to: to),
      rate > 0
    else { return nil }
    return (Money(Money(minorUnits: amountMinor, currency: from).decimal * rate, to).minorUnits, rate)
  }

  /// The transaction's amount on `accountID` (the sending or the receiving side of a transfer).
  static func side(of txn: Txn, on accountID: Account.ID) -> Int64 {
    if txn.type == .transfer, txn.toAccountID == accountID, txn.accountID != accountID {
      return txn.toAmountMinor ?? txn.amountMinor
    }
    return txn.amountMinor
  }

  private static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  /// A search text that is an amount ("100", "100,5"): digits and one separator, as written with a dot.
  private static func number(_ text: String) -> String? {
    guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }
    return text.replacingOccurrences(of: ",", with: ".")
  }
}

// MARK: - Later import: matching an estimated transfer

/// Finds the estimated transfer a row is the real figure of.
public enum EstimatedTransferMatcher {
  public static let dayWindow = 5
  /// The row's amount may differ from the estimate by this fraction of the estimate.
  public static let tolerance = 0.05

  /// The side of `txn` the row (on `accountID`, moving money `flow`) is: the receiving side for
  /// money in, the sending side for money out; nil when `txn` does not touch the account that way.
  static func side(of txn: Txn, accountID: Account.ID, flow: Flow) -> TransferSide? {
    guard txn.type == .transfer, txn.isEstimatedTransferAmount, txn.toAccountID != nil, txn.toAccountID != txn.accountID
    else { return nil }
    switch flow {
    case .in: return txn.toAccountID == accountID ? .to : nil
    case .out: return txn.accountID == accountID ? .from : nil
    }
  }

  static func amount(of txn: Txn, side: TransferSide) -> Int64 {
    switch side {
    case .from: txn.amountMinor
    case .to: txn.toAmountMinor ?? txn.amountMinor
    }
  }

  /// The transfers in `transfers` the row may complete, best first: amount within the tolerance of
  /// the estimate, then the closest in amount and in time.
  static func matches(
    _ transfers: [Txn], accountID: Account.ID, flow: Flow, amountMinor: Int64, occurredAt: Date, calendar: Calendar
  ) -> [(txn: Txn, side: TransferSide)] {
    let rowDay = Day(occurredAt, calendar: calendar)
    var found: [(txn: Txn, side: TransferSide, gap: Int, diff: Int64)] = []
    for txn in transfers {
      guard let side = side(of: txn, accountID: accountID, flow: flow) else { continue }
      let estimate = amount(of: txn, side: side)
      guard estimate > 0, Double(abs(amountMinor - estimate)) <= tolerance * Double(estimate) else { continue }
      let gap = abs(rowDay.distance(to: Day(txn.occurredAt, calendar: calendar), calendar: calendar))
      guard gap <= dayWindow else { continue }
      found.append((txn, side, gap, abs(amountMinor - estimate)))
    }
    found.sort { ($0.diff, $0.gap, $0.txn.occurredAt) < ($1.diff, $1.gap, $1.txn.occurredAt) }
    return found.map { ($0.txn, $0.side) }
  }
}

// MARK: - Preview API

extension ImportPreview {
  /// Whether making the row a transfer to `accountID` needs the other side from the user: another
  /// currency and no amount in it in the file. Applies to a new expense/income row and to a
  /// Needs review row that offers "Transfer to my account".
  public func needsCounterpart(row id: String, to accountID: Account.ID) -> Bool {
    guard counterpartRowIsEligible(id), let row = row(id), let other = context.account(accountID), !other.isArchived,
      row.account != .existing(accountID), let own = currency(of: row.account), other.currency != own
    else { return false }
    if row.isInflow, !row.source.lines.isEmpty { return false }
    return Self.knownAmount(of: row.source, in: other.currency, accountCurrency: own) == nil
  }

  /// The facts of the row's transfer to `accountID` for the "Find the other side…" sheet.
  public func counterpartProbe(forRow id: String, to accountID: Account.ID) -> CounterpartProbe? {
    guard counterpartRowIsEligible(id), let row = row(id), let other = context.account(accountID), !other.isArchived,
      row.account != .existing(accountID), let own = currency(of: row.account)
    else { return nil }
    return CounterpartProbe(
      rowID: id, targetAccountID: accountID, targetCurrency: other.currency, rowCurrency: own, amountMinor: row.amountMinor,
      isInflow: row.isInflow, occurredAt: row.source.occurredAt, payee: row.source.payee)
  }

  /// The row's amount in the other account's currency at the day's rate, with the rate; nil when no
  /// rate is known (or the currencies are the same).
  public func estimatedCounterpart(forRow id: String, to accountID: Account.ID) -> (amountMinor: Int64, rate: Decimal)? {
    guard let probe = counterpartProbe(forRow: id, to: accountID), probe.rowCurrency != probe.targetCurrency else { return nil }
    return TransferCounterpartRanker.estimate(
      amountMinor: probe.amountMinor, from: probe.rowCurrency, to: probe.targetCurrency,
      day: Day(probe.occurredAt, calendar: calendar), converter: converter)
  }

  /// Existing transactions another row of this import already settles, links or converts: never
  /// offered as the other side.
  public var touchedExistingTxnIDs: Set<Txn.ID> {
    var ids = Set<Txn.ID>()
    for plan in plans {
      switch plan {
      case .settle(let txn, _), .link(let txn, _), .convert(let txn, _), .completeEstimate(let txn, _, _, _): ids.insert(txn.id)
      case .nothing, .openingBalance, .create: break
      }
    }
    return ids
  }

  /// Makes the row a transfer to (money out) or from (money in) the own account of `counterpart`,
  /// with the other side the user gave. False when the row cannot (another account than the
  /// counterpart's, attached records with a found transaction, a transaction on the wrong account).
  @discardableResult
  public mutating func setTransfer(toAccount accountID: Account.ID, counterpart: TransferCounterpart, forRow id: String) -> Bool {
    guard counterpart.accountID == accountID, counterpart.amountMinor > 0, counterpartRowIsEligible(id), let row = row(id),
      let other = context.account(accountID), !other.isArchived, row.account != .existing(accountID)
    else { return false }
    if case .existing(let txn) = counterpart.kind {
      guard row.source.lines.isEmpty, txn.accountID == accountID || txn.toAccountID == accountID else { return false }
    }
    if row.review != nil {
      decisions.counterparts[id] = counterpart
      applyReviewChoice(.transfer(accountID: accountID), forRow: id)
    } else {
      decisions.counterparts[id] = counterpart
      decisions.transfers[id] = accountID
      decisions.categories[id] = nil
      decisions.debts[id] = nil
    }
    recompute()
    return true
  }

  /// Rows that can take a transfer with a given other side: a new expense/income (also a possible
  /// duplicate imported anyway, or a row that already is such a transfer), or a Needs review row
  /// that offers "Transfer to my account".
  private func counterpartRowIsEligible(_ id: String) -> Bool {
    guard let row = row(id), row.source.kind != .openingBalance else { return false }
    if let review = row.review {
      switch review.reason {
      case .unknownOperationType, .transferAmountUnknown: return true
      case .unpairedTransferHalf: return false
      }
    }
    guard row.createsTransaction || row.absorbedTxn != nil else { return false }
    return row.type == .expense || row.type == .income || row.type == .transfer
  }

  // MARK: Estimated transfers of an earlier import

  /// The facts of every row that can be offered as the real figure of an estimated transfer: a new
  /// income/expense on an existing account without attached records, or a Needs review row whose
  /// transfer amount is unknown. Independent of the user's choices.
  public var estimateProbes: [(rowID: String, accountID: Account.ID, isInflow: Bool, amountMinor: Int64, occurredAt: Date)] {
    var result: [(String, Account.ID, Bool, Int64, Date)] = []
    for (i, source) in parsedRows.enumerated() where i < analysis.count {
      let found = analysis[i]
      guard found.exactTxnID == nil, found.settles == nil, found.sameTransfer == nil, found.completesTransfer == nil,
        found.debtLeg == nil, found.duplicate == nil, source.kind == .expense || source.kind == .income,
        source.lines.isEmpty, source.amountMinor > 0, let flow = source.flow
      else { continue }
      if let reason = found.review {
        guard case .transferAmountUnknown = reason else { continue }
      }
      guard case .existing(let accountID) = accountRef(source.account) else { continue }
      result.append((source.id, accountID, flow == .in, source.amountMinor, source.occurredAt))
    }
    return result
  }

  mutating func setExistingEstimateOffers(_ offers: [String: ImportEstimatedTransfer]) {
    existingEstimateOffers = offers
    recompute()
  }

  /// "Accept": the row is the real figure of the offered transfer. False when it no longer fits.
  @discardableResult
  public mutating func acceptEstimate(forRow id: String) -> Bool {
    guard let offer = row(id)?.estimateOffer ?? existingEstimateOffers[id] else { return false }
    decisions.estimates[id] = .accepted(offer)
    recompute()
    return row(id)?.estimateLink != nil
  }

  /// "Not this": an ordinary row again, and the offer does not come back.
  public mutating func declineEstimate(forRow id: String) {
    decisions.estimates[id] = .declined
    recompute()
  }

  /// Back to undecided: the offer comes back.
  public mutating func resetEstimate(forRow id: String) {
    decisions.estimates[id] = nil
    recompute()
  }
}

// MARK: - Pipeline

extension ImportPipeline {
  /// The ranked transactions of `accountID` that may be the other side of row `rowID`'s transfer.
  /// Within ±5 days; a search text widens the window to ±60 days and filters by description, note
  /// and amount. Empty without a counterpart repository.
  public func counterpartOptions(
    for preview: ImportPreview, row rowID: String, to accountID: Account.ID, matching search: String = "", limit: Int = 30
  ) async throws -> [ImportCounterpartOption] {
    guard let counterparts, let probe = preview.counterpartProbe(forRow: rowID, to: accountID) else { return [] }
    let day = Day(probe.occurredAt, calendar: calendar)
    let window = search.trimmingCharacters(in: .whitespaces).isEmpty
      ? TransferCounterpartRanker.dayWindow : TransferCounterpartRanker.searchDayWindow
    let found = try await counterparts.counterpartCandidates(
      accountID: accountID, from: day.adding(days: -window, calendar: calendar), to: day.adding(days: window, calendar: calendar))
    let touched = preview.touchedExistingTxnIDs
    return TransferCounterpartRanker.rank(
      found.filter { !touched.contains($0.txn.id) }, probe: probe, converter: await converter(), calendar: calendar,
      matching: search, limit: limit)
  }

  /// Looks for the existing estimated transfer each eligible row is the real figure of and stores
  /// the best match per row (a transfer is offered to one row only). Read-only; a failing search
  /// leaves the rows without an offer.
  func suggestEstimateMatches(_ preview: inout ImportPreview) async {
    guard let counterparts else { return }
    var offers: [String: ImportEstimatedTransfer] = [:]
    var taken = Set<Txn.ID>()
    let names = Dictionary(preview.context.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    for probe in preview.estimateProbes {
      let day = Day(probe.occurredAt, calendar: calendar)
      guard let transfers = try? await counterparts.estimatedTransfers(
        accountID: probe.accountID,
        from: day.adding(days: -EstimatedTransferMatcher.dayWindow, calendar: calendar),
        to: day.adding(days: EstimatedTransferMatcher.dayWindow, calendar: calendar)),
        let currency = preview.context.account(probe.accountID)?.currency
      else { continue }
      let matches = EstimatedTransferMatcher.matches(
        transfers.filter { !taken.contains($0.id) }, accountID: probe.accountID, flow: probe.isInflow ? .in : .out,
        amountMinor: probe.amountMinor, occurredAt: probe.occurredAt, calendar: calendar)
      guard let best = matches.first else { continue }
      taken.insert(best.txn.id)
      let otherID = best.side == .to ? best.txn.accountID : best.txn.toAccountID
      offers[probe.rowID] = ImportEstimatedTransfer(
        txn: best.txn, estimatedMinor: EstimatedTransferMatcher.amount(of: best.txn, side: best.side), currency: currency,
        otherAccountName: otherID.flatMap { names[$0] } ?? "")
    }
    preview.setExistingEstimateOffers(offers)
  }
}
