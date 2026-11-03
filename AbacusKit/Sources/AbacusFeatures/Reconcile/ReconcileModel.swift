import AbacusDomain
import Foundation
import Observation

/// N6 (R-CLR-5, R-CLR-6): the Reconcile screen of one account. Setup (statement date and closing
/// balance, or the counted cash), then the working screen: tick, add, edit, delete, mark settled,
/// correct. Everything is staged in memory and written by `finish`, in one database transaction.
@MainActor
@Observable
public final class ReconcileModel {
  public enum Phase: Hashable, Sendable { case loading, setup, working, failed(String) }

  public struct Row: Identifiable, Hashable, Sendable {
    public var id: Txn.ID
    public var day: String
    public var payee: String
    public var detail: String
    public var amount: String
    public var isInflow: Bool
    public var isTicked: Bool
    public var isCleared: Bool
    public var isPending: Bool
    public var isStaged: Bool
    public var isEdited: Bool
    public var canTick: Bool
    public var canEdit: Bool
    public var canDelete: Bool
    public var canSettle: Bool
    public var stateLabel: String
  }

  public struct AddForm: Hashable, Sendable {
    public var day: Date
    public var description = ""
    public var amountText = ""
    public var categoryID: AbacusDomain.Category.ID?
  }

  public struct EditForm: Hashable, Sendable {
    public var id: Txn.ID
    public var amountText: String
    public var day: Date
  }

  public private(set) var phase: Phase = .loading
  public private(set) var account: Account?
  public var statementDay = Date()
  public var closingText = ""
  /// Filled from the import's last running balance.
  public private(set) var fromImport = false
  public private(set) var last: Reconciliation?
  public var showCleared = false
  public var addForm: AddForm?
  public var editForm: EditForm?
  public private(set) var categories: [AbacusDomain.Category] = []
  public private(set) var notice: String?
  public var errorMessage: String?
  public private(set) var isBusy = false

  private var baseRows: [ReconcileRow] = []
  private var ticks: Set<Txn.ID> = []
  private var added: [Txn] = []
  private var edits: [Txn.ID: Txn] = [:]
  private var deleted: Set<Txn.ID> = []
  private var settled: Set<Txn.ID> = []

  @ObservationIgnored private let dependencies: ManageDependencies
  @ObservationIgnored private let accountID: Account.ID
  @ObservationIgnored private let offer: (day: Day, closingMinor: Int64)?
  @ObservationIgnored public var onClose: (() -> Void)?
  @ObservationIgnored public var onDataChanged: (() -> Void)?
  private var format: ManageFormat { dependencies.format }
  private var calendar: Calendar { format.calendar }

  public init(dependencies: ManageDependencies, accountID: Account.ID, offer: (day: Day, closingMinor: Int64)? = nil) {
    self.dependencies = dependencies
    self.accountID = accountID
    self.offer = offer
    fromImport = offer != nil
  }

  // MARK: Loading

  public func load() async {
    do {
      guard let account = try await dependencies.accounts.accounts(includeArchived: true).first(where: { $0.id == accountID }) else {
        phase = .failed("The account no longer exists.")
        return
      }
      self.account = account
      categories = (try? await dependencies.categories.categories(kind: nil, includeArchived: false)) ?? []
      let txns = try await dependencies.txns.transactions(matching: TxnQuery(accountIDs: [accountID], newestFirst: false))
      baseRows = Reconcile.rows(account: account, txns: txns, calendar: calendar)
      last = try await dependencies.reconcile?.lastReconciliations()[accountID]
      if phase == .loading {
        // The statement date: from the import, else the account's last booked day, else today.
        if let offer {
          statementDay = offer.day.date(calendar: calendar)
          closingText = Self.text(offer.closingMinor, account.currency)
        } else {
          let lastDay = baseRows.filter { !$0.isPending }.map(\.statementDay).max() ?? dependencies.today()
          statementDay = min(lastDay, dependencies.today()).date(calendar: calendar)
        }
        phase = .setup
      }
    } catch {
      phase = .failed("Couldn't load the account: \(error.localizedDescription)")
    }
  }

  static func text(_ minor: Int64, _ currency: Currency) -> String {
    let text = EditorAmount.text(minor: abs(minor), code: currency.rawValue)
    return minor < 0 ? "-" + text : text
  }

  /// A typed amount with an optional leading sign ("-12.50", "+5"): the magnitude and the sign
  /// typed, if any. `EditorAmount` itself rejects signs.
  static func signed(_ text: String) -> (value: Decimal, sign: Character?)? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var sign: Character?
    if let first = body.first, "+-\u{2212}".contains(first) {
      sign = first == "+" ? "+" : "-"
      body.removeFirst()
    }
    guard let value = EditorAmount.decimal(body) else { return nil }
    return (value, sign)
  }

  // MARK: Setup

  public var isCash: Bool { account?.kind == .cash }
  public var title: String { account.map { "Reconcile · \($0.name)" } ?? "Reconcile" }
  public var statementLabel: String { isCash ? "Counted cash" : "Statement closing balance" }
  public var dateLabel: String { isCash ? "Count date" : "Statement date" }
  public var currencyCode: String { account?.currency.rawValue ?? "" }

  public var closingMinor: Int64? {
    guard let account, let parsed = Self.signed(closingText) else { return nil }
    return Money(parsed.sign == "-" ? -parsed.value : parsed.value, account.currency).minorUnits
  }

  public var canStart: Bool { closingMinor != nil }

  public var setupSource: String {
    if fromImport { return "Filled from the file you just imported (its last booked day and running balance)." }
    if let last, let day = Day(last.statementDay) { return "Last reconciled to \(format.day(day)). Type the new balance." }
    return "First reconciliation of this account: type the values from your \(isCash ? "count" : "statement")."
  }

  public var lastReconciledText: String {
    guard let last, let account, let day = Day(last.statementDay) else { return "Never reconciled" }
    return "Last reconciled to \(format.day(day)) · " + format.money(Money(minorUnits: last.closingMinor, currency: account.currency))
  }

  public func start() {
    guard canStart else { return }
    phase = .working
  }

  public func changeStatement() {
    phase = .setup
  }

  // MARK: Staged rows and figures

  private var day: Day { Day(statementDay, calendar: calendar) }

  /// The rows as they stand with every staged change.
  private var liveRows: [ReconcileRow] {
    guard let account else { return [] }
    var rows: [ReconcileRow] = []
    for base in baseRows where !deleted.contains(base.id) {
      var txn = base.item.txn
      var edited = false
      if let edit = edits[base.id] { txn = edit; edited = true }
      if settled.contains(base.id) { txn.isPendingAtBank = false }
      let item = TxnWithLines(txn: txn, lines: base.item.lines)
      var row = ReconcileRow(
        item: item, effectMinor: Calc.effect(of: item, on: account.id), isCleared: base.isCleared,
        statementDay: edited ? Day(txn.occurredAt, calendar: calendar) : base.statementDay)
      if settled.contains(base.id) { row.isCleared = false }
      rows.append(row)
    }
    for txn in added where !deleted.contains(txn.id) {
      let item = TxnWithLines(txn: txn, lines: [])
      rows.append(
        ReconcileRow(
          item: item, effectMinor: Calc.effect(of: item, on: account.id), isCleared: true,
          statementDay: Day(txn.occurredAt, calendar: calendar)))
    }
    return rows
  }

  public var figures: ReconcileFigures? {
    guard let account, let closing = closingMinor else { return nil }
    return Reconcile.figures(
      account: account, rows: liveRows, statementMinor: closing, through: day, ticked: ticks, wholeBalance: isCash)
  }

  public var differenceMinor: Int64? { figures?.differenceMinor }
  public var isBalanced: Bool { differenceMinor == 0 }

  public var statementText: String { closingMinor.map(money) ?? "—" }
  public var clearedText: String { figures.map { money($0.clearedMinor) } ?? "—" }
  public var openingText: String { account.map { money($0.openingBalanceMinor) } ?? "" }
  public var differenceText: String {
    guard let difference = differenceMinor else { return "—" }
    return difference == 0 ? money(0) : (difference > 0 ? "+" : "−") + money(abs(difference))
  }

  public var differenceReason: String {
    guard let difference = differenceMinor else { return "Enter a balance" }
    if difference == 0 { return "Balanced — ready to finish" }
    return difference < 0
      ? "The statement is lower: a payment is missing from the cleared rows, or a ticked row is not on the statement"
      : "The statement is higher: income or a refund is missing from the cleared rows"
  }

  public var correctionText: String? {
    guard let difference = differenceMinor, difference != 0 else { return nil }
    return (difference > 0 ? "+" : "−") + money(abs(difference))
  }

  private func money(_ minor: Int64) -> String {
    guard let account else { return "" }
    return format.money(Money(minorUnits: minor, currency: account.currency))
  }

  private func item(_ row: ReconcileRow) -> Row {
    let txn = row.item.txn
    let account = self.account
    let isHandTyped = txn.source == .manual && !row.isCleared && txn.type != .transfer && txn.debtRecordID == nil
    let isStaged = added.contains { $0.id == txn.id }
    let state: String
    if row.isPending {
      state = "Pending — not on a statement"
    } else if isStaged {
      state = "Added now · cleared"
    } else if row.isCleared {
      state = "Cleared · \(txn.source == .pko ? "PKO" : txn.source == .saldo ? "Saldo" : "typed")"
    } else {
      state = (settled.contains(txn.id) ? "Settled by hand" : txn.source == .manual ? "Hand-typed" : txn.source == .pko ? "PKO" : "Saldo") + " · not cleared"
    }
    return Row(
      id: txn.id, day: format.day(row.statementDay), payee: txn.payee.isEmpty ? "—" : txn.payee,
      detail: txn.note.isEmpty ? (txn.bookedDay != nil && txn.bookedDay != Day(txn.occurredAt, calendar: calendar).string ? "purchased \(format.day(Day(txn.occurredAt, calendar: calendar)))" : "") : txn.note,
      amount: (row.effectMinor < 0 ? "−" : "+") + format.money(Money(minorUnits: abs(row.effectMinor), currency: account?.currency ?? .PLN)),
      isInflow: row.effectMinor > 0, isTicked: ticks.contains(txn.id) || row.isCleared, isCleared: row.isCleared,
      isPending: row.isPending, isStaged: isStaged, isEdited: edits[txn.id] != nil,
      canTick: !row.isPending && !row.isCleared, canEdit: isHandTyped || isStaged && txn.type != .transfer,
      canDelete: isHandTyped || isStaged || (row.isPending && txn.source == .pko),
      canSettle: row.isPending, stateLabel: state)
  }

  /// Uncleared rows up to the statement date, newest first: what to tick, add to, edit.
  public var toCheck: [Row] {
    liveRows.filter { $0.statementDay <= day && !$0.isCleared }.sorted { $0.statementDay > $1.statementDay }.map(item)
  }

  public var alreadyCleared: [Row] {
    liveRows.filter { $0.statementDay <= day && $0.isCleared }.sorted { $0.statementDay > $1.statementDay }.map(item)
  }

  public var afterDate: [Row] {
    liveRows.filter { $0.statementDay > day }.sorted { $0.statementDay > $1.statementDay }.map(item)
  }

  public var hasStaged: Bool {
    !ticks.isEmpty || !added.isEmpty || !edits.isEmpty || !deleted.isEmpty || !settled.isEmpty
  }

  /// The last reconciliation recomputed now: red note when it no longer adds up.
  public var driftNote: String? {
    guard let last, let account, let drift = Reconcile.drift(last, account: account, rows: baseRows),
      let day = Day(last.statementDay)
    else { return nil }
    return "Cleared rows up to \(format.day(day)) now give \(money(last.closingMinor + drift)), the statement said \(money(last.closingMinor)). A cleared row was edited or removed since."
  }

  // MARK: Staging

  public func setTicked(_ id: Txn.ID, _ ticked: Bool) {
    if ticked { ticks.insert(id) } else { ticks.remove(id) }
  }

  /// "Tick all" (cash: "Tick all up to the date").
  public func tickAll() {
    for row in liveRows where row.statementDay <= day && !row.isCleared && !row.isPending { ticks.insert(row.id) }
  }

  public func markSettled(_ id: Txn.ID) { settled.insert(id) }

  public func delete(_ id: Txn.ID) {
    if added.contains(where: { $0.id == id }) {
      added.removeAll { $0.id == id }
    } else {
      deleted.insert(id)
    }
    ticks.remove(id)
    edits[id] = nil
  }

  public func beginAdd() {
    addForm = AddForm(day: statementDay)
  }

  public var canSaveAdd: Bool {
    guard let form = addForm, let account else { return false }
    guard let parsed = Self.signed(form.amountText), parsed.value != 0 else { return false }
    _ = account
    return !form.description.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Adds a transaction the statement has and Abacus does not: already cleared, counted at once.
  public func saveAdd() {
    guard canSaveAdd, let form = addForm, let account, let parsed = Self.signed(form.amountText) else { return }
    let minor = Money(parsed.value, account.currency).minorUnits
    // Money out unless a "+" was typed.
    let isIncome = parsed.sign == "+"
    let kind: CategoryKind = isIncome ? .income : .expense
    let category = categories.first { $0.id == form.categoryID && $0.kind == kind }?.id
    var txn = Txn(
      type: isIncome ? .income : .expense,
      occurredAt: calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: form.day)) ?? form.day,
      accountID: account.id, amountMinor: minor, categoryID: category,
      payee: form.description.trimmingCharacters(in: .whitespaces), source: .manual)
    txn.setCleared(true, on: account.id)
    added.append(txn)
    addForm = nil
  }

  public func beginEdit(_ id: Txn.ID) {
    guard let row = liveRows.first(where: { $0.id == id }), let account else { return }
    editForm = EditForm(
      id: id, amountText: Self.text(row.item.txn.amountMinor, account.currency), day: row.item.txn.occurredAt)
  }

  public func commitEdit() {
    guard let form = editForm, let account, let value = EditorAmount.decimal(form.amountText), value != 0 else {
      editForm = nil
      return
    }
    let minor = Money(abs(value), account.currency).minorUnits
    if let index = added.firstIndex(where: { $0.id == form.id }) {
      added[index].amountMinor = minor
      added[index].occurredAt = form.day
    } else if let base = baseRows.first(where: { $0.id == form.id }) {
      var txn = edits[form.id] ?? base.item.txn
      txn.amountMinor = minor
      txn.occurredAt = form.day
      txn.bookedDay = nil
      edits[form.id] = txn
    }
    editForm = nil
  }

  public func cancel() {
    ticks = []
    added = []
    edits = [:]
    deleted = []
    settled = []
    addForm = nil
    editForm = nil
    onClose?()
  }

  // MARK: Finish

  /// Writes every staged change and the reconciliation. With `withCorrection` the remaining
  /// difference is booked as a "Balance correction" first; without it the difference must be 0.
  public func finish(withCorrection: Bool = false) async {
    guard let account, let closing = closingMinor, let difference = differenceMinor, !isBusy else { return }
    guard difference == 0 || withCorrection else { return }
    isBusy = true
    defer { isBusy = false }
    var clear = ticks
    if isCash {
      for row in liveRows where row.statementDay <= day && !row.isCleared && !row.isPending { clear.insert(row.id) }
    }
    // Rows added during the run are inserted cleared; ticking them again would be a no-op.
    clear.subtract(added.map(\.id))
    let request = ReconcileFinish(
      accountID: account.id, statementDay: day, closingMinor: closing, clearIDs: Array(clear), additions: added,
      edits: Array(edits.values), deletions: Array(deleted), settleIDs: Array(settled),
      correctionMinor: withCorrection ? difference : 0)
    do {
      try await dependencies.reconcile?.finish(request)
      let changed = clear.count + added.count + edits.count + deleted.count + settled.count + (withCorrection && difference != 0 ? 1 : 0)
      notice = "Reconciled \(account.name) to \(format.day(day)) at \(money(closing)). \(changed) row\(changed == 1 ? "" : "s") changed or marked cleared"
        + (withCorrection && difference != 0 ? ", balance correction \(correctionText ?? "") added" : "") + "."
      ticks = []
      added = []
      edits = [:]
      deleted = []
      settled = []
      let txns = try await dependencies.txns.transactions(matching: TxnQuery(accountIDs: [accountID], newestFirst: false))
      baseRows = Reconcile.rows(account: account, txns: txns, calendar: calendar)
      last = try await dependencies.reconcile?.lastReconciliations()[accountID]
      onDataChanged?()
    } catch {
      errorMessage = "Nothing was saved: \(error.localizedDescription)"
    }
  }

  public var categoryOptions: [(id: AbacusDomain.Category.ID, label: String)] {
    let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
    let kind: CategoryKind = addForm.flatMap({ Self.signed($0.amountText)?.sign }) == "+" ? .income : .expense
    return categories.filter { $0.kind == kind }.map { category in
      (category.id, category.parentID.flatMap { names[$0] }.map { "\($0) › \(category.name)" } ?? category.name)
    }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
  }
}
