import Foundation

/// The periods the detector offers (Q11). Other intervals can be set by hand in the editor.
public enum SubscriptionPeriod: String, CaseIterable, Hashable, Sendable {
  case weekly, biweekly, monthly, quarterly, yearly

  /// Nominal gap in days and the tolerance of the median gap (R-REC-8).
  var nominalDays: Int {
    switch self {
    case .weekly: 7
    case .biweekly: 14
    case .monthly: 30
    case .quarterly: 91
    case .yearly: 365
    }
  }

  var tolerance: Int {
    switch self {
    case .weekly: 1
    case .biweekly: 2
    case .monthly: 4
    case .quarterly: 6
    case .yearly: 10
    }
  }

  public var unit: ScheduleUnit {
    switch self {
    case .weekly, .biweekly: .week
    case .monthly, .quarterly: .month
    case .yearly: .year
    }
  }

  public var interval: Int {
    switch self {
    case .weekly, .monthly, .yearly: 1
    case .biweekly: 2
    case .quarterly: 3
    }
  }
}

public enum SuggestionConfidence: String, Hashable, Sendable {
  case high, medium
}

/// A proposed scheduled item with the rows it was found in (R-REC-8). Never stored.
public struct SubscriptionSuggestion: Hashable, Sendable, Identifiable {
  public var id: String { "\(accountID.uuidString)|\(key)" }
  /// Dismissal key: normalised description, type and currency.
  public let key: String
  public let description: String
  public let accountID: Account.ID
  public let currency: Currency
  public let type: TxnType
  public let categoryID: Category.ID?
  public let amountMinor: Int64
  public let period: SubscriptionPeriod
  public let nextDay: Day
  public let confidence: SuggestionConfidence
  /// Evidence rows, oldest first.
  public let evidence: [Txn.ID]
  public let latestDay: Day
}

/// Pure detection of recurring payments in the transaction history (R-REC-8). Runs on demand,
/// off the main actor; nothing is stored here.
public enum SubscriptionDetector {
  public static let windowDays = 730  // about 24 months

  /// Same text on a card statement across months: folded, words with digits dropped (card numbers,
  /// dates, reference ids), spaces collapsed.
  public static func normalise(_ description: String) -> String {
    TextFolding.fold(description)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .filter { word in !word.contains(where: \.isNumber) }
      .joined(separator: " ")
  }

  public static func key(description: String, type: TxnType, currency: Currency) -> String? {
    let text = normalise(description)
    return text.isEmpty ? nil : "\(text)|\(type.rawValue)|\(currency.rawValue)"
  }

  /// - Parameters:
  ///   - matchedTxnIDs: transactions already matched to a scheduled item (ignored).
  ///   - dismissed: `"<accountUUID>|<key>"` of dismissed suggestions (`dismissalID`).
  public static func detect(
    txns: [Txn], accounts: [Account], matchedTxnIDs: Set<Txn.ID> = [], dismissed: Set<String> = [], today: Day,
    calendar: Calendar = .current
  ) -> [SubscriptionSuggestion] {
    let usable = Dictionary(uniqueKeysWithValues: accounts.filter { !$0.isArchived }.map { ($0.id, $0) })
    let earliest = today.plusDays(-windowDays)

    struct Row {
      let txn: Txn
      let day: Day
    }
    var groups: [String: (accountID: Account.ID, currency: Currency, type: TxnType, rows: [Row])] = [:]
    for txn in txns {
      guard txn.type != .transfer, !txn.isRefund, !txn.isBalanceCorrection, !matchedTxnIDs.contains(txn.id),
        let account = usable[txn.accountID], let key = key(description: txn.payee, type: txn.type, currency: account.currency)
      else { continue }
      let day = Day(txn.occurredAt, calendar: calendar)
      guard day >= earliest, day <= today else { continue }
      let groupKey = "\(account.id.uuidString)|\(key)"
      groups[groupKey, default: (account.id, account.currency, txn.type, [])].rows.append(Row(txn: txn, day: day))
    }

    var result: [SubscriptionSuggestion] = []
    for (groupKey, group) in groups where group.rows.count >= 3 && !dismissed.contains(groupKey) {
      let rows = group.rows.sorted { ($0.day, $0.txn.createdAt) < ($1.day, $1.txn.createdAt) }
      // Amounts: every row within 10 % of the median.
      let amounts = rows.map(\.txn.amountMinor).sorted()
      let medianAmount = amounts[amounts.count / 2]
      guard medianAmount > 0, amounts.allSatisfy({ abs($0 - medianAmount) * 10 <= medianAmount }) else { continue }
      // Gaps: regular, and near a known period.
      let gaps = zip(rows, rows.dropFirst()).map { $0.day.daysUntil($1.day) }.sorted()
      let medianGap = gaps[gaps.count / 2]
      guard medianGap > 0, gaps.allSatisfy({ abs($0 - medianGap) * 5 <= medianGap }),
        let period = SubscriptionPeriod.allCases.first(where: { abs(medianGap - $0.nominalDays) <= $0.tolerance })
      else { continue }
      if period == .monthly {
        let days = rows.map(\.day.day)
        guard let low = days.min(), let high = days.max(), high - low <= 4 else { continue }
      }
      let newest = rows[rows.count - 1]
      guard Double(newest.day.daysUntil(today)) <= 1.5 * Double(period.nominalDays) else { continue }

      let schedule = Schedule(unit: period.unit, interval: period.interval, startDay: newest.day)
      let next = schedule.occurrence(at: 1) ?? newest.day.plusDays(period.nominalDays)
      let exact = amounts.allSatisfy { abs($0 - medianAmount) * 50 <= medianAmount }
      var categoryCounts: [Category.ID: Int] = [:]
      for row in rows { if let c = row.txn.categoryID { categoryCounts[c, default: 0] += 1 } }
      let category = categoryCounts.max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }?.key
      let keyOnly = String(groupKey.dropFirst(group.accountID.uuidString.count + 1))
      result.append(
        SubscriptionSuggestion(
          key: keyOnly, description: newest.txn.payee, accountID: group.accountID, currency: group.currency,
          type: group.type, categoryID: category, amountMinor: newest.txn.amountMinor, period: period,
          nextDay: next, confidence: rows.count >= 4 && exact ? .high : .medium, evidence: rows.map(\.txn.id),
          latestDay: newest.day))
    }
    return result.sorted { ($0.nextDay, $0.id) < ($1.nextDay, $1.id) }
  }

  /// The string stored in `SuggestionDismissal` and passed to `detect(dismissed:)`.
  public static func dismissalID(accountID: Account.ID, key: String) -> String { "\(accountID.uuidString)|\(key)" }
}
