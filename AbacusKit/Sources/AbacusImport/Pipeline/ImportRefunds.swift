import AbacusDomain
import Foundation

// C35: an incoming row that looks like the refund of an expense is offered as one. The expense is
// an existing transaction (found by the pipeline through `RefundRepository`, stored as
// `existingRefundSuggestions`) or another row of the same file. Accepting turns the row into an
// expense refund in the expense's category; the commit stores the link on the new transaction in
// the same database transaction, so undo and re-import need nothing special.

extension ImportPreview {
  /// A suggestion needs the same description and the same amount (C30's score of 70).
  static let refundSuggestionScore = 70

  /// The row's facts for the candidate search of the existing expenses; nil when the row cannot
  /// be a refund or its account does not exist yet (only rows of the file can match then).
  public func refundProbe(forRow id: String) -> RefundProbe? {
    guard let i = rowIndex(id), let probe = RefundMatcher(preview: self, rows: rows, plans: plans).probe(i) else { return nil }
    return probe
  }

  /// Probes of every row that can still be offered as a refund (not declined, not accepted).
  public var refundProbes: [(rowID: String, probe: RefundProbe)] {
    let matcher = RefundMatcher(preview: self, rows: rows, plans: plans)
    return rows.indices.compactMap { i in
      guard rows[i].refundOf == nil, !rows[i].refundDeclined, let probe = matcher.probe(i) else { return nil }
      return (rows[i].id, probe)
    }
  }

  /// Stores what the pipeline found among the existing expenses (rows without an entry have none).
  mutating func setExistingRefundSuggestions(_ suggestions: [String: ImportRefundOriginal]) {
    existingRefundSuggestions = suggestions
    recompute()
  }

  /// Expenses of this file the row may be the refund of, best first (`search` filters by
  /// description and drops the date window). The existing ones come from
  /// `ImportPipeline.refundOptions`.
  public func fileRefundOptions(forRow id: String, matching search: String = "", limit: Int = 30) -> [ImportRefundOriginal] {
    guard let i = rowIndex(id) else { return [] }
    let matcher = RefundMatcher(preview: self, rows: rows, plans: plans)
    guard matcher.eligible(i) else { return [] }
    var used: [ImportRefundOriginal.Ref: Int64] = [:]
    for (k, row) in rows.enumerated() where k != i {
      if let ref = row.refundOf?.ref { used[ref, default: 0] += matcher.amount(k) }
    }
    return Array(matcher.options(forRow: i, matching: search, used: used).prefix(max(0, limit)))
  }

  /// Accepts the row as a refund of `original` ("Accept", "Choose another…"). False when the row
  /// cannot be a refund of it: another currency, or together with the refunds already accepted
  /// it would be more than the expense cost.
  @discardableResult
  public mutating func acceptRefund(_ original: ImportRefundOriginal, forRow id: String) -> Bool {
    guard let i = rowIndex(id) else { return false }
    let matcher = RefundMatcher(preview: self, rows: rows, plans: plans)
    guard matcher.eligible(i) else { return false }
    var used: [ImportRefundOriginal.Ref: Int64] = [:]
    for (k, row) in rows.enumerated() where k != i {
      if let ref = row.refundOf?.ref { used[ref, default: 0] += matcher.amount(k) }
    }
    guard matcher.validate(original, forRow: i, used: used) != nil else { return false }
    decisions.refunds[id] = .accepted(original)
    recompute()
    return rows[i].refundOf != nil
  }

  /// "Not a refund": an ordinary row again, and the suggestion does not come back.
  public mutating func declineRefund(forRow id: String) {
    decisions.refunds[id] = .declined
    recompute()
  }

  /// Back to undecided: the suggestion is offered again.
  public mutating func resetRefund(forRow id: String) {
    decisions.refunds[id] = nil
    recompute()
  }

  fileprivate func rowIndex(_ id: String) -> Int? { rows.firstIndex { $0.id == id } }
}

/// Matching of incoming rows with expenses of the same file, over one state of rows and plans.
struct RefundMatcher {
  let preview: ImportPreview
  let rows: [PreviewRow]
  let plans: [RowPlan]
  /// Rows of the file that can be the expense of a refund, by account and amount (suggestions).
  private let byAmount: [AmountKey: [Int]]
  /// Existing transactions another row settles, links or converts: never an original.
  private let touched: Set<Txn.ID>
  private let folded: [Int: String]

  struct AmountKey: Hashable {
    var account: AccountRef
    var amount: Int64
  }

  static let windowDays = 60

  init(preview: ImportPreview, rows: [PreviewRow], plans: [RowPlan]) {
    self.preview = preview
    self.rows = rows
    self.plans = plans
    var byAmount: [AmountKey: [Int]] = [:]
    var touched = Set<Txn.ID>()
    var folded: [Int: String] = [:]
    for (j, plan) in plans.enumerated() {
      switch plan {
      case .settle(let txn, _), .link(let txn, _), .convert(let txn, _), .completeEstimate(let txn, _, _, _):
        touched.insert(txn.id)
      case .create(let shape):
        guard Self.isOriginal(shape, rows[j]) else { continue }
        byAmount[AmountKey(account: shape.from, amount: shape.amountMinor), default: []].append(j)
        folded[j] = Self.fold(shape.payee)
      case .nothing, .openingBalance:
        break
      }
    }
    self.byAmount = byAmount
    self.touched = touched
    self.folded = folded
  }

  static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  static func isOriginal(_ shape: TxnShape, _ row: PreviewRow) -> Bool {
    row.createsTransaction && row.status == .new && shape.type == .expense && !shape.isRefund && shape.debt == nil
      && shape.amountMinor > 0
  }

  func amount(_ i: Int) -> Int64 {
    if case .create(let shape) = plans[i] { return shape.amountMinor }
    return 0
  }

  /// A new money-in row without attached records that is no transfer and no debt record: an
  /// income, or an expense marked as a refund.
  func eligible(_ i: Int) -> Bool {
    guard case .create(let shape) = plans[i], rows[i].status == .new, rows[i].review == nil, shape.debt == nil,
      shape.lines.isEmpty, shape.amountMinor > 0
    else { return false }
    switch shape.type {
    case .income: return !shape.isRefund
    case .expense: return shape.isRefund
    case .transfer: return false
    }
  }

  func probe(_ i: Int) -> RefundProbe? {
    guard eligible(i), case .create(let shape) = plans[i], case .existing(let accountID) = shape.from else { return nil }
    return RefundProbe(accountID: accountID, amountMinor: shape.amountMinor, payee: shape.payee, occurredAt: shape.occurredAt)
  }

  private func currency(_ i: Int) -> Currency? { preview.currency(of: rows[i].account) }

  // MARK: Validation

  /// `original` as it stands now when row `i` may be accepted as its refund (`used`: what the
  /// other accepted rows already return of each expense); nil otherwise.
  func validate(_ original: ImportRefundOriginal, forRow i: Int, used: [ImportRefundOriginal.Ref: Int64]) -> ImportRefundOriginal? {
    guard eligible(i), let currency = currency(i), original.currency == currency else { return nil }
    let amount = amount(i)
    var current = original
    switch original.ref {
    case .existing(let id):
      guard !touched.contains(id) else { return nil }
    case .row(let rowID):
      guard let j = rows.firstIndex(where: { $0.id == rowID }), j != i, case .create(let shape) = plans[j],
        Self.isOriginal(shape, rows[j]), shape.from == plans[i].shapeAccount, self.currency(j) == currency
      else { return nil }
      current = Self.original(row: rows[j], shape: shape, currency: currency, remaining: shape.amountMinor)
      current.score = original.score
      current.isSameAmount = original.isSameAmount
    }
    guard used[current.ref, default: 0] + amount <= current.remainingMinor else { return nil }
    return current
  }

  static func original(row: PreviewRow, shape: TxnShape, currency: Currency, remaining: Int64) -> ImportRefundOriginal {
    ImportRefundOriginal(
      ref: .row(row.id), payee: shape.payee, occurredAt: shape.occurredAt, amountMinor: shape.amountMinor,
      currency: currency, remainingMinor: remaining)
  }

  // MARK: Suggestions and options

  /// The expense row `i` looks like the refund of, offered without asking: the same description
  /// and the same amount (score 70), among the existing expenses the pipeline found and the
  /// expenses of this file.
  func suggestion(forRow i: Int, used: [ImportRefundOriginal.Ref: Int64]) -> ImportRefundOriginal? {
    guard eligible(i), case .create(let shape) = plans[i], let currency = currency(i) else { return nil }
    var best: ImportRefundOriginal?
    if let existing = preview.existingRefundSuggestions[rows[i].id], existing.currency == currency,
      case .existing(let id) = existing.ref, !touched.contains(id),
      existing.remainingMinor - used[existing.ref, default: 0] == shape.amountMinor
    {
      best = existing
    }
    let payee = Self.fold(shape.payee)
    if !payee.isEmpty {
      for j in byAmount[AmountKey(account: shape.from, amount: shape.amountMinor)] ?? [] where j != i && folded[j] == payee {
        guard case .create(let other) = plans[j], self.currency(j) == currency, used[.row(rows[j].id), default: 0] == 0,
          other.occurredAt <= shape.occurredAt, other.occurredAt >= window(before: shape.occurredAt)
        else { continue }
        var candidate = Self.original(row: rows[j], shape: other, currency: currency, remaining: other.amountMinor)
        candidate.score = 40 + 10 + 30 + 3
        candidate.isSameAmount = true
        if best == nil || candidate.score > best!.score
          || (candidate.score == best!.score && candidate.occurredAt > best!.occurredAt)
        {
          best = candidate
        }
      }
    }
    guard let best, best.isSameAmount, best.score >= ImportPreview.refundSuggestionScore else { return nil }
    return best
  }

  private func window(before date: Date) -> Date {
    preview.calendar.date(byAdding: .day, value: -Self.windowDays, to: date) ?? date
  }

  /// The expenses of this file row `i` may return, best first (C30's ranking and window).
  func options(forRow i: Int, matching search: String, used: [ImportRefundOriginal.Ref: Int64]) -> [ImportRefundOriginal] {
    guard eligible(i), case .create(let shape) = plans[i], let currency = currency(i) else { return [] }
    let needle = Self.fold(search)
    let refundPayee = Self.fold(shape.payee)
    var result: [(ImportRefundOriginal, Int)] = []
    for (j, plan) in plans.enumerated() where j != i {
      guard case .create(let other) = plan, Self.isOriginal(other, rows[j]), other.from == shape.from,
        self.currency(j) == currency
      else { continue }
      if needle.isEmpty {
        guard other.occurredAt <= shape.occurredAt, other.occurredAt >= window(before: shape.occurredAt) else { continue }
      } else if !Self.fold(other.payee).contains(needle), !Self.fold(other.note).contains(needle) {
        continue
      }
      let remaining = other.amountMinor - used[.row(rows[j].id), default: 0]
      guard remaining >= shape.amountMinor else { continue }
      var score = 10 + 3
      let payee = Self.fold(other.payee)
      if !payee.isEmpty, !refundPayee.isEmpty {
        if payee == refundPayee {
          score += 40
        } else if payee.contains(refundPayee) || refundPayee.contains(payee) {
          score += 20
        }
      }
      let same = remaining == shape.amountMinor
      score += same ? 30 : 5
      var candidate = Self.original(row: rows[j], shape: other, currency: currency, remaining: remaining)
      candidate.score = score
      candidate.isSameAmount = same
      result.append((candidate, j))
    }
    return result.sorted { ($0.0.score, $0.0.occurredAt, -$0.1) > ($1.0.score, $1.0.occurredAt, -$1.1) }.map(\.0)
  }
}

extension RowPlan {
  fileprivate var shapeAccount: AccountRef? {
    if case .create(let shape) = self { return shape.from }
    return nil
  }
}
