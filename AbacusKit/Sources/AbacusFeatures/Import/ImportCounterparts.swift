import AbacusDomain
import AbacusImport
import Foundation
import Observation

// C38: the other side of a transfer to an own account in another currency, in the import wizard.
//
// "Transfer to my account" for a row whose amount on the other account the file does not give opens
// the "Find the other side…" sheet: transactions of that account around the row's date (ranked by how
// close they are to the row's amount at the known rate), an amount typed by hand, or an estimate at
// the day's rate. The rules live in `ImportPreview` / `ImportPipeline` (AbacusImport); this file is
// the sheet's model, the display values and the wizard's actions. A later import row that looks like
// the other side of an estimated transfer is offered with Accept / Not this (`ImportEstimateItem`).

/// What a row shows about the other side of its transfer.
public struct ImportCounterpartItem: Hashable, Sendable {
  /// "Other side: Salary · 11.03.2026 · zł 398.00 (replaces that transaction)", "Amount typed by
  /// you: zł 397.00", "Estimated amount: zł 400.00 at 4.0000 — flagged until the other statement is
  /// imported".
  public var text: String
  /// The other account the "Change…" link reopens the sheet for.
  public var accountID: Account.ID
}

/// A row's offer to be the real figure of an estimated transfer of an earlier import.
public struct ImportEstimateItem: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// "Looks like the other side of the transfer on …": Accept / Not this.
    case offered
    /// Accepted: the row completes that transfer (Undo).
    case accepted
    /// "Not this" was chosen (Undo).
    case declined
  }

  public var state: State
  public var text: String
}

/// The sheet of a row ("Find the other side…").
public struct ImportCounterpartPicker: Identifiable {
  public let rowID: String
  public let accountID: Account.ID
  public let model: TransferCounterpartModel
  public var id: String { rowID }
}

/// The model of the "Find the other side…" sheet: ranked candidates with a search field, a typed
/// amount and the estimate at the day's rate.
@MainActor
@Observable
public final class TransferCounterpartModel {
  /// One candidate transaction.
  public struct Option: Identifiable, Hashable, Sendable {
    public var id: Txn.ID
    /// Description, else "No description".
    public var title: String
    /// "11 Mar 2026 · 1 day away · Income" and the reason when it cannot be used.
    public var subtitle: String
    /// The candidate's amount on its own account.
    public var amountText: String
    /// "Rate 3.9750 · 0.6 % from the expected amount".
    public var detail: String
    /// Why it cannot be used ("It has attached records (…)"); nil = it can.
    public var refusal: String?
    public var isUsable: Bool { refusal == nil }
    let found: ImportCounterpartOption
  }

  /// The estimate at the day's rate, when a rate is known.
  public struct Estimate: Hashable, Sendable {
    public var amountMinor: Int64
    public var rate: Decimal
    public var amountText: String
    public var rateText: String
  }

  public let title: String
  public let subtitle: String
  /// "PLN": the currency a typed amount is in.
  public let currencyCode: String
  public let estimate: Estimate?
  public var search = ""
  /// The amount typed for "Use this amount" (the other account's currency, positive).
  public var manualText = ""
  public private(set) var options: [Option] = []
  public private(set) var isLoading = false
  public var errorMessage: String?

  @ObservationIgnored private let source: @Sendable (String) async throws -> [ImportCounterpartOption]
  @ObservationIgnored private let accountNames: [Account.ID: String]
  @ObservationIgnored private let format: ImportFormat
  @ObservationIgnored private var generation = 0

  init(
    title: String, subtitle: String, currencyCode: String, estimate: Estimate?, accountNames: [Account.ID: String],
    format: ImportFormat, source: @escaping @Sendable (String) async throws -> [ImportCounterpartOption]
  ) {
    self.title = title
    self.subtitle = subtitle
    self.currencyCode = currencyCode
    self.estimate = estimate
    self.accountNames = accountNames
    self.format = format
    self.source = source
  }

  /// The typed amount in minor units; nil when empty, not a number, zero or negative.
  public var manualAmountMinor: Int64? {
    let text = manualText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
      .replacingOccurrences(of: " ", with: "")
    guard !text.isEmpty, let value = Decimal(string: text), value > 0 else { return nil }
    let minor = Money.minorUnits(from: value)
    return minor > 0 ? minor : nil
  }

  /// Loads the candidates for the current search text. A newer call supersedes an older one.
  public func load() async {
    generation += 1
    let current = generation
    isLoading = true
    let text = search
    let found: [ImportCounterpartOption]
    do {
      found = try await source(text)
    } catch {
      guard current == generation else { return }
      options = []
      isLoading = false
      errorMessage = "Couldn't load transactions."
      return
    }
    guard current == generation else { return }
    options = found.map(option)
    isLoading = false
    if errorMessage == "Couldn't load transactions." { errorMessage = nil }
  }

  private func option(_ found: ImportCounterpartOption) -> Option {
    let txn = found.candidate.txn
    let code = found.candidate.currency.rawValue
    var parts = [format.longDay(Day(txn.occurredAt, calendar: format.calendar))]
    parts.append(found.dayGap == 0 ? "same day" : found.dayGap == 1 ? "1 day away" : "\(found.dayGap) days away")
    switch txn.type {
    case .income: parts.append("Income")
    case .expense: parts.append("Expense")
    case .transfer: parts.append("Transfer")
    }
    if let refusal = found.candidate.refusal { parts.append(refusal.message) }
    var detail = "Rate " + Self.rateText(found.impliedRate)
    if let deviation = found.deviation {
      detail += deviation < 0.0005 ? " · as expected" : " · " + String(format: "%.1f", deviation * 100) + " % from the expected amount"
    }
    return Option(
      id: txn.id, title: txn.payee.isEmpty ? "No description" : txn.payee, subtitle: parts.joined(separator: " · "),
      amountText: format.money.string(minor: found.amountMinor, code: code), detail: detail,
      refusal: found.candidate.refusal?.message, found: found)
  }

  static func rateText(_ rate: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 4
    return formatter.string(from: rate as NSDecimalNumber) ?? "\(rate)"
  }
}

extension ImportWizardModel {
  // MARK: Display

  func counterpartItem(_ row: PreviewRow) -> ImportCounterpartItem? {
    guard let counterpart = row.counterpart else { return nil }
    let code = accounts.first { $0.id == counterpart.accountID }?.currency.rawValue ?? row.source.account.currency.rawValue
    let amount = format.money.string(minor: counterpart.amountMinor, code: code)
    let text: String
    switch counterpart.kind {
    case .existing(let txn):
      let payee = txn.payee.isEmpty ? "a transaction" : txn.payee
      text = "Other side: \(payee) · \(format.day(txn.occurredAt)) · \(amount)" + (row.absorbedTxn != nil ? " (it becomes this transfer)" : "")
    case .manual:
      text = "Other side typed by you: \(amount)"
    case .estimated(let rate):
      text = "Estimated other side: \(amount) at \(TransferCounterpartModel.rateText(rate)) (marked until the other statement is imported)"
    }
    return ImportCounterpartItem(text: text, accountID: counterpart.accountID)
  }

  func estimateItem(_ row: PreviewRow) -> ImportEstimateItem? {
    guard row.canMatchEstimate || row.estimateLink != nil else { return nil }
    if let linked = row.estimateLink {
      return ImportEstimateItem(
        state: .accepted,
        text: "Completes the transfer of \(format.day(linked.txn.occurredAt)): \(describe(linked)) becomes "
          + format.money.string(minor: row.amountMinor, code: linked.currency.rawValue))
    }
    if row.estimateDeclined { return ImportEstimateItem(state: .declined, text: "Not the other side of that transfer") }
    if let offer = row.estimateOffer {
      return ImportEstimateItem(
        state: .offered, text: "Looks like the other side of the transfer on \(format.day(offer.txn.occurredAt)) · \(describe(offer))")
    }
    return nil
  }

  /// "zł 400.00 (estimated)".
  private func describe(_ offer: ImportEstimatedTransfer) -> String {
    format.money.string(minor: offer.estimatedMinor, code: offer.currency.rawValue) + " (estimated)"
  }

  // MARK: Estimated transfers of an earlier import

  /// "Accept": the row is the real figure of the offered transfer.
  public func acceptEstimateOffer(forRow id: String) {
    var accepted = false
    update { accepted = $0.acceptEstimate(forRow: id) }
    if !accepted { errorMessage = "That transfer doesn't fit this row any more." }
  }

  /// "Not this": an ordinary row; the offer does not come back.
  public func declineEstimate(forRow id: String) {
    update { $0.declineEstimate(forRow: id) }
  }

  /// Undo of "Not this" or of an accepted match: the offer comes back.
  public func resetEstimate(forRow id: String) {
    update { $0.resetEstimate(forRow: id) }
  }

  // MARK: The other side of a transfer

  /// Whether a transfer to `accountID` needs the other side from the user for this row.
  public func needsCounterpart(forRow id: String, to accountID: Account.ID) -> Bool {
    preview?.needsCounterpart(row: id, to: accountID) ?? false
  }

  /// Opens "Find the other side…" for the row's transfer to `accountID`.
  public func beginCounterpart(forRow id: String, to accountID: Account.ID) {
    guard let preview, let row = preview.row(id), let probe = preview.counterpartProbe(forRow: id, to: accountID) else { return }
    let pipeline = self.pipeline
    let targetName = accounts.first { $0.id == accountID }?.name ?? "the other account"
    let own = preview.name(of: row.account)
    let amount = format.money.string(minor: row.amountMinor, code: probe.rowCurrency.rawValue)
    let subtitle = [
      row.source.payee.isEmpty ? (row.isInflow ? "Incoming payment" : "Outgoing payment") : row.source.payee,
      "\(row.isInflow ? "+" : "−")\(amount) on \(own)", format.day(row.day),
    ].joined(separator: " · ")
    var estimate: TransferCounterpartModel.Estimate?
    if let found = preview.estimatedCounterpart(forRow: id, to: accountID) {
      estimate = TransferCounterpartModel.Estimate(
        amountMinor: found.amountMinor, rate: found.rate,
        amountText: format.money.string(minor: found.amountMinor, code: probe.targetCurrency.rawValue),
        rateText: "1 \(probe.rowCurrency.rawValue) = \(TransferCounterpartModel.rateText(found.rate)) \(probe.targetCurrency.rawValue)")
    }
    let model = TransferCounterpartModel(
      title: row.isInflow ? "Find the other side of the transfer from “\(targetName)”" : "Find the other side of the transfer to “\(targetName)”",
      subtitle: subtitle, currencyCode: probe.targetCurrency.rawValue, estimate: estimate,
      accountNames: Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }), format: format,
      source: { search in try await pipeline.counterpartOptions(for: preview, row: id, to: accountID, matching: search) })
    counterpartPicker = ImportCounterpartPicker(rowID: id, accountID: accountID, model: model)
  }

  public func cancelCounterpart() {
    counterpartPicker = nil
  }

  /// A pick in the sheet: the row's transfer takes over that transaction as its other side.
  public func chooseCounterpart(_ option: TransferCounterpartModel.Option) {
    guard let picker = counterpartPicker else { return }
    if let refusal = option.refusal {
      picker.model.errorMessage = refusal
      return
    }
    apply(
      TransferCounterpart(
        accountID: picker.accountID, kind: .existing(option.found.candidate.txn), amountMinor: option.found.amountMinor),
      picker: picker)
  }

  /// "Use this amount": the typed amount is what arrived on (left) the other account.
  public func useManualCounterpart() {
    guard let picker = counterpartPicker else { return }
    guard let amount = picker.model.manualAmountMinor else {
      picker.model.errorMessage = "Type the amount in \(picker.model.currencyCode), for example 398.00."
      return
    }
    apply(TransferCounterpart(accountID: picker.accountID, kind: .manual, amountMinor: amount), picker: picker)
  }

  /// "Estimate at the NBU rate": the amount at the day's rate; the transfer is marked as estimated.
  public func useEstimatedCounterpart() {
    guard let picker = counterpartPicker, let estimate = picker.model.estimate else { return }
    apply(
      TransferCounterpart(accountID: picker.accountID, kind: .estimated(rate: estimate.rate), amountMinor: estimate.amountMinor),
      picker: picker)
  }

  private func apply(_ counterpart: TransferCounterpart, picker: ImportCounterpartPicker) {
    var done = false
    update { done = $0.setTransfer(toAccount: picker.accountID, counterpart: counterpart, forRow: picker.rowID) }
    if done {
      counterpartPicker = nil
    } else {
      picker.model.errorMessage = "That can't be the other side of this row's transfer."
    }
  }
}
