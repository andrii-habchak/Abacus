import AbacusDomain
import Foundation

/// Why a row waits in *needs review* (R-IMP-5).
public enum ReviewReason: Hashable, Sendable {
  /// A transfer half without its other half (R-IMP-SALDO-2, D26) or a PKO currency exchange
  /// whose other account is unknown.
  case unpairedTransferHalf(TransferHalf.Direction)
  /// A PKO operation type the importer does not know; the sign gave expense/income.
  case unknownOperationType
  /// A transfer to an own account in another currency whose received amount is unknown.
  case transferAmountUnknown
}

/// A transfer between the imported account and another own account found by its account
/// number (R-IMP-PKO-3).
struct OwnTransfer: Hashable, Sendable {
  var from: AccountRef
  var to: AccountRef
  var amountMinor: Int64
  var toAmountMinor: Int64?
  var ownAccountID: Account.ID
}

/// The store-dependent findings for one row. Recomputed when an account mapping changes.
struct RowAnalysis: Sendable {
  /// R-IMP-3: one of the row's fingerprints is stored.
  var exactTxnID: Txn.ID?
  /// R-IMP-PKO-2: the pending hold this settled row upgrades.
  var settles: Txn?
  var ownTransfer: OwnTransfer?
  /// The other side of an own-account transfer already imported from the other account's
  /// statement: the same transfer (link) or an expense/income that becomes the transfer.
  var sameTransfer: Txn?
  var completesTransfer: Txn?
  /// R-IMP-4: the existing transaction this row probably duplicates.
  var duplicate: Txn?
  var review: ReviewReason?
  /// Unpaired halves of this file the user may pair this one with, best first.
  var pairRows: [String] = []
  /// Existing expenses that may be the other side of an incoming half.
  var pairExisting: [Txn] = []
}

/// Flow of a row on its own account.
extension NormalizedRow {
  var flow: Flow? {
    switch kind {
    case .expense: return isRefund ? .in : .out
    case .income: return isRefund ? .out : .in
    case .transferHalf: return transferHalf?.direction == .incoming ? .in : .out
    case .transfer: return .out
    case .openingBalance: return nil
    }
  }

  var isUnknownPKOType: Bool {
    warnings.contains { $0.hasPrefix("Unknown PKO transaction type") }
  }
}

struct RowAnalyzer {
  let rows: [NormalizedRow]
  let source: ImportSource
  let context: ImportContext
  let accountRefs: [String: AccountRef]
  let targetAccountID: Account.ID?
  let store: any ImportStore
  let calendar: Calendar

  func ref(_ account: ExternalAccount) -> AccountRef {
    if let id = account.resolvedID { return .existing(id) }
    return accountRefs[account.key] ?? .new(key: account.key)
  }

  func day(_ row: NormalizedRow) -> Day { row.valueDay ?? Day(row.occurredAt, calendar: calendar) }

  func window(_ day: Day, _ days: Int) -> (Day, Day) {
    (day.adding(days: -days, calendar: calendar), day.adding(days: days, calendar: calendar))
  }

  /// A match competing for an existing transaction; each transaction serves one row.
  private struct Claim {
    enum Kind: Int { case settle = 0, sameTransfer, completes, duplicate }
    var row: Int
    var kind: Kind
    var txn: Txn
    var dayGap: Int
    var amountGap: Int64
  }

  func run() async throws -> [RowAnalysis] {
    var result = Array(repeating: RowAnalysis(), count: rows.count)

    // R-IMP-3: exact matches, one lookup for the whole file.
    let existing = try await store.existingFingerprints(rows.flatMap(\.fingerprints))
    for (i, row) in rows.enumerated() {
      result[i].exactTxnID = row.fingerprints.lazy.compactMap { existing[$0] }.first
    }

    let ibanIndex = Dictionary(
      context.accounts.compactMap { account in
        account.iban.map { (AccountNumber.normalized($0), account) }
      }.filter { !$0.0.isEmpty },
      uniquingKeysWith: { a, _ in a })

    var claims: [Claim] = []
    let pending = try await pendingHolds()

    for (i, row) in rows.enumerated() where result[i].exactTxnID == nil && row.kind != .openingBalance {
      let rowDay = day(row)

      // R-IMP-PKO-3: a counterparty account that is an Abacus account → own transfer.
      if source == .pko, let iban = row.counterpartyIBAN, let flow = row.flow,
        let own = ibanIndex[AccountNumber.normalized(iban)], ref(row.account) != .existing(own.id)
      {
        let transfer = ownTransfer(row, own: own, flow: flow)
        result[i].ownTransfer = transfer
        if transfer.from == .existing(own.id) ? transfer.amountMinor <= 0 : transfer.toAmountMinor == nil {
          result[i].review = .transferAmountUnknown
          continue
        }
        claims += try await otherSide(i, transfer, rowDay: rowDay, rowFlow: flow)
      } else if row.kind == .transferHalf {
        result[i].review = .unpairedTransferHalf(row.transferHalf?.direction ?? .outgoing)
        result[i].pairExisting = try await existingPairs(row, rowDay: rowDay)
        continue
      } else if row.isUnknownPKOType {
        result[i].review = .unknownOperationType
        continue
      }

      // R-IMP-PKO-2: a settled card payment matching an earlier hold.
      if source == .pko, row.kind == .expense, !row.isRefund, !row.isPending,
        case .existing(let accountID) = ref(row.account)
      {
        for hold in pending where hold.accountID == accountID && hold.type == .expense && !hold.isRefund {
          let gap = abs(rowDay.distance(to: Day(hold.occurredAt, calendar: calendar), calendar: calendar))
          guard gap <= PendingSettlement.dayWindow,
            PendingSettlement.amountMatches(pending: hold.amountMinor, settled: row.amountMinor),
            PendingSettlement.merchantMatches(hold.payee, row.payee)
          else { continue }
          claims.append(Claim(row: i, kind: .settle, txn: hold, dayGap: gap, amountGap: abs(hold.amountMinor - row.amountMinor)))
        }
      }

      // R-IMP-4: fuzzy duplicates on the first existing account the row touches.
      claims += try await duplicates(i, row, rowDay: rowDay, transfer: result[i].ownTransfer)
    }

    // One existing transaction per row and one row per transaction: settlements first, then
    // the closest dates.
    claims.sort { ($0.kind.rawValue, $0.dayGap, $0.amountGap, $0.row) < ($1.kind.rawValue, $1.dayGap, $1.amountGap, $1.row) }
    var takenRows = Set<Int>()
    var takenTxns = Set<Txn.ID>()
    for claim in claims where !takenRows.contains(claim.row) && !takenTxns.contains(claim.txn.id) {
      takenRows.insert(claim.row)
      takenTxns.insert(claim.txn.id)
      switch claim.kind {
      case .settle: result[claim.row].settles = claim.txn
      case .sameTransfer: result[claim.row].sameTransfer = claim.txn
      case .completes: result[claim.row].completesTransfer = claim.txn
      case .duplicate: result[claim.row].duplicate = claim.txn
      }
    }

    pairHalves(&result)
    return result
  }

  // MARK: - Pending holds

  private func pendingHolds() async throws -> [Txn] {
    guard source == .pko, let targetAccountID else { return [] }
    let days = rows.filter { !$0.isPending }.map(day)
    guard let first = days.min(), let last = days.max() else { return [] }
    return try await store.pendingTxns(
      accountID: targetAccountID, from: window(first, PendingSettlement.dayWindow).0,
      to: window(last, PendingSettlement.dayWindow).1)
  }

  // MARK: - Own-account transfers

  private func ownTransfer(_ row: NormalizedRow, own: Account, flow: Flow) -> OwnTransfer {
    let rowAccount = ref(row.account)
    // The amount on the own account's side, in its currency.
    var otherAmount: Int64?
    if own.currency == row.account.currency {
      otherAmount = row.amountMinor
    } else if let transit = row.transferHalf?.transit, transit.currencyCode == own.currency.rawValue {
      otherAmount = transit.minorUnits
    } else if let original = row.original, original.currencyCode == own.currency.rawValue {
      otherAmount = original.minorUnits
    }
    if flow == .out {
      return OwnTransfer(
        from: rowAccount, to: .existing(own.id), amountMinor: row.amountMinor, toAmountMinor: otherAmount,
        ownAccountID: own.id)
    }
    return OwnTransfer(
      from: .existing(own.id), to: rowAccount, amountMinor: otherAmount ?? 0, toAmountMinor: row.amountMinor,
      ownAccountID: own.id)
  }

  /// The same transfer, or its other side, imported from the other account's PKO statement.
  private func otherSide(_ i: Int, _ transfer: OwnTransfer, rowDay: Day, rowFlow: Flow) async throws -> [Claim] {
    guard case .existing(let from) = transfer.from, case .existing(let to) = transfer.to,
      let toAmount = transfer.toAmountMinor
    else { return [] }
    let (start, end) = window(rowDay, FuzzyDuplicate.dayWindow)
    var found: [Txn.ID: Txn] = [:]
    for txn in try await store.candidates(accountID: from, amountMinor: transfer.amountMinor, from: start, to: end) {
      found[txn.id] = txn
    }
    for txn in try await store.candidates(accountID: to, amountMinor: toAmount, from: start, to: end) {
      found[txn.id] = txn
    }
    var claims: [Claim] = []
    for txn in found.values where txn.source == .pko {
      let gap = abs(rowDay.distance(to: Day(txn.occurredAt, calendar: calendar), calendar: calendar))
      if txn.type == .transfer, txn.accountID == from, txn.toAccountID == to {
        claims.append(Claim(row: i, kind: .sameTransfer, txn: txn, dayGap: gap, amountGap: 0))
      } else if txn.accountID == transfer.ownAccountID, !txn.isRefund {
        // Money out of the imported account arrives on the own account as income, and the
        // other way round.
        let matches = rowFlow == .out
          ? txn.type == .income && txn.amountMinor == toAmount
          : txn.type == .expense && txn.amountMinor == transfer.amountMinor
        if matches { claims.append(Claim(row: i, kind: .completes, txn: txn, dayGap: gap, amountGap: 0)) }
      }
    }
    return claims
  }

  // MARK: - Fuzzy duplicates

  private func duplicates(_ i: Int, _ row: NormalizedRow, rowDay: Day, transfer: OwnTransfer?) async throws -> [Claim] {
    var sides: [(AccountRef, Int64, Flow)] = []
    if let transfer {
      sides = [(transfer.from, transfer.amountMinor, .out)]
      if let toAmount = transfer.toAmountMinor { sides.append((transfer.to, toAmount, .in)) }
    } else if row.kind == .transfer {
      sides = [(ref(row.account), row.amountMinor, .out)]
      if let counter = row.counterAccount {
        sides.append((ref(counter), row.counterAmountMinor ?? row.amountMinor, .in))
      }
    } else if let flow = row.flow {
      sides = [(ref(row.account), row.amountMinor, flow)]
    }
    guard let (account, amount, flow) = sides.first(where: { if case .existing = $0.0 { true } else { false } }),
      case .existing(let accountID) = account
    else { return [] }
    let (start, end) = window(rowDay, FuzzyDuplicate.dayWindow)
    return try await store.candidates(accountID: accountID, amountMinor: amount, from: start, to: end)
      .filter { txn in
        Flow.of(txn, on: accountID) == flow
          && FuzzyDuplicate.matches(
            rowSource: source, rowPayee: row.payee, rowDay: rowDay, candidate: txn,
            candidateDay: Day(txn.occurredAt, calendar: calendar), calendar: calendar)
      }
      .map { txn in
        Claim(
          row: i, kind: .duplicate, txn: txn,
          dayGap: abs(rowDay.distance(to: Day(txn.occurredAt, calendar: calendar), calendar: calendar)),
          amountGap: DescriptionSimilarity.words(txn.payee) == DescriptionSimilarity.words(row.payee) ? 0 : 1)
      }
  }

  // MARK: - Transfer halves

  /// Existing expenses that may be the sending side of an incoming half: another account in the
  /// in-transit currency, the in-transit amount, ± 3 days.
  private func existingPairs(_ row: NormalizedRow, rowDay: Day) async throws -> [Txn] {
    guard let half = row.transferHalf, half.direction == .incoming else { return [] }
    let own = ref(row.account)
    let (start, end) = window(rowDay, FuzzyDuplicate.dayWindow)
    var result: [Txn] = []
    for account in context.accounts
    where account.currency.rawValue == half.transit.currencyCode && own != .existing(account.id) {
      result += try await store.candidates(
        accountID: account.id, amountMinor: half.transit.minorUnits, from: start, to: end
      ).filter { $0.accountID == account.id && $0.type == .expense && !$0.isRefund }
    }
    return result.sorted {
      abs($0.occurredAt.timeIntervalSince(row.occurredAt)) < abs($1.occurredAt.timeIntervalSince(row.occurredAt))
    }
  }

  /// Manual pairing candidates among this file's unpaired halves: opposite direction, another
  /// account, ≤ 3 days apart; equal in-transit amount first, then the closest in time.
  private func pairHalves(_ result: inout [RowAnalysis]) {
    let halves = rows.indices.filter {
      result[$0].exactTxnID == nil && rows[$0].kind == .transferHalf && result[$0].ownTransfer == nil
    }
    let window = TimeInterval(FuzzyDuplicate.dayWindow * 24 * 60 * 60)
    let byDate = halves.sorted { rows[$0].occurredAt < rows[$1].occurredAt }
    for i in halves {
      let row = rows[i]
      guard let half = row.transferHalf else { continue }
      var options: [(index: Int, sameTransit: Bool, gap: TimeInterval)] = []
      // Halves sorted by date: scan only the ±3-day neighbourhood.
      let lower = byDate.firstIndex { rows[$0].occurredAt >= row.occurredAt.addingTimeInterval(-window) } ?? byDate.endIndex
      for j in byDate[lower...] {
        let other = rows[j]
        if other.occurredAt > row.occurredAt.addingTimeInterval(window) { break }
        guard j != i, let otherHalf = other.transferHalf, otherHalf.direction != half.direction,
          other.account.key != row.account.key
        else { continue }
        options.append((j, otherHalf.transit == half.transit, abs(other.occurredAt.timeIntervalSince(row.occurredAt))))
      }
      options.sort { ($0.sameTransit ? 0 : 1, $0.gap) < ($1.sameTransit ? 0 : 1, $1.gap) }
      result[i].pairRows = options.prefix(5).map { rows[$0.index].id }
    }
  }
}
