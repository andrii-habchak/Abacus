import AbacusDomain
import Foundation

/// Accounts, categories and events the list resolves names, currencies and colours from.
public struct TransactionsReference: Equatable, Sendable {
  public var accounts: [Account]
  /// Account groups: the accounts menu lists accounts A–Z under them (R-MGMT-8).
  public var accountGroups: [AccountGroup]
  public var categories: TransactionCategoryTree
  public var events: [Event]
  public private(set) var accountsByID: [Account.ID: Account]
  public private(set) var eventsByID: [Event.ID: Event]
  /// `#RRGGBB` of the built-in "Uncategorised" (D47): tiles of rows without a category.
  public var uncategorisedColor: String

  public init(
    accounts: [Account] = [], categories: [AbacusDomain.Category] = [], events: [Event] = [],
    uncategorisedColor: String = Uncategorised.defaultColorHex, accountGroups: [AccountGroup] = []
  ) {
    self.uncategorisedColor = uncategorisedColor
    self.accountGroups = accountGroups
    self.accounts = accounts.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    self.categories = TransactionCategoryTree(categories)
    self.events = events
    accountsByID = Dictionary(accounts.map { ($0.id, $0) }) { first, _ in first }
    eventsByID = Dictionary(events.map { ($0.id, $0) }) { first, _ in first }
  }
}

/// Everything the transaction list shows for a fetched set of rows: day sections with their
/// net, row texts and badges, nested attached records, and the footer totals in the display
/// currency (approved prototype 2, R-LIST-4/5).
public struct TransactionListContent: Equatable, Sendable {
  public enum Tone: Hashable, Sendable {
    /// Expense, reversal, fee: primary text.
    case outflow
    /// Income, refund, cashback: green.
    case inflow
    /// Transfer: secondary text.
    case transfer
  }

  public struct Badge: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case pending, refund, event, debt }
    public var kind: Kind
    public var label: String
  }

  /// The category tile at the start of a row.
  public struct Icon: Hashable, Sendable {
    /// First letter of the category, "⇄" for transfers.
    public var symbol: String
    /// `#RRGGBB`, nil for the neutral grey.
    public var colorHex: String?
  }

  /// An attached record nested under its transaction (R-TX-6).
  public struct Line: Identifiable, Hashable, Sendable {
    public var id: AttachedRecord.ID
    /// The record's note, else its category name.
    public var label: String
    public var category: String
    public var amount: String
    public var tone: Tone
  }

  public struct Row: Identifiable, Hashable, Sendable {
    public var id: Txn.ID
    public var type: TxnType
    public var icon: Icon
    /// Description (payee).
    public var title: String
    public var badges: [Badge]
    /// "Note · 13:20" or the time alone.
    public var subtitle: String
    /// "Parent › Child", or "Transfer".
    public var category: String
    /// Account name, or "From → To" for transfers.
    public var account: String
    /// Signed, in the account currency.
    public var amount: String
    public var tone: Tone
    /// "Charged €10.00" (original amount, R-CUR-4); for transfers "→ +$100.00" (amount
    /// received) or "→ <account>" when both sides use one currency.
    public var amountDetail: String?
    public var lines: [Line]
  }

  public struct DaySection: Identifiable, Hashable, Sendable {
    public var id: Day { day }
    public var day: Day
    /// "Wednesday, 21 October" (year added outside the current year).
    public var title: String
    /// The day's income − expenses in the display currency.
    public var net: Money
    public var netText: String
    public var rows: [Row]
  }

  public struct Totals: Hashable, Sendable {
    public var count: Int
    public var income: Money
    public var expense: Money
    public var net: Money { income - expense }
    /// Day/currency buckets left out because no rate is known for them.
    public var unconverted: Int

    public var countLabel: String { count == 1 ? "1 transaction" : "\(count) transactions" }
  }

  public var days: [DaySection]
  public var totals: Totals
  public var incomeText: String
  public var expenseText: String
  public var netText: String
  public var isEmpty: Bool { days.isEmpty }

  public static func empty(_ currency: Currency) -> TransactionListContent {
    TransactionListContent(
      rows: [], reference: TransactionsReference(), displayCurrency: currency,
      converter: TransactionNoRates(), today: Day(year: 2000, month: 1, day: 1))
  }

  /// All rows at once, totals and day sums computed from them (previews, tests, small sets).
  /// - Parameters:
  ///   - rows: as fetched, already filtered and sorted; days keep that order.
  ///   - categoryFilter: the expanded category filter, if any (see `TransactionTotalsRule`).
  ///   - includeUncategorised: "Uncategorised" is ticked in the category filter.
  ///   - converter: every day's amounts convert at that day's rate (R-FX-3).
  public init(
    rows: [TxnWithLines], reference: TransactionsReference, displayCurrency: Currency,
    converter: any CurrencyConverter, today: Day,
    categoryFilter: Set<AbacusDomain.Category.ID>? = nil, includeUncategorised: Bool = false,
    refundsReduceSpending: Bool = false,
    calendar: Calendar = .current, format: TransactionMoneyFormat = TransactionMoneyFormat()
  ) {
    let builder = Builder(
      summary: TxnListSummary(rows: rows), reference: reference, displayCurrency: displayCurrency,
      converter: converter, today: today, categoryFilter: categoryFilter,
      includeUncategorised: includeUncategorised, refundsReduceSpending: refundsReduceSpending,
      calendar: calendar, format: format)
    self = builder.content(rows: rows)
  }

  fileprivate init(days: [DaySection], totals: Totals, format: TransactionMoneyFormat) {
    self.days = days
    self.totals = totals
    incomeText = format.string(totals.income)
    expenseText = format.string(totals.expense)
    netText = format.string(totals.net, sign: .always)
  }

  /// Builds the list content page by page (C28): the footer totals, "N transactions" and every
  /// day's net come from `summary`, the aggregate of the WHOLE filtered set, so they stay right
  /// while only some pages of rows are loaded; rows are formatted only for the pages given.
  public struct Builder {
    let reference: TransactionsReference
    let calendar: Calendar
    let format: TransactionMoneyFormat
    let titles: TransactionDayTitles
    public let totals: Totals
    /// The net of every day of the filtered set, in the display currency.
    let dayNets: [Day: Money]

    /// - Parameter summary: the whole filtered set (`TxnRepository.summary`).
    public init(
      summary: TxnListSummary, reference: TransactionsReference, displayCurrency: Currency,
      converter: any CurrencyConverter, today: Day,
      categoryFilter: Set<AbacusDomain.Category.ID>? = nil, includeUncategorised: Bool = false,
      refundsReduceSpending: Bool = false, calendar: Calendar = .current,
      format: TransactionMoneyFormat = TransactionMoneyFormat()
    ) {
      self.reference = reference
      self.calendar = calendar
      self.format = format
      titles = TransactionDayTitles(today: today, calendar: calendar, locale: format.locale)
      let rule = TransactionTotalsRule(
        refundsReduceSpending: refundsReduceSpending, categoryFilter: categoryFilter,
        categoryKinds: reference.categories.byID.mapValues(\.kind), includeUncategorised: includeUncategorised)

      var buckets: [Day: [Currency: (income: Int64, expense: Int64)]] = [:]
      var unconverted = 0
      for main in summary.mains {
        guard let currency = reference.accountsByID[main.accountID]?.currency else {
          unconverted += 1
          continue
        }
        let parts = rule.parts(
          type: main.type, isRefund: main.isRefund, categoryID: main.categoryID, amountMinor: main.amountMinor)
        let day = Day(main.occurredAt, calendar: calendar)
        buckets[day, default: [:]][currency, default: (0, 0)].income += parts.income
        buckets[day, default: [:]][currency, default: (0, 0)].expense += parts.expense
      }
      for line in summary.lines {
        guard let currency = reference.accountsByID[line.accountID]?.currency else { continue }
        let parts = rule.parts(lineKind: line.kind, categoryID: line.categoryID, amountMinor: line.amountMinor)
        let day = Day(line.occurredAt, calendar: calendar)
        buckets[day, default: [:]][currency, default: (0, 0)].income += parts.income
        buckets[day, default: [:]][currency, default: (0, 0)].expense += parts.expense
      }

      var income = Money.zero(displayCurrency)
      var expense = Money.zero(displayCurrency)
      var nets: [Day: Money] = [:]
      for (day, byCurrency) in buckets {
        var dayIncome = Money.zero(displayCurrency)
        var dayExpense = Money.zero(displayCurrency)
        for (currency, sums) in byCurrency.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
          guard sums.income != 0 || sums.expense != 0 else { continue }
          guard
            let i = converter.convert(Money(minorUnits: sums.income, currency: currency), to: displayCurrency, on: day),
            let e = converter.convert(Money(minorUnits: sums.expense, currency: currency), to: displayCurrency, on: day)
          else {
            unconverted += 1
            continue
          }
          dayIncome = dayIncome + i
          dayExpense = dayExpense + e
        }
        income = income + dayIncome
        expense = expense + dayExpense
        nets[day] = dayIncome - dayExpense
      }
      dayNets = nets
      totals = Totals(count: summary.count, income: income, expense: expense, unconverted: unconverted)
      self.displayCurrency = displayCurrency
    }

    private let displayCurrency: Currency

    /// Content for the first `rows` (a page, or all of them).
    public func content(rows: [TxnWithLines]) -> TransactionListContent {
      var content = TransactionListContent(days: [], totals: totals, format: format)
      append(rows, to: &content)
      return content
    }

    /// Adds the next page: its rows join the last day section when they share its day (a page
    /// boundary may fall inside a day), otherwise new sections start.
    public func append(_ rows: [TxnWithLines], to content: inout TransactionListContent) {
      for item in rows {
        let day = Day(item.txn.occurredAt, calendar: calendar)
        let row = TransactionListContent.row(item, reference: reference, calendar: calendar, format: format)
        if let last = content.days.indices.last, content.days[last].day == day {
          content.days[last].rows.append(row)
        } else {
          let net = dayNets[day] ?? .zero(displayCurrency)
          content.days.append(
            DaySection(
              day: day, title: titles.title(day), net: net, netText: format.string(net, sign: .always),
              rows: [row]))
        }
      }
    }
  }

  // MARK: Rows

  static func row(
    _ item: TxnWithLines, reference: TransactionsReference, calendar: Calendar,
    format: TransactionMoneyFormat
  ) -> Row {
    let txn = item.txn
    let tree = reference.categories
    let account = reference.accountsByID[txn.accountID]
    let code = account?.currency.rawValue ?? "UAH"
    let accountName = account?.name ?? "Unknown account"

    var badges: [Badge] = []
    if txn.isPendingAtBank { badges.append(Badge(kind: .pending, label: "Pending")) }
    // R-DEBT-3: a debt record's leg; its isRefund only marks money in (no refund badge).
    if txn.debtRecordID != nil {
      badges.append(Badge(kind: .debt, label: "Debt"))
    } else if txn.isRefund {
      badges.append(Badge(kind: .refund, label: txn.type == .income ? "Reversal" : "Refund"))
    }
    if let event = txn.eventID.flatMap({ reference.eventsByID[$0] }) {
      badges.append(Badge(kind: .event, label: event.name))
    }

    let time = calendar.dateComponents([.hour, .minute], from: txn.occurredAt)
    let clock = String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    let note = txn.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitle = note.isEmpty ? clock : "\(note) · \(clock)"

    let lines = item.lines.sorted { $0.position < $1.position }.map { line in
      let category = tree.path(line.categoryID) ?? Uncategorised.title
      let inflow = line.kind == .income
      let note = line.note.trimmingCharacters(in: .whitespacesAndNewlines)
      return Line(
        id: line.id,
        label: note.isEmpty ? (tree.category(line.categoryID)?.name ?? (inflow ? "Income" : "Fee")) : note,
        category: category,
        amount: format.string(minor: inflow ? line.amountMinor : -line.amountMinor, code: code, sign: .always),
        tone: inflow ? .inflow : .outflow)
    }

    switch txn.type {
    case .transfer where txn.debtRecordID != nil && txn.toAccountID == nil:
      // A debt leg without destination: money out, or in when `isRefund` (R-DEBT-3).
      let inflow = txn.isOneSidedInflow
      return Row(
        id: txn.id, type: .transfer, icon: Icon(symbol: "⇄", colorHex: nil),
        title: txn.payee.isEmpty ? "Debt" : txn.payee, badges: badges, subtitle: subtitle,
        category: "Debt", account: inflow ? "Debt → \(accountName)" : "\(accountName) → Debt",
        amount: format.string(minor: inflow ? txn.amountMinor : -txn.amountMinor, code: code, sign: .always),
        tone: .transfer, amountDetail: nil, lines: lines)
    case .transfer:
      let destination = txn.toAccountID.flatMap { reference.accountsByID[$0] }
      var detail: String?
      if let destination {
        if destination.currency != account?.currency, let received = txn.toAmountMinor {
          detail = "→ " + format.string(minor: received, code: destination.currency.rawValue, sign: .always)
        } else {
          detail = "→ " + destination.name
        }
      }
      return Row(
        id: txn.id, type: .transfer, icon: Icon(symbol: "⇄", colorHex: nil),
        title: txn.payee.isEmpty ? "Transfer" : txn.payee, badges: badges, subtitle: subtitle,
        category: "Transfer", account: "\(accountName) → \(destination?.name ?? "Unknown account")",
        amount: format.string(minor: -txn.amountMinor, code: code, sign: .always), tone: .transfer,
        amountDetail: detail, lines: lines)
    case .expense, .income:
      let category = tree.category(txn.categoryID)
      let inflow = (txn.type == .income) != txn.isRefund
      var detail: String?
      if let original = txn.originalAmountMinor, let originalCode = txn.originalCurrencyCode,
        originalCode.uppercased() != code
      {
        detail = "Charged " + format.string(minor: original, code: originalCode.uppercased())
      }
      return Row(
        id: txn.id, type: txn.type,
        icon: Icon(
          symbol: category.map { String($0.name.prefix(1)) } ?? "?",
          colorHex: category == nil ? reference.uncategorisedColor : tree.color(txn.categoryID)),
        title: txn.payee.isEmpty ? (category?.name ?? "No description") : txn.payee,
        badges: badges, subtitle: subtitle, category: tree.path(txn.categoryID) ?? Uncategorised.title,
        account: accountName,
        amount: format.string(minor: inflow ? txn.amountMinor : -txn.amountMinor, code: code, sign: .always),
        tone: inflow ? .inflow : .outflow, amountDetail: detail, lines: lines)
    }
  }
}

/// "Wednesday, 21 October"; "Monday, 29 December 2025" outside the current year.
struct TransactionDayTitles {
  let today: Day
  let calendar: Calendar
  let thisYear: DateFormatter
  let otherYear: DateFormatter

  init(today: Day, calendar: Calendar, locale: Locale) {
    self.today = today
    self.calendar = calendar
    thisYear = DateFormatter()
    thisYear.locale = locale
    thisYear.calendar = calendar
    thisYear.timeZone = calendar.timeZone
    thisYear.dateFormat = "EEEE, d MMMM"
    otherYear = DateFormatter()
    otherYear.locale = locale
    otherYear.calendar = calendar
    otherYear.timeZone = calendar.timeZone
    otherYear.dateFormat = "EEEE, d MMMM yyyy"
  }

  func title(_ day: Day) -> String {
    let date = day.date(calendar: calendar)
    return day.year == today.year ? thisYear.string(from: date) : otherYear.string(from: date)
  }
}

/// A converter that knows no rates (the empty placeholder content).
struct TransactionNoRates: CurrencyConverter {
  func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { from == to ? 1 : nil }
  func latestRate(from: Currency, to: Currency) -> Decimal? { from == to ? 1 : nil }
  var latestDay: Day? { nil }
}
