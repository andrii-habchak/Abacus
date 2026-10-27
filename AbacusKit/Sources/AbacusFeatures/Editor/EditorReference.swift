import AbacusDomain
import AbacusImport
import Foundation

/// Accounts, categories, events and rules the editor offers and looks things up in.
public struct EditorReference: Sendable {
  public typealias CategoryID = AbacusDomain.Category.ID

  /// One entry of a category menu; children are indented under their parent (R-CAT-2).
  public struct CategoryOption: Identifiable, Hashable, Sendable {
    public var id: CategoryID
    public var name: String
    public var kind: CategoryKind
    public var isChild: Bool
  }

  /// A rule match for the description (R-EDIT-3).
  public struct Suggestion: Hashable, Sendable {
    public var rule: CategoryRule
    public var category: AbacusDomain.Category
  }

  /// Purchase currencies offered by the currency picker (approved prototype 3). Any other
  /// ISO code already on a transaction is added when it is edited (R-CUR-4).
  public static let currencyCodes = ["UAH", "PLN", "EUR", "USD", "CHF", "CZK", "GBP", "HUF"]

  public private(set) var accounts: [Account]
  public private(set) var categories: [AbacusDomain.Category]
  public private(set) var events: [Event]
  /// In evaluation order (the repository's order: position, then most used).
  public private(set) var rules: [CategoryRule]
  public private(set) var accountsByID: [Account.ID: Account]
  public private(set) var categoriesByID: [CategoryID: AbacusDomain.Category]

  public init(
    accounts: [Account] = [], categories: [AbacusDomain.Category] = [], events: [Event] = [],
    rules: [CategoryRule] = []
  ) {
    self.accounts = accounts.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    self.categories = categories
    self.events = events
    self.rules = rules
    accountsByID = Dictionary(accounts.map { ($0.id, $0) }) { first, _ in first }
    categoriesByID = Dictionary(categories.map { ($0.id, $0) }) { first, _ in first }
  }

  public func account(_ id: Account.ID?) -> Account? { id.flatMap { accountsByID[$0] } }
  public func category(_ id: CategoryID?) -> AbacusDomain.Category? { id.flatMap { categoriesByID[$0] } }

  // MARK: Pickers

  /// Active accounts (R-ACC-4: archived ones are hidden), plus `selected` when it is archived.
  public func accountOptions(including selected: [Account.ID?] = []) -> [Account] {
    let keep = Set(selected.compactMap { $0 })
    return accounts.filter { !$0.isArchived || keep.contains($0.id) }
  }

  /// "Monobank Black · UAH".
  public static func accountLabel(_ account: Account) -> String {
    "\(account.name) · \(account.currency.rawValue)"
  }

  /// Categories of `kind`, parents by position each followed by its children; archived ones
  /// are left out unless `selected`.
  public func categoryOptions(kind: CategoryKind, including selected: CategoryID? = nil) -> [CategoryOption] {
    let order: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = {
      ($0.position, $0.name) < ($1.position, $1.name)
    }
    let live = categories.filter { $0.kind == kind && (!$0.isArchived || $0.id == selected) }
    let liveIDs = Set(live.map(\.id))
    let children = Dictionary(grouping: live.filter { $0.parentID.map(liveIDs.contains) ?? false }) {
      $0.parentID!
    }
    var options: [CategoryOption] = []
    for parent in live.filter({ $0.parentID.map { !liveIDs.contains($0) } ?? true }).sorted(by: order) {
      options.append(CategoryOption(id: parent.id, name: parent.name, kind: kind, isChild: false))
      for child in (children[parent.id] ?? []).sorted(by: order) {
        options.append(CategoryOption(id: child.id, name: child.name, kind: kind, isChild: true))
      }
    }
    return options
  }

  /// "Groceries", or "Food › Groceries" for a child.
  public func categoryPath(_ id: CategoryID?) -> String? {
    guard let item = category(id) else { return nil }
    guard let parent = category(item.parentID) else { return item.name }
    return "\(parent.name) › \(item.name)"
  }

  /// Active events (newest start first, undated last), plus `selected` when archived.
  public func eventOptions(including selected: Event.ID? = nil) -> [Event] {
    events
      .filter { !$0.isArchived || $0.id == selected }
      .sorted { ($0.startDay ?? "", $1.name) > ($1.startDay ?? "", $0.name) }
  }

  /// "Lyon trip · 1–19 Oct", "Move · 28 Sep – 3 Oct", "Car · from 1 Oct", "Relocation".
  public static func eventLabel(_ event: Event, calendar: Calendar = .current) -> String {
    let start = event.startDay.flatMap(Day.init)
    let end = event.endDay.flatMap(Day.init)
    let month = { (day: Day) in
      day.date(calendar: calendar).formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }
    switch (start, end) {
    case let (start?, end?) where start.year == end.year && start.month == end.month:
      return start == end
        ? "\(event.name) · \(start.day) \(month(start))"
        : "\(event.name) · \(start.day)–\(end.day) \(month(end))"
    case let (start?, end?):
      return "\(event.name) · \(start.day) \(month(start)) – \(end.day) \(month(end))"
    case let (start?, nil):
      return "\(event.name) · from \(start.day) \(month(start))"
    case let (nil, end?):
      return "\(event.name) · until \(end.day) \(month(end))"
    case (nil, nil):
      return event.name
    }
  }

  // MARK: Rules and events

  /// R-EDIT-3 / R-IMP-8: the first enabled *category* rule whose conditions hold — description
  /// contains / exactly matches, amount (in the account's currency; nil = not typed yet, so
  /// amount rules do not match) and account; its category must exist, be active and of `kind`.
  /// Transfer rules are skipped here: the editor only suggests a category and never changes the
  /// transaction type on its own (they apply on import and "Update existing transactions").
  public func suggestion(
    for description: String, accountID: Account.ID?, kind: CategoryKind, amountMinor: Int64? = nil
  ) -> Suggestion? {
    // Same matching as imports and the rules tester (AbacusImport.RuleMatcher).
    let matcher = RuleMatcher(rules: rules, categories: Array(categoriesByID.values))
    guard let rule = matcher.match(description: description, accountID: accountID, kind: kind, amountMinor: amountMinor),
      let category = category(rule.categoryID)
    else { return nil }
    return Suggestion(rule: rule, category: category)
  }

  /// R-EVT-2: the event whose date range contains `day` (an event without a start day is never
  /// active; without an end day it runs on); the latest start wins when several are active.
  public func activeEvent(on day: Day) -> Event? {
    let text = day.string
    return events
      .filter { event in
        guard !event.isArchived, let start = event.startDay, start <= text else { return false }
        return event.endDay.map { $0 >= text } ?? true
      }
      .max { ($0.startDay ?? "", $1.name) < ($1.startDay ?? "", $0.name) }
  }

  /// The category "Add fee" uses: an active expense category named "Fees" (or "Fee").
  public var feesCategoryID: CategoryID? {
    categories.first {
      $0.kind == .expense && !$0.isArchived
        && ["fees", "fee"].contains($0.name.lowercased().trimmingCharacters(in: .whitespaces))
    }?.id
  }
}
