import AbacusDomain
import AbacusImport
import Foundation

// Display values of the import wizard (approved prototype 5), derived from the preview.

/// How a note under a control is coloured.
public enum ImportTone: Hashable, Sendable {
  case secondary
  /// Blue: something this import will save ("Will be saved as a rule").
  case info
  /// Green: remembered from an earlier import.
  case success
  /// Red: needs a decision ("Needs a category").
  case attention
}

public struct ImportNote: Hashable, Sendable {
  public var text: String
  public var tone: ImportTone

  public init(_ text: String, _ tone: ImportTone = .secondary) {
    self.text = text
    self.tone = tone
  }
}

// MARK: - Summary cards and tabs

public struct ImportCard: Identifiable, Hashable, Sendable {
  /// nil = "All rows".
  public var status: RowStatus?
  public var label: String
  public var count: String
  public var hint: String
  public var id: String { status?.rawValue ?? "all" }
}

public struct ImportTabItem: Identifiable, Hashable, Sendable {
  public var tab: ImportWizardModel.Tab
  public var label: String
  public var id: ImportWizardModel.Tab { tab }
}

// MARK: - Transactions tab

/// A category picker value: none, an existing category, or the file's category this import
/// creates.
public enum ImportCategoryChoice: Hashable, Sendable {
  case none
  case existing(AbacusDomain.Category.ID)
  case new(key: String)
}

public struct ImportCategoryOption: Identifiable, Hashable, Sendable {
  public var choice: ImportCategoryChoice
  public var label: String
  /// Indented under its parent in the menu.
  public var isChild: Bool
  public var id: ImportCategoryChoice { choice }
}

public struct ImportRowItem: Identifiable, Hashable, Sendable {
  public enum CategoryCell: Hashable, Sendable {
    /// Expense/income: the picker with its options and the note under it.
    case picker(selection: ImportCategoryChoice, options: [ImportCategoryOption], needsCategory: Bool)
    /// No picker: transfers, opening balances, rows not imported.
    case none
  }

  public var id: String
  public var status: RowStatus
  /// "New", "New transfer", "Already imported", …
  public var statusLabel: String
  public var date: String
  public var payee: String
  /// Detail line: what the importer did, original amount, tag, warnings.
  public var detail: String
  public var account: String
  public var amount: String
  public var isInflow: Bool
  /// Rows that are not imported are dimmed.
  public var isDimmed: Bool
  public var category: CategoryCell
  /// Possible duplicates: the chosen action.
  public var duplicateAction: DuplicateAction?
  public var note: ImportNote?
  /// The row's pick is saved as a rule unless turned off; nil when no rule is involved.
  public var savesRule: Bool?
}

// MARK: - Accounts & categories tab

public enum ImportMappingChoice: Hashable, Sendable {
  case create
  case existing(UUID)
}

public struct ImportMappingOption: Identifiable, Hashable, Sendable {
  public var choice: ImportMappingChoice
  public var label: String
  public var id: ImportMappingChoice { choice }
}

public struct ImportMappingItem: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case account, category
    /// Read-only (the PKO target account, own accounts recognised by their number).
    case fixed
  }

  public var id: String
  public var kind: Kind
  public var source: String
  public var meta: String
  public var selection: ImportMappingChoice
  public var options: [ImportMappingOption]
  public var note: ImportNote?

  /// The selected option's label (read-only rows show it as text).
  public var selectionLabel: String { options.first { $0.choice == selection }?.label ?? "" }
}

public struct ImportMappingGroup: Identifiable, Hashable, Sendable {
  public var title: String
  public var summary: String
  public var items: [ImportMappingItem]
  public var id: String { title }
}

// MARK: - Events tab

public struct ImportEventItem: Identifiable, Hashable, Sendable {
  public var tag: String
  public var count: String
  public var range: String
  public var isSelected: Bool
  /// "Goes to the existing event" when an event has the tag's name.
  public var note: String?
  public var id: String { tag }
}

// MARK: - Needs review tab

public enum ImportReviewOption: Hashable, Sendable {
  case pair
  case record(CategoryKind)
  case transfer
  case skip
}

public struct ImportReviewItem: Identifiable, Hashable, Sendable {
  public struct Option: Identifiable, Hashable, Sendable {
    public var option: ImportReviewOption
    public var label: String
    public var isEnabled: Bool
    public var id: ImportReviewOption { option }
  }

  public struct Candidate: Identifiable, Hashable, Sendable {
    public var choice: ReviewChoice
    public var label: String
    public var id: ReviewChoice { choice }
  }

  public struct AccountOption: Identifiable, Hashable, Sendable {
    public var id: Account.ID
    public var label: String
  }

  public var id: String
  public var title: String
  public var date: String
  public var detail: String
  public var options: [Option]
  /// The chosen option; nil until decided.
  public var selected: ImportReviewOption?
  /// What the importer suggests (`acceptSuggestions()` applies it).
  public var suggested: ImportReviewOption
  public var pairCandidates: [Candidate]
  public var selectedPair: ReviewChoice?
  /// Kind a "Record as …" choice records.
  public var recordKind: CategoryKind
  public var categoryOptions: [ImportCategoryOption]
  public var selectedCategory: AbacusDomain.Category.ID?
  public var transferAccounts: [AccountOption]
  public var selectedTransferAccount: Account.ID?
}

// MARK: - History

public struct ImportHistoryItem: Identifiable, Hashable, Sendable {
  public var batch: ImportBatch
  public var file: String
  public var when: String
  public var summary: String
  public var isUndone: Bool
  public var id: ImportBatch.ID { batch.id }
}

// MARK: - Formatting

/// Dates and amounts as the prototype shows them.
struct ImportFormat: Sendable {
  let calendar: Calendar
  let money = TransactionMoneyFormat()

  private func formatter(_ pattern: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = pattern
    return formatter
  }

  /// "21.10.2026"
  func day(_ date: Date) -> String { formatter("dd.MM.yyyy").string(from: date) }
  /// "21.10.2026 12:04"
  func dayTime(_ date: Date) -> String { formatter("dd.MM.yyyy HH:mm").string(from: date) }
  /// "21 Oct 2026, 18:40"
  func stamp(_ date: Date) -> String { formatter("d MMM yyyy, HH:mm").string(from: date) }
  /// "May 2025"
  func month(_ day: Day) -> String { formatter("MMM yyyy").string(from: day.date(calendar: calendar)) }
  /// "1 Jun 2024"
  func longDay(_ day: Day) -> String { formatter("d MMM yyyy").string(from: day.date(calendar: calendar)) }

  /// "May 2025" or "Jun 2024 – Aug 2024".
  func monthRange(_ first: Day, _ last: Day) -> String {
    let a = month(first)
    let b = month(last)
    return a == b ? a : "\(a) – \(b)"
  }

  func amount(_ minor: Int64, _ code: String, inflow: Bool) -> String {
    money.string(minor: inflow ? minor : -minor, code: code, sign: .always)
  }

  static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
  }
}

extension AccountKind {
  var importLabel: String {
    switch self {
    case .cash: "Cash"
    case .bank: "Bank"
    case .card: "Card"
    case .savings: "Savings"
    case .investment: "Investment"
    case .creditCard: "Credit card"
    case .loan: "Loan"
    case .debt: "Debt"
    }
  }
}

// MARK: - Model content

extension ImportWizardModel {
  // MARK: File bar

  public var formatLabel: String {
    switch file?.source {
    case .saldo: "Saldo export"
    case .pko: "PKO BP statement"
    case nil: ""
    }
  }

  /// "12 rows · 1 Jun 2024 – 3 Oct 2025"
  public var fileMeta: String {
    guard let preview else { return file?.currency.map { "Statement in \($0.rawValue)" } ?? "" }
    var parts = [ImportFormat.count(preview.rows.count + preview.parserSkippedCount, "row")]
    if file?.source == .pko { parts.append("Windows-1250") }
    if let range = preview.dateRange {
      parts.append(
        range.lowerBound == range.upperBound
          ? format.longDay(range.lowerBound) : "\(format.longDay(range.lowerBound)) – \(format.longDay(range.upperBound))")
    }
    return parts.joined(separator: " · ")
  }

  /// PKO: "remembered" next to the target picker when it came from the last import.
  public var targetRemembered: Bool { preview?.targetRemembered ?? false }

  // MARK: Cards and tabs

  /// Summary cards (they filter the rows). Already imported, possible duplicates and settle
  /// pending appear for PKO statements or when the file has such rows; Skipped only when there
  /// are any.
  public var cards: [ImportCard] {
    guard let preview else { return [] }
    let counts = preview.counts
    var cards = [ImportCard(status: nil, label: "All rows", count: counts.all.formatted(), hint: "in this file")]
    let all: [(RowStatus, String, String)] = [
      (.new, "New", "will be imported"),
      (.alreadyImported, "Already imported", "skipped automatically"),
      (.possibleDuplicate, "Possible duplicates", "skipped unless you choose"),
      (.settlesPending, "Settle pending", "update earlier holds"),
      (.needsReview, "Needs review", "resolve before import"),
      (.skipped, "Skipped", "not imported"),
    ]
    for (status, label, hint) in all {
      let shown: Bool = switch status {
      case .new, .needsReview: true
      case .alreadyImported, .possibleDuplicate, .settlesPending: preview.source == .pko || counts[status] > 0
      case .skipped: counts[status] > 0
      }
      if shown { cards.append(ImportCard(status: status, label: label, count: counts[status].formatted(), hint: hint)) }
    }
    return cards
  }

  public var tabs: [ImportTabItem] {
    guard let preview else { return [] }
    var tabs = [
      ImportTabItem(tab: .transactions, label: "Transactions"),
      ImportTabItem(tab: .mapping, label: "Accounts & categories"),
    ]
    if preview.source == .saldo { tabs.append(ImportTabItem(tab: .events, label: "Events from tags")) }
    tabs.append(ImportTabItem(tab: .review, label: "Needs review (\(preview.counts.needsReview.formatted()))"))
    return tabs
  }

  // MARK: Rows

  func makeRowItems(_ preview: ImportPreview) -> [ImportRowItem] {
    preview.rows.map { rowItem($0, preview) }
  }

  private func rowItem(_ row: PreviewRow, _ preview: ImportPreview) -> ImportRowItem {
    let code = row.source.account.currency.rawValue
    var accountText = preview.name(of: row.account)
    if let counter = row.counterAccount, row.type == .transfer {
      let counterName = preview.name(of: counter)
      accountText = row.isInflow ? "\(counterName) → \(accountText)" : "\(accountText) → \(counterName)"
    }
    var label: String = switch row.status {
    case .new: "New"
    case .alreadyImported: "Already imported"
    case .possibleDuplicate: "Possible duplicate"
    case .settlesPending: "Settles pending"
    case .needsReview: "Needs review"
    case .skipped: "Skipped"
    }
    if row.status == .new, row.type == .transfer { label = "New transfer" }
    if row.status == .new, row.source.kind == .openingBalance { label = "Opening balance" }

    var item = ImportRowItem(
      id: row.id, status: row.status, statusLabel: label, date: format.day(row.day),
      payee: row.source.payee.isEmpty ? "—" : row.source.payee, detail: detail(row), account: accountText,
      amount: format.amount(row.amountMinor, code, inflow: row.isInflow), isInflow: row.isInflow,
      isDimmed: row.status == .alreadyImported || row.status == .skipped || (row.status == .possibleDuplicate && row.duplicate?.action == .skip),
      category: .none, duplicateAction: row.duplicate?.action, note: nil, savesRule: nil)

    switch row.status {
    case .alreadyImported:
      item.note = ImportNote("Skipped")
      return item
    case .skipped:
      item.note = ImportNote("Not imported")
      return item
    case .settlesPending:
      item.note = ImportNote("Updates the pending payment")
      return item
    case .needsReview:
      item.note = row.review?.choice == nil
        ? ImportNote("Decide in Needs review", .attention) : ImportNote("Decided in Needs review")
      return item
    case .possibleDuplicate:
      guard row.duplicate?.action == .importAnyway else { return item }
    case .new:
      break
    }
    switch row.type {
    case .transfer:
      item.note = ImportNote("Transfer — no category")
    case nil:
      item.note = ImportNote("Opening balance — no category")
    case .expense, .income:
      let kind: CategoryKind = row.type == .income ? .income : .expense
      let selection: ImportCategoryChoice = switch row.category {
      case .existing(let id): .existing(id)
      case .new(let key): .new(key: key)
      case nil: .none
      }
      var options = [ImportCategoryOption(choice: .none, label: "Choose category…", isChild: false)]
      if case .new(let key) = selection {
        options.append(ImportCategoryOption(choice: .new(key: key), label: "\(preview.name(of: CategoryRef.new(key: key))) (new)", isChild: false))
      }
      options += categoryOptions(kind)
      item.category = .picker(selection: selection, options: options, needsCategory: row.needsCategory)
      switch row.categorySource {
      case .rule(_, let pattern):
        item.note = ImportNote("By rule “\(pattern)”")
      case .learnedRule(let pattern):
        item.note = ImportNote("By new rule “\(pattern)”", .info)
      case .user:
        if let pattern = row.rulePattern {
          item.note = ImportNote("Will be saved as a rule “\(pattern)”", .info)
          item.savesRule = true
        } else if noRuleRows.contains(row.id) {
          item.note = ImportNote("Not saved as a rule")
          item.savesRule = false
        }
      case .none:
        if row.needsCategory { item.note = ImportNote("Needs a category", .attention) }
      case .file, .notApplicable:
        break
      }
    }
    return item
  }

  private func detail(_ row: PreviewRow) -> String {
    var parts: [String] = []
    if let detail = row.detail { parts.append(detail) }
    if let original = row.source.original {
      parts.append("Charged " + format.money.string(minor: original.minorUnits, code: original.currencyCode))
    }
    if !row.source.lines.isEmpty {
      parts.append(ImportFormat.count(row.source.lines.count, "attached record"))
    }
    if let tag = row.source.tag, !tag.isEmpty {
      parts.append(row.eventTag != nil ? "tag “\(tag)” → event" : "tag “\(tag)”")
    }
    if !row.source.note.isEmpty, row.source.note != row.source.payee {
      parts.append(row.source.note.replacingOccurrences(of: "\n", with: " "))
    }
    if let warning = row.warnings.first {
      parts.append("Warning: " + warning)
    }
    return parts.joined(separator: " · ")
  }

  /// Active categories of `kind` as "Parent › Child", parents first.
  func categoryOptions(_ kind: CategoryKind) -> [ImportCategoryOption] {
    let live = categories.filter { $0.kind == kind && !$0.isArchived }
    let order: (AbacusDomain.Category, AbacusDomain.Category) -> Bool = { ($0.position, $0.name) < ($1.position, $1.name) }
    var options: [ImportCategoryOption] = []
    for parent in live.filter({ $0.parentID == nil }).sorted(by: order) {
      options.append(ImportCategoryOption(choice: .existing(parent.id), label: parent.name, isChild: false))
      for child in live.filter({ $0.parentID == parent.id }).sorted(by: order) {
        options.append(ImportCategoryOption(choice: .existing(child.id), label: "\(parent.name) › \(child.name)", isChild: true))
      }
    }
    return options
  }

  func categoryPath(_ id: AbacusDomain.Category.ID) -> String {
    guard let category = categories.first(where: { $0.id == id }) else { return "?" }
    guard let parent = category.parentID.flatMap({ p in categories.first { $0.id == p } }) else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  // MARK: Accounts & categories

  public var mappingGroups: [ImportMappingGroup] {
    guard let preview else { return [] }
    switch preview.source {
    case .saldo:
      return [accountGroup(preview, title: "Accounts"), categoryGroup(preview)]
    case .pko:
      var target: [ImportMappingItem] = []
      if let id = preview.targetAccountID, let account = accounts.first(where: { $0.id == id }) {
        target.append(
          ImportMappingItem(
            id: "statement", kind: .fixed, source: "This file", meta: "PKO BP · \(account.currency.rawValue)",
            selection: .existing(id), options: [ImportMappingOption(choice: .existing(id), label: accountLabel(account))],
            note: preview.targetRemembered
              ? ImportNote("Remembered from the last PKO import", .success) : ImportNote("Chosen above")))
      }
      var counterparties = accountGroup(preview, title: "Counterparties")
      let own = ownAccountItems(preview)
      counterparties.items += own
      counterparties.summary =
        counterparties.items.isEmpty ? "none in this file" : "\(counterparties.items.count.formatted()) recognised"
      return [ImportMappingGroup(title: "Account", summary: "chosen above", items: target), counterparties]
    }
  }

  private func accountLabel(_ account: Account) -> String {
    "\(account.name) · \(account.currency.rawValue)" + (account.isArchived ? " (archived)" : "")
  }

  private func accountGroup(_ preview: ImportPreview, title: String) -> ImportMappingGroup {
    let items = preview.accountMappings.map { mapping -> ImportMappingItem in
      let external = mapping.external
      var meta = [(external.kind ?? mapping.newKind).importLabel, external.currency.rawValue, ImportFormat.count(mapping.rowCount, "row")]
      if external.isArchived { meta.append("archived in Saldo") }
      var options = [
        ImportMappingOption(
          choice: .create,
          label: "Create “\(mapping.newName)” (\(mapping.newKind.importLabel)\(mapping.newIsArchived ? ", archived" : ""))")
      ]
      options += preview.accountOptions(for: mapping.id).map { ImportMappingOption(choice: .existing($0.id), label: accountLabel($0)) }
      let selection: ImportMappingChoice = switch mapping.target {
      case .create: .create
      case .existing(let id): .existing(id)
      }
      let note: ImportNote? = switch mapping.origin {
      case .remembered: ImportNote("Remembered", .success)
      case .sameName: ImportNote("Same name")
      case .cashAccount: ImportNote("Your cash account in \(external.currency.rawValue)")
      case .user: ImportNote("Mapped by you")
      case .new:
        if mapping.newKind.isLiability {
          ImportNote("Liability → \(mapping.newKind.importLabel) account")
        } else if mapping.newIsArchived {
          ImportNote("Created archived")
        } else if preview.source == .pko, external.name == "Cash" {
          ImportNote("ATM withdrawals")
        } else {
          nil
        }
      }
      return ImportMappingItem(
        id: mapping.id, kind: .account, source: external.name, meta: meta.joined(separator: " · "),
        selection: selection, options: options, note: note)
    }
    let created = preview.accountMappings.filter { $0.target == .create }.count
    return ImportMappingGroup(
      title: title, summary: "\(ImportFormat.count(items.count, "account")) in the file · \(created.formatted()) new",
      items: items)
  }

  private func categoryGroup(_ preview: ImportPreview) -> ImportMappingGroup {
    let items = preview.categoryMappings.map { mapping -> ImportMappingItem in
      let external = mapping.external
      let name = external.parentName.map { "\($0) › \(external.name)" } ?? external.name
      let kind = external.kind == .income ? "Income" : "Expense"
      var options = [ImportMappingOption(choice: .create, label: "Create “\(external.name)”")]
      options += preview.categoryOptions(for: mapping.id)
        .filter { !$0.isArchived }
        .map { ImportMappingOption(choice: .existing($0.id), label: categoryPath($0.id)) }
      let selection: ImportMappingChoice = switch mapping.target {
      case .create: .create
      case .existing(let id): .existing(id)
      }
      if case .existing(let id) = selection, !options.contains(where: { $0.choice == selection }) {
        options.append(ImportMappingOption(choice: selection, label: categoryPath(id) + " (archived)"))
      }
      let note: ImportNote? = switch mapping.origin {
      case .remembered: ImportNote("Remembered", .success)
      case .sameName: ImportNote("Same name")
      case .user: ImportNote("Mapped by you")
      case .new: nil
      }
      return ImportMappingItem(
        id: mapping.id, kind: .category, source: name,
        meta: "\(kind) · \(ImportFormat.count(mapping.rowCount, "row"))", selection: selection, options: options, note: note)
    }
    let created = preview.categoryMappings.filter { $0.target == .create }.count
    return ImportMappingGroup(
      title: "Categories",
      summary: "\(ImportFormat.count(items.count, "category", "categories")) in the file · \(created.formatted()) new",
      items: items)
  }

  /// PKO counterparties recognised as own accounts by their account number (R-IMP-PKO-3).
  private func ownAccountItems(_ preview: ImportPreview) -> [ImportMappingItem] {
    var seen: Set<String> = []
    var items: [ImportMappingItem] = []
    for row in preview.rows {
      guard row.type == .transfer, let number = row.source.counterpartyIBAN, case .existing(let id)? = row.counterAccount,
        let account = accounts.first(where: { $0.id == id }), seen.insert(number).inserted
      else { continue }
      let digits = number.filter(\.isNumber)
      let masked = digits.count > 6 ? "\(digits.prefix(2)) … \(digits.suffix(4))" : number
      items.append(
        ImportMappingItem(
          id: "iban|\(number)", kind: .fixed, source: masked,
          meta: "\(row.isInflow ? "Sender" : "Recipient") of “\(row.source.payee)”", selection: .existing(id),
          options: [ImportMappingOption(choice: .existing(id), label: accountLabel(account) + " (own account)")],
          note: ImportNote("Matched by account number → transfer")))
    }
    return items
  }

  // MARK: Events from tags

  public var eventItems: [ImportEventItem] {
    guard let preview else { return [] }
    return preview.eventCandidates.map { candidate in
      ImportEventItem(
        tag: candidate.tag, count: ImportFormat.count(candidate.rowCount, "transaction"),
        range: format.monthRange(candidate.firstDay, candidate.lastDay), isSelected: candidate.isSelected,
        note: candidate.existingEventID != nil ? "Goes to the existing event" : nil)
    }
  }

  // MARK: Needs review

  public var reviewIntro: String {
    file?.source == .saldo
      ? "Transfer halves Saldo booked through “Money on the way” that could not be paired automatically "
        + "(same transit amount and currency, different accounts, ≤ 3 days apart)."
      : "Rows the importer could not place confidently. Each needs a decision before importing."
  }

  /// Review rows still without a decision.
  public var unresolvedReviewCount: Int { preview?.unresolvedReviewCount ?? 0 }

  func makeReviewItems(_ preview: ImportPreview) -> [ImportReviewItem] {
    preview.rows.compactMap { row in
      guard let review = row.review else { return nil }
      return reviewItem(row, review, preview)
    }
  }

  private func reviewItem(_ row: PreviewRow, _ review: ReviewInfo, _ preview: ImportPreview) -> ImportReviewItem {
    let code = row.source.account.currency.rawValue
    let amount = format.amount(row.amountMinor, code, inflow: row.isInflow)
    let accountName = preview.name(of: row.account)
    let recordKind: CategoryKind = row.isInflow ? .income : .expense
    var title: String
    var detail: String
    var options: [ImportReviewItem.Option] = []

    var candidates: [ImportReviewItem.Candidate] = review.pairRows.compactMap { id in
      guard let other = preview.row(id) else { return nil }
      let otherAmount = format.amount(other.amountMinor, other.source.account.currency.rawValue, inflow: other.isInflow)
      return ImportReviewItem.Candidate(
        choice: .pair(rowID: id),
        label: "\(otherAmount) \(preview.name(of: other.account)) · \(format.dayTime(other.day))")
    }
    candidates += review.pairExisting.map { txn in
      let account = accounts.first { $0.id == txn.accountID }
      let text = format.amount(txn.amountMinor, account?.currency.rawValue ?? code, inflow: false)
      return ImportReviewItem.Candidate(
        choice: .pairExisting(txn.id),
        label: "\(text) \(txn.payee) · \(account?.name ?? "?") · \(format.day(txn.occurredAt)) (existing)")
    }

    switch review.reason {
    case .unpairedTransferHalf(let direction):
      let transit = row.source.transferHalf?.transit
      let transitText = transit.flatMap { $0.currencyCode == code ? nil : format.money.string(minor: $0.minorUnits, code: $0.currencyCode) }
      if direction == .outgoing {
        title = "Outgoing transfer half without a match"
        detail = "\(amount) from “\(accountName)” via Money on the way"
      } else {
        title = "Incoming transfer half without a match"
        detail = "\(amount) into “\(accountName)” from Money on the way"
      }
      if let transitText { detail += " (\(transitText) in transit)" }
      detail += "."
      if let hint = row.source.transferHalf?.counterpartHint, !hint.isEmpty, hint.caseInsensitiveCompare("Money on the way") != .orderedSame {
        detail += " Saldo hints the other side is “\(hint)”."
      } else if candidates.isEmpty {
        detail += " No other half within 3 days; often a payment to or from another person."
      }
      if !row.source.payee.isEmpty { title += " · \(row.source.payee)" }
      options = [
        .init(option: .pair, label: candidates.isEmpty ? "Pair with — no candidates found" : "Pair with", isEnabled: !candidates.isEmpty),
        .init(option: .record(recordKind), label: recordKind == .expense ? "Record as expense" : "Record as income", isEnabled: true),
        .init(option: .skip, label: "Skip", isEnabled: true),
      ]
    case .unknownOperationType, .transferAmountUnknown:
      if case .unknownOperationType = review.reason {
        title = "Unknown operation type"
        detail = "“\(row.source.payee)”, \(amount) on “\(accountName)”. The sign says money went \(row.isInflow ? "in" : "out")."
      } else {
        title = "Transfer to an own account in another currency"
        detail = "“\(row.source.payee)”, \(amount) on “\(accountName)”. The amount on the other account is unknown."
      }
      if !row.source.note.isEmpty { detail += " Title: \(row.source.note)." }
      options = [
        .init(option: .record(recordKind), label: recordKind == .expense ? "Expense" : "Income", isEnabled: true),
        .init(option: .transfer, label: "Transfer to my account", isEnabled: true),
        .init(option: .skip, label: "Skip", isEnabled: true),
      ]
    }

    var selected: ImportReviewOption?
    var selectedPair: ReviewChoice?
    var selectedCategory: AbacusDomain.Category.ID?
    var selectedTransfer: Account.ID?
    switch review.choice {
    case .pair, .pairExisting:
      selected = .pair
      selectedPair = review.choice
    case .record(let kind, let categoryID):
      selected = .record(kind)
      selectedCategory = categoryID
    case .transfer(let id):
      selected = .transfer
      selectedTransfer = id
    case .skip:
      selected = .skip
    case nil:
      break
    }
    let suggested: ImportReviewOption = switch review.suggested {
    case .pair, .pairExisting: .pair
    case .record(let kind, _): .record(kind)
    case .transfer: .transfer
    case .skip: .skip
    }
    let ownID: Account.ID? = if case .existing(let id) = row.account { id } else { nil }
    let transferAccounts = accounts.filter { !$0.isArchived && $0.id != ownID }
      .map { ImportReviewItem.AccountOption(id: $0.id, label: accountLabel($0)) }
    return ImportReviewItem(
      id: row.id, title: title, date: format.day(row.day), detail: detail, options: options, selected: selected,
      suggested: suggested, pairCandidates: candidates, selectedPair: selectedPair, recordKind: recordKind,
      categoryOptions: [ImportCategoryOption(choice: .none, label: "No category", isChild: false)] + categoryOptions(recordKind),
      selectedCategory: selectedCategory, transferAccounts: transferAccounts, selectedTransferAccount: selectedTransfer)
  }

  // MARK: Footer

  /// "3 transactions still without a category (they import uncategorised). 1 new rule will be
  /// saved from your choices. All or nothing: if anything fails, nothing is saved."
  public var footerNote: String {
    guard let preview else { return "" }
    var text = ""
    if preview.uncategorisedCount > 0 {
      text += ImportFormat.count(preview.uncategorisedCount, "transaction") + " still without a category (they import uncategorised). "
    }
    if !preview.rulesToSave.isEmpty {
      text += ImportFormat.count(preview.rulesToSave.count, "new rule") + " will be saved from your choices. "
    }
    return text + "All or nothing: if anything fails, nothing is saved."
  }

  /// Why Import is disabled: undecided review rows or other issues.
  public var blockingNote: String? {
    guard let preview else { return nil }
    var parts: [String] = []
    if preview.unresolvedReviewCount > 0 {
      parts.append(ImportFormat.count(preview.unresolvedReviewCount, "row") + " in Needs review still " + (preview.unresolvedReviewCount == 1 ? "needs" : "need") + " a decision.")
    }
    parts += preview.issues
    if parts.isEmpty, !hasWork { parts.append("Nothing new in this file.") }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// The commit changes something: new transactions, opening balances, settled holds or links.
  var hasWork: Bool {
    guard let preview else { return false }
    return preview.transactionsToCreate > 0 || preview.counts.settlesPending > 0
      || preview.rows.contains { $0.source.kind == .openingBalance && $0.status == .new }
      || preview.rows.contains { $0.duplicate?.action == .link }
      || preview.rows.contains { $0.status == .alreadyImported && $0.type == .transfer && $0.counterAccount != nil }
  }

  public var canCommit: Bool {
    guard let preview, !isBusy else { return false }
    return preview.canCommit && hasWork
  }

  public var commitLabel: String {
    guard let preview else { return "Import" }
    if activity == .committing { return "Importing…" }
    let n = preview.transactionsToCreate
    return n > 0 ? "Import " + ImportFormat.count(n, "transaction") : "Import"
  }

  // MARK: Done

  public var doneTitle: String {
    switch summary?.batch.source {
    case .pko: "PKO statement imported"
    case .saldo: "Saldo history imported"
    case nil: "Imported"
    }
  }

  public var doneLines: [String] { summary?.lines ?? [] }

  // MARK: History

  public var historyItems: [ImportHistoryItem] {
    history.map { batch in
      ImportHistoryItem(
        batch: batch, file: batch.fileName, when: format.stamp(batch.importedAt),
        summary: batch.summary.isEmpty ? (batch.source == .pko ? "PKO BP" : "Saldo") : batch.summary,
        isUndone: batch.isUndone)
    }
  }
}
