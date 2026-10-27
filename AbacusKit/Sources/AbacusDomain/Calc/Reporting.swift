import Foundation

/// Parent/child lookups over the one-level category tree (R-CAT-2).
public struct CategoryTree: Sendable {
  private let byID: [Category.ID: Category]
  private let childrenByParent: [Category.ID: [Category]]

  public init(_ categories: [Category]) {
    var byID: [Category.ID: Category] = [:]
    var children: [Category.ID: [Category]] = [:]
    for category in categories {
      byID[category.id] = category
      if let parent = category.parentID { children[parent, default: []].append(category) }
    }
    self.byID = byID
    self.childrenByParent = children.mapValues { $0.sorted { ($0.position, $0.name) < ($1.position, $1.name) } }
  }

  public func category(_ id: Category.ID) -> Category? { byID[id] }

  /// The parent when `id` is a known subcategory, else nil.
  public func parentID(of id: Category.ID) -> Category.ID? { byID[id]?.parentID }

  /// The top-level category `id` rolls up into: its parent, or itself.
  public func topLevelID(of id: Category.ID) -> Category.ID { parentID(of: id) ?? id }

  public func children(of id: Category.ID) -> [Category] { childrenByParent[id] ?? [] }

  /// `id` and its children (a parent selects its children, R-LIST-2).
  public func withChildren(_ id: Category.ID) -> Set<Category.ID> {
    Set([id] + children(of: id).map(\.id))
  }
}

/// Where an amount is reported in category totals.
public enum CategoryKey: Hashable, Sendable {
  case category(Category.ID)
  case uncategorized
  /// Expense refunds while "Refunds reduce category spending" is off: reported as income
  /// "Refunds" (R-TX-4, R-SET-3).
  case refunds
}

/// One reportable amount: a transaction's main amount or one of its attached records, after the
/// refund rule. Transfers have no main entry (R-TX-5); their attached records do.
public struct ReportEntry: Hashable, Sendable {
  public let txnID: Txn.ID
  public let day: Day
  public let kind: CategoryKind
  public let key: CategoryKey
  /// In the account's currency. Negative when it reduces its kind's total: an expense refund
  /// with the setting on, an income reversal.
  public let amount: Money
  public let eventID: Event.ID?
}

extension Calc {
  /// The reportable amounts of a transaction (R-TX-4, R-TX-6, R-SET-3):
  /// - expense → expense under its category;
  /// - expense refund → setting off: income under `.refunds`, the category's spending unchanged;
  ///   setting on: a negative expense under its category;
  /// - income → income under its category; an income reversal → negative income under its
  ///   category (the setting is about spending only);
  /// - transfer → nothing;
  /// - each attached record → its own kind under its own category, except a refund line: an
  ///   `.income` record in an expense category (D22) is counted like an expense refund above.
  ///
  /// `categories` tells refund lines apart; a category it does not know is not an expense one.
  public static func reportEntries(
    of item: TxnWithLines, currency: Currency, categories: CategoryTree,
    refundsReduceSpending: Bool, calendar: Calendar = .current
  ) -> [ReportEntry] {
    let txn = item.txn
    let day = Day(txn.occurredAt, calendar: calendar)
    func entry(_ kind: CategoryKind, _ key: CategoryKey, _ minor: Int64) -> ReportEntry {
      ReportEntry(
        txnID: txn.id, day: day, kind: kind, key: key,
        amount: Money(minorUnits: minor, currency: currency), eventID: txn.eventID)
    }
    func key(_ id: Category.ID?) -> CategoryKey { id.map(CategoryKey.category) ?? .uncategorized }

    func refund(_ categoryID: Category.ID?, _ minor: Int64) -> ReportEntry {
      refundsReduceSpending ? entry(.expense, key(categoryID), -minor) : entry(.income, .refunds, minor)
    }

    var entries: [ReportEntry] = []
    switch txn.type {
    case .expense where txn.isRefund:
      entries.append(refund(txn.categoryID, txn.amountMinor))
    case .expense:
      entries.append(entry(.expense, key(txn.categoryID), txn.amountMinor))
    case .income:
      entries.append(entry(.income, key(txn.categoryID), txn.isRefund ? -txn.amountMinor : txn.amountMinor))
    case .transfer:
      break
    }
    for line in item.lines {
      let isRefundLine =
        line.kind == .income && line.categoryID.flatMap { categories.category($0)?.kind } == .expense
      entries.append(
        isRefundLine ? refund(line.categoryID, line.amountMinor) : entry(line.kind, key(line.categoryID), line.amountMinor))
    }
    return entries
  }

  /// Report entries of `txns` (optionally only within `days`) converted to `currency`, each at
  /// the rate of its own day (R-FX-3). Unconvertible entries are left out and recorded.
  static func convertedEntries(
    _ txns: [TxnWithLines], accounts: [Account], categories: CategoryTree, currency: Currency,
    converter: some CurrencyConverter, refundsReduceSpending: Bool,
    days: ClosedRange<Day>? = nil, calendar: Calendar, gaps: inout Unconverted
  ) -> [ReportEntry] {
    let currencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
    var result: [ReportEntry] = []
    for item in txns {
      if let days, !days.contains(Day(item.txn.occurredAt, calendar: calendar)) { continue }
      let entries = reportEntries(
        of: item, currency: currencies[item.txn.accountID] ?? currency, categories: categories,
        refundsReduceSpending: refundsReduceSpending, calendar: calendar)
      guard !entries.isEmpty else { continue }
      guard let from = currencies[item.txn.accountID] else {
        for _ in entries { gaps.recordUnknownAccount(item.txn.accountID) }
        continue
      }
      for entry in entries {
        guard
          let minor = convert(
            entry.amount.minorUnits, from: from, to: currency, at: .day(entry.day), using: converter, gaps: &gaps)
        else { continue }
        result.append(ReportEntry(
          txnID: entry.txnID, day: entry.day, kind: entry.kind, key: entry.key,
          amount: Money(minorUnits: minor, currency: currency), eventID: entry.eventID))
      }
    }
    return result
  }
}

// MARK: - Category totals (donut, event by-category)

/// A category's total in a breakdown. A parent's total includes its children (R-CAT-2).
public struct CategoryTotal: Hashable, Sendable, Identifiable {
  public let key: CategoryKey
  /// Including children.
  public let total: Money
  /// Booked on this category itself (a parent's own transactions); equals `total` for a leaf.
  public let direct: Money
  /// `total` / the breakdown's total (1 = 100 %); nil when the breakdown's total is not positive.
  public let share: Decimal?
  /// Subcategories with a non-zero total, largest first.
  public let children: [CategoryTotal]

  public var id: CategoryKey { key }
}

public struct CategoryBreakdown: Hashable, Sendable {
  public let kind: CategoryKind
  public let currency: Currency
  public let total: Money
  /// Top-level categories (plus `.uncategorized` / `.refunds`) with a non-zero total, largest first.
  public let items: [CategoryTotal]
  public let unconverted: Unconverted
}

extension Calc {
  /// Rolls entries of one kind up into top-level categories with their children.
  static func breakdown(
    _ entries: [ReportEntry], kind: CategoryKind, currency: Currency, tree: CategoryTree,
    unconverted: Unconverted
  ) -> CategoryBreakdown {
    var direct: [CategoryKey: Int64] = [:]
    for entry in entries where entry.kind == kind {
      direct[entry.key, default: 0] += entry.amount.minorUnits
    }
    var childrenByTop: [CategoryKey: [CategoryKey]] = [:]
    var tops: Set<CategoryKey> = []
    for key in direct.keys {
      if case .category(let id) = key, let parent = tree.parentID(of: id) {
        childrenByTop[.category(parent), default: []].append(key)
        tops.insert(.category(parent))
      } else {
        tops.insert(key)
      }
    }
    let grand = direct.values.reduce(0, +)
    func money(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: currency) }
    func share(_ minor: Int64) -> Decimal? { grand > 0 ? Decimal(minor) / Decimal(grand) : nil }
    func order(_ a: CategoryTotal, _ b: CategoryTotal) -> Bool {
      if a.total.minorUnits != b.total.minorUnits { return a.total.minorUnits > b.total.minorUnits }
      return sortKey(a.key, tree) < sortKey(b.key, tree)
    }

    var items: [CategoryTotal] = []
    for top in tops {
      let children = (childrenByTop[top] ?? []).compactMap { key -> CategoryTotal? in
        let minor = direct[key] ?? 0
        guard minor != 0 else { return nil }
        return CategoryTotal(key: key, total: money(minor), direct: money(minor), share: share(minor), children: [])
      }.sorted(by: order)
      let own = direct[top] ?? 0
      let total = own + children.reduce(0) { $0 + $1.total.minorUnits }
      guard total != 0 || !children.isEmpty else { continue }
      items.append(CategoryTotal(key: top, total: money(total), direct: money(own), share: share(total), children: children))
    }
    return CategoryBreakdown(
      kind: kind, currency: currency, total: money(grand), items: items.sorted(by: order), unconverted: unconverted)
  }

  private static func sortKey(_ key: CategoryKey, _ tree: CategoryTree) -> String {
    switch key {
    case .category(let id):
      let c = tree.category(id)
      return String(format: "0%09d", c?.position ?? 0) + (c?.name ?? id.uuidString)
    case .uncategorized: return "1"
    case .refunds: return "2"
    }
  }

  /// The monthly expenses donut (R-HOME-3): expenses of `month` by top-level category with
  /// subcategories, attached expense records under their own category (R-TX-6), each amount
  /// converted at its day's rate (R-FX-3), refunds by the setting (R-TX-4, R-SET-3).
  public static func expensesByCategory(
    month: Month, accounts: [Account], categories: [Category], txns: [TxnWithLines],
    currency: Currency, converter: some CurrencyConverter, refundsReduceSpending: Bool,
    calendar: Calendar = .current
  ) -> CategoryBreakdown {
    categoryTotals(
      kind: .expense, days: month.firstDay...month.lastDay(calendar: calendar), accounts: accounts,
      categories: categories, txns: txns, currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, calendar: calendar)
  }

  /// Expense or income totals by category over `days` (nil = all of `txns`). Income includes
  /// the `.refunds` row while the refund setting is off.
  public static func categoryTotals(
    kind: CategoryKind, days: ClosedRange<Day>?, accounts: [Account], categories: [Category],
    txns: [TxnWithLines], currency: Currency, converter: some CurrencyConverter,
    refundsReduceSpending: Bool, calendar: Calendar = .current
  ) -> CategoryBreakdown {
    var gaps = Unconverted()
    let tree = CategoryTree(categories)
    let entries = convertedEntries(
      txns, accounts: accounts, categories: tree, currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, days: days, calendar: calendar, gaps: &gaps)
    return breakdown(entries, kind: kind, currency: currency, tree: tree, unconverted: gaps)
  }
}

// MARK: - List totals (R-LIST-5)

/// Footer totals of a filtered transaction list in the display currency (R-LIST-5).
public struct ListTotals: Hashable, Sendable {
  public let count: Int
  public let income: Money
  public let expense: Money
  public let unconverted: Unconverted

  /// income − expense.
  public var net: Money { income - expense }
}

extension Calc {
  /// Income, expense and net of `txns` (already filtered by the caller) in `currency`, each
  /// amount at its day's rate. Transfers count as neither (R-TX-5); attached records count by
  /// their kind (R-TX-6); refunds and refund lines follow the setting (R-TX-4, D22) — the net
  /// is the same either way.
  public static func listTotals(
    txns: [TxnWithLines], accounts: [Account], categories: [Category], currency: Currency,
    converter: some CurrencyConverter, refundsReduceSpending: Bool, calendar: Calendar = .current
  ) -> ListTotals {
    var gaps = Unconverted()
    let entries = convertedEntries(
      txns, accounts: accounts, categories: CategoryTree(categories), currency: currency,
      converter: converter, refundsReduceSpending: refundsReduceSpending, calendar: calendar, gaps: &gaps)
    var income: Int64 = 0
    var expense: Int64 = 0
    for entry in entries {
      if entry.kind == .income { income += entry.amount.minorUnits } else { expense += entry.amount.minorUnits }
    }
    return ListTotals(
      count: txns.count, income: Money(minorUnits: income, currency: currency),
      expense: Money(minorUnits: expense, currency: currency), unconverted: gaps)
  }
}

// MARK: - Income vs expenses by month (R-HOME-6)

/// One month of the income vs expenses widget: the same totals as the month's donuts.
public struct MonthIncomeExpense: Hashable, Sendable, Identifiable {
  public let month: Month
  public let income: Money
  public let expense: Money

  /// income − expense.
  public var net: Money { income - expense }
  public var id: Month { month }
}

public struct IncomeExpenseSeries: Hashable, Sendable {
  public let currency: Currency
  /// Oldest first, one per month; months without entries are zero.
  public let months: [MonthIncomeExpense]
  public let unconverted: Unconverted
}

extension Calc {
  /// Income and expenses of each of the `count` months ending at `last` (R-HOME-6) in
  /// `currency`, each amount at its day's rate (R-FX-3). The same entries as the donuts and the
  /// list totals: transfers count as neither, attached records by their kind, refunds by the
  /// setting (the net is the same either way).
  public static func incomeExpenseSeries(
    endingAt last: Month, count: Int = 12, accounts: [Account], categories: [Category], txns: [TxnWithLines],
    currency: Currency, converter: some CurrencyConverter, refundsReduceSpending: Bool,
    calendar: Calendar = .current
  ) -> IncomeExpenseSeries {
    let count = max(count, 1)
    let months = (0..<count).map { last.adding(months: $0 - count + 1) }
    var gaps = Unconverted()
    let entries = convertedEntries(
      txns, accounts: accounts, categories: CategoryTree(categories), currency: currency, converter: converter,
      refundsReduceSpending: refundsReduceSpending, days: months[0].firstDay...last.lastDay(calendar: calendar),
      calendar: calendar, gaps: &gaps)
    var income: [Month: Int64] = [:]
    var expense: [Month: Int64] = [:]
    for entry in entries {
      if entry.kind == .income {
        income[entry.day.yearMonth, default: 0] += entry.amount.minorUnits
      } else {
        expense[entry.day.yearMonth, default: 0] += entry.amount.minorUnits
      }
    }
    return IncomeExpenseSeries(
      currency: currency,
      months: months.map {
        MonthIncomeExpense(
          month: $0, income: Money(minorUnits: income[$0] ?? 0, currency: currency),
          expense: Money(minorUnits: expense[$0] ?? 0, currency: currency))
      },
      unconverted: gaps)
  }
}
