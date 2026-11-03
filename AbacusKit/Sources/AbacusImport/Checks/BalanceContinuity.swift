import AbacusDomain
import Foundation

/// One row next to a balance gap, as shown in the preview.
public struct GapRow: Hashable, Sendable, Identifiable {
  /// The preview row id (`NormalizedRow.id`).
  public var id: String
  public var payee: String
  public var bookedDay: Day
  /// Signed, as in the statement.
  public var amountMinor: Int64
  public var balanceAfterMinor: Int64
  /// The balance the row starts from: `balanceAfter − amount`.
  public var startsFromMinor: Int64
}

/// Rows of the file adding up to `missingMinor` are not in it: the balance after `before` does not
/// match the balance `after` starts from (R-CLR-9).
public struct BalanceGap: Hashable, Sendable, Identifiable {
  public var before: GapRow
  public var after: GapRow
  /// Signed net amount of the missing rows: `after.startsFrom − before.balanceAfter`.
  public var missingMinor: Int64
  public var id: String { before.id + ">" + after.id }
}

/// The file's balance chain: its gaps, its opening balance and its closing balance.
public struct BalanceContinuity: Hashable, Sendable {
  public var gaps: [BalanceGap]
  /// The oldest row's starting balance and booked day (the file opens with it).
  public var startMinor: Int64?
  public var startDay: Day?
  /// The newest row's balance after and booked day (the statement closes with it).
  public var endMinor: Int64?
  public var endDay: Day?

  public static let empty = BalanceContinuity(gaps: [])

  public init(gaps: [BalanceGap], startMinor: Int64? = nil, startDay: Day? = nil, endMinor: Int64? = nil, endDay: Day? = nil) {
    self.gaps = gaps
    self.startMinor = startMinor
    self.startDay = startDay
    self.endMinor = endMinor
    self.endDay = endDay
  }

  /// Checks that each booked row's balance follows from the one before (PKO `Saldo po transakcji`).
  ///
  /// Rows are not strictly ordered and a day holds several, so file order is not trusted: row *j*
  /// follows row *i* when `balanceAfter_i + amount_j = balanceAfter_j`. Starting balances
  /// (`balanceAfter − amount`) are matched against balances after as multisets; a starting balance
  /// no row ends on is a chain start, a balance after no row starts from is a chain end. A healthy
  /// file has exactly one of each; every further pair is a gap, from an end to the next start in
  /// date order, and the difference between them is the net amount of the missing rows. Equal
  /// balances (+x then −x, zero amounts) are told apart by date, oldest first for starts and newest
  /// first for ends. Holds and rows without a balance are ignored.
  public static func analyze(_ rows: [NormalizedRow], calendar: Calendar) -> BalanceContinuity {
    struct Node {
      var id: String
      var payee: String
      var day: Day
      var order: Int
      var amount: Int64
      var after: Int64
      var start: Int64 { after - amount }
    }
    var nodes: [Node] = []
    for (order, row) in rows.enumerated() {
      guard !row.isPending, let amount = row.statementAmountMinor, let after = row.balanceAfterMinor else { continue }
      let day = row.bookedDay ?? row.valueDay ?? Day(row.occurredAt, calendar: calendar)
      nodes.append(Node(id: row.id, payee: row.payee, day: day, order: order, amount: amount, after: after))
    }
    guard !nodes.isEmpty else { return .empty }
    // Oldest first; within a day the file lists newest first, so the later row comes first.
    nodes.sort { ($0.day, -$0.order) < ($1.day, -$1.order) }

    var startsByValue: [Int64: [Int]] = [:]  // node indexes whose start balance is the value
    var endsByValue: [Int64: [Int]] = [:]
    for (index, node) in nodes.enumerated() {
      startsByValue[node.start, default: []].append(index)
      endsByValue[node.after, default: []].append(index)
    }
    var starts: [Int] = []  // chain starts: surplus starting balances, oldest first
    var ends: [Int] = []  // chain ends: surplus balances after, newest first
    for (value, startIndexes) in startsByValue {
      let endCount = endsByValue[value]?.count ?? 0
      let surplus = startIndexes.count - endCount
      if surplus > 0 { starts += startIndexes.prefix(surplus) }
    }
    for (value, endIndexes) in endsByValue {
      let startCount = startsByValue[value]?.count ?? 0
      let surplus = endIndexes.count - startCount
      if surplus > 0 { ends += endIndexes.suffix(surplus) }
    }
    starts.sort()
    ends.sort()
    func gapRow(_ node: Node) -> GapRow {
      GapRow(
        id: node.id, payee: node.payee, bookedDay: node.day, amountMinor: node.amount, balanceAfterMinor: node.after,
        startsFromMinor: node.start)
    }
    var gaps: [BalanceGap] = []
    // Pair each end with the first later start; the very first start and the very last end are the
    // file's own opening and closing.
    var remainingStarts = Array(starts.dropFirst())
    for end in ends {
      guard let next = remainingStarts.first(where: { $0 > end }) ?? remainingStarts.first else { continue }
      remainingStarts.removeAll { $0 == next }
      let before = nodes[end], after = nodes[next]
      gaps.append(BalanceGap(before: gapRow(before), after: gapRow(after), missingMinor: after.start - before.after))
    }
    gaps.sort { $0.before.bookedDay < $1.before.bookedDay }
    let first = starts.first.map { nodes[$0] } ?? nodes[0]
    let last = ends.last.map { nodes[$0] } ?? nodes[nodes.count - 1]
    return BalanceContinuity(
      gaps: gaps, startMinor: first.start, startDay: first.day, endMinor: last.after, endDay: last.day)
  }
}

/// The file's opening balance against the account's cleared balance on the day before.
public struct StartBalanceCheck: Hashable, Sendable {
  public var fileStartMinor: Int64
  public var accountClearedMinor: Int64
  public var differenceMinor: Int64 { fileStartMinor - accountClearedMinor }
  public var isMatch: Bool { differenceMinor == 0 }
}
