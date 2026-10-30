import AbacusDomain
import Foundation
import Observation

/// "Refund text" of a failed link, in the words the sheets and the editor show.
public enum RefundMessages {
  public static func text(for error: Error, format: TransactionMoneyFormat = TransactionMoneyFormat()) -> String {
    switch error as? RefundError {
    case .exceedsOriginal(let remaining, let currency)?:
      return "The refunds of this expense would be more than it cost. Up to "
        + format.string(minor: remaining, code: currency.rawValue) + " can still be refunded."
    case .rateUnavailable?:
      return "No exchange rate is known for the refund's date, so it can't be compared with the expense."
    case .invalidOriginal?:
      return "That transaction can't be refunded: it must be an expense that is not itself a refund."
    case .notRefundable?:
      return "This transaction can't be a refund."
    case .notFound?:
      return "The transaction no longer exists."
    case nil:
      return "Couldn't link the refund."
    }
  }
}

/// The search sheet behind "This is a refund of…" (pick the expense a refund returns), "Link a
/// refund…" (pick the incoming transaction that returned an expense) and the editor's "Refund of"
/// field: a search field and ranked suggestions (R-TX-4, C30).
@MainActor
@Observable
public final class RefundPickerModel {
  public enum Kind: Hashable, Sendable {
    /// The subject is a refund; the options are expenses.
    case chooseOriginal
    /// The subject is an expense; the options are incoming transactions.
    case chooseRefund
  }

  /// One suggestion.
  public struct Option: Identifiable, Hashable, Sendable {
    public var id: Txn.ID
    /// Description (payee), else "No description".
    public var title: String
    /// "12 Oct 2026 · Account · note".
    public var subtitle: String
    /// The transaction's amount in its account currency.
    public var amountText: String
    /// "Same amount" when it matches what is open, "N already refunded" for a partly refunded expense.
    public var detail: String?
    public var isSameAmount: Bool
    public var categoryID: AbacusDomain.Category.ID?
    public var occurredAt: Date

    public init(
      id: Txn.ID, title: String, subtitle: String, amountText: String, detail: String?, isSameAmount: Bool,
      categoryID: AbacusDomain.Category.ID?, occurredAt: Date
    ) {
      self.id = id
      self.title = title
      self.subtitle = subtitle
      self.amountText = amountText
      self.detail = detail
      self.isSameAmount = isSameAmount
      self.categoryID = categoryID
      self.occurredAt = occurredAt
    }
  }

  public let kind: Kind
  public let title: String
  public let subtitle: String
  /// The transaction the options are for; nil for a refund the editor has not saved yet.
  public let subjectID: Txn.ID?
  public var search = ""
  public private(set) var options: [Option] = []
  public private(set) var isLoading = false
  public var errorMessage: String?

  @ObservationIgnored private let repository: any RefundRepository
  @ObservationIgnored private let probe: RefundProbe?
  @ObservationIgnored private let accountNames: [Account.ID: String]
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let format = TransactionMoneyFormat()
  @ObservationIgnored private let limit: Int
  @ObservationIgnored private var generation = 0

  /// - Parameters:
  ///   - probe: for `.chooseOriginal`, the refund's facts (it may not be saved yet).
  public init(
    kind: Kind, subjectID: Txn.ID?, probe: RefundProbe? = nil, title: String, subtitle: String,
    repository: any RefundRepository, accountNames: [Account.ID: String], calendar: Calendar = .current,
    limit: Int = 30
  ) {
    self.kind = kind
    self.subjectID = subjectID
    self.probe = probe
    self.title = title
    self.subtitle = subtitle
    self.repository = repository
    self.accountNames = accountNames
    self.calendar = calendar
    self.limit = limit
  }

  /// Loads the suggestions for the current search text. A newer call supersedes an older one.
  public func load() async {
    generation += 1
    let current = generation
    isLoading = true
    let text = search
    let built: [Option]
    do {
      switch kind {
      case .chooseOriginal:
        guard let probe else { throw RefundError.notFound }
        let candidates = try await repository.refundCandidates(probe: probe, matching: text, limit: limit)
        built = candidates.map(option)
      case .chooseRefund:
        guard let subjectID else { throw RefundError.notFound }
        let targets = try await repository.refundTargets(for: subjectID, matching: text, limit: limit)
        built = targets.map(option)
      }
    } catch {
      guard current == generation else { return }
      options = []
      isLoading = false
      errorMessage = "Couldn't load suggestions."
      return
    }
    guard current == generation else { return }
    options = built
    isLoading = false
    if errorMessage == "Couldn't load suggestions." { errorMessage = nil }
  }

  private func subtitle(of txn: Txn) -> String {
    var parts = [dayText(txn.occurredAt, withYear: true)]
    if let name = accountNames[txn.accountID] { parts.append(name) }
    let note = txn.note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty { parts.append(note) }
    return parts.joined(separator: " · ")
  }

  private func dayText(_ date: Date, withYear: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = format.locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = withYear ? "d MMM yyyy" : "d MMM"
    return formatter.string(from: date)
  }

  private func option(_ candidate: RefundCandidate) -> Option {
    let txn = candidate.txn
    let code = candidate.currency.rawValue
    let sameAmount = candidate.isSameAmount
    var detail: String?
    if sameAmount {
      detail = "Same amount"
    } else if candidate.refundedMinor > 0 {
      detail = format.string(minor: candidate.refundedMinor, code: code) + " already refunded"
    }
    return Option(
      id: txn.id, title: txn.payee.isEmpty ? "No description" : txn.payee, subtitle: subtitle(of: txn),
      amountText: format.string(minor: txn.amountMinor, code: code), detail: detail, isSameAmount: sameAmount,
      categoryID: txn.categoryID, occurredAt: txn.occurredAt)
  }

  private func option(_ target: RefundTargetCandidate) -> Option {
    let txn = target.txn
    let code = target.currency.rawValue
    let same = txn.amountMinor == target.remainingMinor
    return Option(
      id: txn.id, title: txn.payee.isEmpty ? "No description" : txn.payee, subtitle: subtitle(of: txn),
      amountText: format.string(minor: txn.amountMinor, code: code), detail: same ? "Same amount" : nil,
      isSameAmount: same, categoryID: txn.categoryID, occurredAt: txn.occurredAt)
  }
}
