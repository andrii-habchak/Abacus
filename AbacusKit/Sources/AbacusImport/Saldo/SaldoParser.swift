import AbacusDomain
import Foundation

/// Parses a Saldo CSV export into normalised rows (R-IMP-SALDO-1…4, format in
/// docs/import/saldo-format.md).
///
/// - Legs are grouped by `Transaction ID` and mapped by their leg pattern: expense, split
///   expense, refund, income, income reversal, transfer (+ fee), opening balance, transfer half.
/// - Account identity is (`Account`, `Currency`); amounts are in the account currency, a
///   category leg in another currency becomes the original amount (R-CUR-4).
/// - MONEY_ON_THE_WAY halves are paired into transfers (`TransferPairing`); unpaired halves come
///   out as `.transferHalf` rows for *needs review*.
/// - Transactions with an unsupported leg pattern are skipped with a file warning and counted in
///   `skippedRowCount` (one per Saldo transaction, not per CSV line).
public struct SaldoParser: ImportParser {
  public static let source: ImportSource = .saldo

  /// Saldo writes local times without a zone; they are read in this zone.
  public var timeZone: TimeZone
  /// Maximum distance between two transfer halves (R-IMP-SALDO-2: 3 days).
  public var pairingWindow: TimeInterval

  public init(timeZone: TimeZone = .current, pairingWindow: TimeInterval = 3 * 24 * 60 * 60) {
    self.timeZone = timeZone
    self.pairingWindow = pairingWindow
  }

  /// True when the first line is a Saldo header (R-IMP-1).
  public static func canParse(_ data: Data) -> Bool {
    let bytes = CSVReader.strippingBOM([UInt8](data.prefix(8192)))
    let firstLine = bytes.prefix { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\r") }
    guard let record = try? CSVReader.records(firstLine).first else { return false }
    let names = Set(record.fields.map { $0.trimmingCharacters(in: .whitespaces) })
    return SaldoHeader.signature.allSatisfy(names.contains)
      && SaldoHeader.required.allSatisfy(names.contains)
  }

  public func parse(_ data: Data) throws -> ParsedImport {
    let bytes = CSVReader.strippingBOM([UInt8](data))
    guard String(validating: bytes, as: UTF8.self) != nil else { throw ImportError.unreadableEncoding }
    let records = try CSVReader.records(bytes)
    guard let first = records.first, let header = SaldoHeader(first.fields) else {
      throw ImportError.unrecognisedFormat
    }
    let legs = try records.dropFirst().map { try header.leg(from: $0, timeZone: timeZone) }
    var mapping = SaldoMapping(legs: legs, pairingWindow: pairingWindow)
    return mapping.run()
  }
}

/// Row-level warning texts shown in the import preview.
enum SaldoWarning {
  static let unbalanced =
    "Unbalanced legs in Saldo: the account amount is kept, category amounts were adjusted."
  static let unbalancedTransfer =
    "Unbalanced transfer in Saldo: amounts sent and received differ in the same currency."
  static let estimatedSplit =
    "Split across several foreign currencies: the account amount was divided equally; check it."
  static let feeInOtherCurrency =
    "A fee is in a currency of neither account: its charged amount is 0; enter it by hand."
  static let sameAccount = "Transfer from an account to itself."
  static let refundLine =
    "Contains an expense refund, imported as an attached income record in the expense category."
  static let splitRefund =
    "Refund split over several categories in Saldo: imported in full under the first category."
  static let severalTags = "Several Saldo tags on one transaction: only the first is used."
}

private struct SaldoGroup {
  var index: Int
  var id: String
  var legs: [SaldoLeg]

  var fingerprint: String { Fingerprint.saldo(transactionID: id) }
  var date: Date { legs[0].date }
  var payee: String { legs[0].description }
  var note: String { unique(legs.map(\.note)).joined(separator: "\n") }
  var tags: [String] { unique(legs.map(\.tag)) }
  var shape: String {
    legs.map { "\($0.side.rawValue) \($0.rawType)" }.sorted().joined(separator: ", ")
  }

  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
  }
}

/// A transfer half waiting for pairing.
private struct HalfDraft {
  var group: SaldoGroup
  var direction: TransferHalf.Direction
  var account: ExternalAccount
  var accountKey: String
  /// Asset leg minus fees (outgoing) or the asset leg (incoming), in the account currency.
  var amountMinor: Int64
  var transit: OriginalAmount
  var hint: String?
  var lines: [NormalizedLine]
  var warnings: [String]
}

private enum Outcome {
  case row(NormalizedRow)
  case half(HalfDraft)
  case skipped(ImportWarning)
}

struct SaldoMapping {
  private var groups: [SaldoGroup] = []
  private var accounts: [String: ExternalAccount] = [:]
  private var fileWarnings: [ImportWarning] = []
  private let pairingWindow: TimeInterval

  init(legs: [SaldoLeg], pairingWindow: TimeInterval) {
    self.pairingWindow = pairingWindow
    var order: [String: Int] = [:]
    for leg in legs {
      if let i = order[leg.transactionID] {
        groups[i].legs.append(leg)
      } else {
        order[leg.transactionID] = groups.count
        groups.append(SaldoGroup(index: groups.count, id: leg.transactionID, legs: [leg]))
      }
    }
    registerAccounts(legs)
  }

  /// R-ACC-2, R-ACC-4: one external account per (name, currency); archived if any leg says so.
  private mutating func registerAccounts(_ legs: [SaldoLeg]) {
    var warnedKeys = Set<String>()
    for leg in legs {
      guard let type = leg.type, let kind = type.accountKind,
        let currency = Currency(rawValue: leg.currencyCode)
      else { continue }
      if var existing = accounts[leg.accountKey] {
        if leg.isArchived, !existing.isArchived {
          existing.isArchived = true
          accounts[leg.accountKey] = existing
        }
        if existing.kind != kind, warnedKeys.insert(leg.accountKey).inserted {
          fileWarnings.append(
            ImportWarning(
              line: leg.line,
              message: "Account \"\(leg.account)\" (\(leg.currencyCode)) has several Saldo account types; the first is used."
            ))
        }
      } else {
        accounts[leg.accountKey] = ExternalAccount(
          name: leg.account, currency: currency, kind: kind, isArchived: leg.isArchived)
      }
    }
  }

  mutating func run() -> ParsedImport {
    var placed: [(index: Int, row: NormalizedRow)] = []
    var outgoing: [HalfDraft] = []
    var incoming: [HalfDraft] = []
    var skipped = 0

    for group in groups {
      switch classify(group) {
      case .row(let row): placed.append((group.index, row))
      case .half(let half): half.direction == .outgoing ? outgoing.append(half) : incoming.append(half)
      case .skipped(let warning):
        fileWarnings.append(warning)
        skipped += 1
      }
    }

    let pairs = TransferPairing.pair(
      outgoing: outgoing.map { PairingHalf(date: $0.group.date, accountKey: $0.accountKey, transit: $0.transit) },
      incoming: incoming.map { PairingHalf(date: $0.group.date, accountKey: $0.accountKey, transit: $0.transit) },
      window: pairingWindow)
    var pairedOut = Set<Int>()
    var pairedIn = Set<Int>()
    for pair in pairs {
      pairedOut.insert(pair.outgoing)
      pairedIn.insert(pair.incoming)
      let out = outgoing[pair.outgoing]
      placed.append((out.group.index, transfer(out, incoming[pair.incoming])))
    }
    for (i, half) in outgoing.enumerated() where !pairedOut.contains(i) {
      placed.append((half.group.index, unpaired(half)))
    }
    for (i, half) in incoming.enumerated() where !pairedIn.contains(i) {
      placed.append((half.group.index, unpaired(half)))
    }

    let rows = placed.sorted { $0.index < $1.index }.map(\.row)
    return ParsedImport(source: .saldo, rows: rows, warnings: fileWarnings, skippedRowCount: skipped)
  }

  // MARK: - Leg patterns

  private func classify(_ group: SaldoGroup) -> Outcome {
    let legs = group.legs
    if let unknown = legs.first(where: { $0.type == nil }) {
      return skip(group, "unknown account type \(unknown.rawType)")
    }
    let assets = legs.filter { $0.type!.isAccount }
    if assets.contains(where: { Currency(rawValue: $0.currencyCode) == nil }) {
      return skip(group, "an account leg is in a currency Abacus accounts do not support")
    }
    let transit = legs.filter { $0.type == .moneyOnTheWay }
    let equity = legs.filter { $0.type == .equity }
    let categories = legs.filter { $0.type == .expenses || $0.type == .income }

    if !equity.isEmpty {
      guard assets.count == 1, equity.count == 1, transit.isEmpty, categories.isEmpty,
        equity[0].side != assets[0].side
      else { return skip(group, "unsupported legs (\(group.shape))") }
      return .row(openingBalance(group, assets[0]))
    }

    if !transit.isEmpty {
      guard assets.count == 1, transit.count == 1, transit[0].side != assets[0].side else {
        return skip(group, "unsupported legs (\(group.shape))")
      }
      let isOutgoing = assets[0].side == .credit
      // Fees only on the sending side: an attached record hits the source account (R-TX-6).
      let feesOK = isOutgoing
        ? categories.allSatisfy { $0.type == .expenses && $0.side == .debit }
        : categories.isEmpty
      guard feesOK else { return skip(group, "unsupported legs (\(group.shape))") }
      return .half(half(group, asset: assets[0], transit: transit[0], fees: categories))
    }

    if assets.count == 2 {
      guard assets[0].side != assets[1].side, categories.allSatisfy({ $0.type == .expenses }) else {
        return skip(group, "unsupported legs (\(group.shape))")
      }
      let from = assets[0].side == .credit ? assets[0] : assets[1]
      let to = assets[0].side == .credit ? assets[1] : assets[0]
      return .row(transfer(group, from: from, to: to, lineLegs: categories))
    }

    if assets.count == 1, !categories.isEmpty {
      let asset = assets[0]
      let types = Set(categories.map(\.type))
      guard types.count == 1, categories.allSatisfy({ $0.side != asset.side }) else {
        return skip(group, "unsupported legs (\(group.shape))")
      }
      let isExpense = types.first == .expenses
      // Money out of the account is an expense or an income reversal; money in is income or a
      // refund (R-TX-4).
      let isRefund = (asset.side == .debit) == isExpense
      return .row(categoryRow(group, asset: asset, legs: categories, kind: isExpense ? .expense : .income, isRefund: isRefund))
    }

    return skip(group, "unsupported legs (\(group.shape))")
  }

  private func skip(_ group: SaldoGroup, _ reason: String) -> Outcome {
    .skipped(ImportWarning(line: group.legs[0].line, message: "Saldo transaction \(group.id) skipped: \(reason)."))
  }

  // MARK: - Row builders

  /// R-IMP-SALDO-3: signed in the account's direction (debit = +).
  private func openingBalance(_ group: SaldoGroup, _ asset: SaldoLeg) -> NormalizedRow {
    var warnings: [String] = []
    let amount = asset.side == .debit ? asset.minorUnits : -asset.minorUnits
    return NormalizedRow(
      fingerprints: [group.fingerprint], kind: .openingBalance, occurredAt: group.date,
      account: accounts[asset.accountKey]!, amountMinor: amount, payee: group.payee,
      note: group.note, tag: tag(group, &warnings), warnings: warnings)
  }

  /// Expense, income, refund and income reversal; several category legs = split (R-TX-6).
  private func categoryRow(
    _ group: SaldoGroup, asset: SaldoLeg, legs: [SaldoLeg], kind: NormalizedRow.Kind, isRefund: Bool
  ) -> NormalizedRow {
    var warnings: [String] = []
    let currency = asset.currencyCode
    var amounts = allocate(asset.minorUnits, currency: currency, legs: legs, warnings: &warnings)
    var lineLegs = Array(legs.dropFirst())
    if isRefund, !lineLegs.isEmpty {
      // Attached records have no refund flag yet: keep the balance right, lose the split.
      warnings.append(SaldoWarning.splitRefund)
      amounts = [asset.minorUnits]
      lineLegs = []
    }
    let main = legs[0]
    let lines = lineLegs.enumerated().map { offset, leg in
      NormalizedLine(
        kind: categoryKind(leg), category: category(leg), amountMinor: amounts[offset + 1],
        original: original(leg, accountCurrency: currency))
    }
    return NormalizedRow(
      fingerprints: [group.fingerprint], kind: kind, occurredAt: group.date,
      account: accounts[asset.accountKey]!, amountMinor: amounts[0], category: category(main),
      isRefund: isRefund, original: original(main, accountCurrency: currency),
      lines: lines, payee: group.payee, note: group.note, tag: tag(group, &warnings),
      warnings: warnings)
  }

  /// Splits the account amount over category legs (R-CUR-4): legs in the account currency keep
  /// their amount, the rest is shared pro rata among legs in the foreign currency.
  private func allocate(_ total: Int64, currency: String, legs: [SaldoLeg], warnings: inout [String]) -> [Int64] {
    let minors = legs.map(\.minorUnits)
    let exact = legs.indices.filter { legs[$0].currencyCode == currency }
    let foreign = legs.indices.filter { legs[$0].currencyCode != currency }
    if foreign.isEmpty {
      if minors.reduce(0, +) == total { return minors }
      warnings.append(SaldoWarning.unbalanced)
      return ProRata.split(total, weights: minors)
    }
    var result = Array(repeating: Int64(0), count: legs.count)
    let exactSum = exact.map { minors[$0] }.reduce(0, +)
    let remainder = total - exactSum
    if remainder < 0 {
      warnings.append(SaldoWarning.unbalanced)
      for (i, share) in zip(exact, ProRata.split(total, weights: exact.map { minors[$0] })) { result[i] = share }
      return result
    }
    for i in exact { result[i] = minors[i] }
    let foreignCurrencies = Set(foreign.map { legs[$0].currencyCode })
    let weights: [Int64]
    if foreignCurrencies.count == 1 {
      weights = foreign.map { minors[$0] }
    } else {
      warnings.append(SaldoWarning.estimatedSplit)
      weights = foreign.map { _ in 1 }
    }
    for (i, share) in zip(foreign, ProRata.split(remainder, weights: weights)) { result[i] = share }
    return result
  }

  /// Account-to-account transfer; expense legs become attached records on the source account:
  /// a DEBIT is a fee, a CREDIT a refund (R-TX-5, R-TX-6).
  private func transfer(_ group: SaldoGroup, from: SaldoLeg, to: SaldoLeg, lineLegs: [SaldoLeg]) -> NormalizedRow {
    var warnings: [String] = []
    let sent = from.minorUnits
    let received = to.minorUnits
    let fromCurrency = from.currencyCode
    let toCurrency = to.currencyCode
    let signs = lineLegs.map { $0.side == .debit ? Int64(1) : -1 }
    var lineAmounts = Array(repeating: Int64(0), count: lineLegs.count)

    let exact = lineLegs.indices.filter { lineLegs[$0].currencyCode == fromCurrency }
    for i in exact { lineAmounts[i] = lineLegs[i].minorUnits }
    let netExact = exact.map { signs[$0] * lineAmounts[$0] }.reduce(0, +)
    let foreign = lineLegs.indices.filter { lineLegs[$0].currencyCode != fromCurrency }

    if fromCurrency == toCurrency {
      // One amount; the difference between the asset legs is what the records cost.
      let residual = sent - received - netExact
      if foreign.isEmpty {
        if residual != 0 { warnings.append(SaldoWarning.unbalanced) }
      } else if foreign.allSatisfy({ signs[$0] == 1 }), residual > 0 {
        let currencies = Set(foreign.map { lineLegs[$0].currencyCode })
        if currencies.count > 1 { warnings.append(SaldoWarning.estimatedSplit) }
        let weights = currencies.count == 1 ? foreign.map { lineLegs[$0].minorUnits } : foreign.map { _ in 1 }
        for (i, share) in zip(foreign, ProRata.split(residual, weights: weights)) { lineAmounts[i] = share }
      } else {
        warnings.append(SaldoWarning.unbalanced)
      }
    } else {
      let inTarget = foreign.filter { lineLegs[$0].currencyCode == toCurrency }
      let elsewhere = foreign.filter { lineLegs[$0].currencyCode != toCurrency }
      if !inTarget.isEmpty {
        if inTarget.allSatisfy({ signs[$0] == 1 }) {
          // What left the source pays for the received amount plus these fees, pro rata.
          let shares = ProRata.split(sent - netExact, weights: [received] + inTarget.map { lineLegs[$0].minorUnits })
          for (i, share) in zip(inTarget, shares.dropFirst()) { lineAmounts[i] = share }
        } else {
          warnings.append(SaldoWarning.feeInOtherCurrency)
        }
      }
      if !elsewhere.isEmpty { warnings.append(SaldoWarning.feeInOtherCurrency) }
    }

    let amount = sent - zip(signs, lineAmounts).map { $0 * $1 }.reduce(0, +)
    if from.accountKey == to.accountKey { warnings.append(SaldoWarning.sameAccount) }
    if fromCurrency == toCurrency, amount != received, !warnings.contains(SaldoWarning.unbalanced) {
      warnings.append(SaldoWarning.unbalancedTransfer)
    }
    if signs.contains(-1) { warnings.append(SaldoWarning.refundLine) }

    let lines = lineLegs.indices.map { i in
      NormalizedLine(
        kind: signs[i] == 1 ? .expense : .income, category: category(lineLegs[i]),
        amountMinor: lineAmounts[i], original: original(lineLegs[i], accountCurrency: fromCurrency),
        note: signs[i] == 1 ? "" : "Refund")
    }
    return NormalizedRow(
      fingerprints: [group.fingerprint], kind: .transfer, occurredAt: group.date,
      account: accounts[from.accountKey]!, amountMinor: amount,
      counterAccount: accounts[to.accountKey]!, counterAmountMinor: received, lines: lines,
      payee: group.payee, note: group.note, tag: tag(group, &warnings), warnings: warnings)
  }

  /// One side of a MONEY_ON_THE_WAY transfer (R-IMP-SALDO-2).
  private func half(_ group: SaldoGroup, asset: SaldoLeg, transit: SaldoLeg, fees: [SaldoLeg]) -> HalfDraft {
    var warnings: [String] = []
    let currency = asset.currencyCode
    var feeAmounts = Array(repeating: Int64(0), count: fees.count)
    let exact = fees.indices.filter { fees[$0].currencyCode == currency }
    for i in exact { feeAmounts[i] = fees[i].minorUnits }
    let inTransit = fees.indices.filter { fees[$0].currencyCode != currency && fees[$0].currencyCode == transit.currencyCode }
    let elsewhere = fees.indices.filter { fees[$0].currencyCode != currency && fees[$0].currencyCode != transit.currencyCode }
    if !inTransit.isEmpty {
      let exactSum = exact.map { feeAmounts[$0] }.reduce(0, +)
      let shares = ProRata.split(asset.minorUnits - exactSum, weights: [transit.minorUnits] + inTransit.map { fees[$0].minorUnits })
      for (i, share) in zip(inTransit, shares.dropFirst()) { feeAmounts[i] = share }
    }
    if !elsewhere.isEmpty { warnings.append(SaldoWarning.feeInOtherCurrency) }

    let amount = asset.minorUnits - feeAmounts.reduce(0, +)
    if transit.currencyCode == currency, inTransit.isEmpty, elsewhere.isEmpty, amount != transit.minorUnits {
      warnings.append(SaldoWarning.unbalanced)
    }
    let lines = fees.indices.map { i in
      NormalizedLine(
        kind: .expense, category: category(fees[i]), amountMinor: feeAmounts[i],
        original: original(fees[i], accountCurrency: currency))
    }
    let hint = transit.account.isEmpty ? nil : transit.account
    return HalfDraft(
      group: group, direction: asset.side == .credit ? .outgoing : .incoming,
      account: accounts[asset.accountKey]!, accountKey: asset.accountKey, amountMinor: amount,
      transit: OriginalAmount(minorUnits: transit.minorUnits, currencyCode: transit.currencyCode),
      hint: hint, lines: lines, warnings: warnings)
  }

  /// Two paired halves → one transfer carrying both Saldo IDs (R-IMP-3).
  private func transfer(_ out: HalfDraft, _ incoming: HalfDraft) -> NormalizedRow {
    var warnings = out.warnings
    for w in incoming.warnings where !warnings.contains(w) { warnings.append(w) }
    if out.account.currency == incoming.account.currency, out.amountMinor != incoming.amountMinor,
      !warnings.contains(SaldoWarning.unbalanced)
    {
      warnings.append(SaldoWarning.unbalancedTransfer)
    }
    var notes = [out.group.note]
    if incoming.group.note != out.group.note { notes.append(incoming.group.note) }
    var tagWarnings: [String] = []
    let tag = tag(out.group, &tagWarnings) ?? tag(incoming.group, &tagWarnings)
    for w in tagWarnings where !warnings.contains(w) { warnings.append(w) }
    return NormalizedRow(
      fingerprints: [out.group.fingerprint, incoming.group.fingerprint], kind: .transfer,
      occurredAt: out.group.date, account: out.account, amountMinor: out.amountMinor,
      counterAccount: incoming.account, counterAmountMinor: incoming.amountMinor, lines: out.lines,
      payee: out.group.payee.isEmpty ? incoming.group.payee : out.group.payee,
      note: notes.filter { !$0.isEmpty }.joined(separator: "\n"),
      tag: tag, warnings: warnings)
  }

  /// An unpaired half → *needs review* (R-IMP-5).
  private func unpaired(_ half: HalfDraft) -> NormalizedRow {
    var warnings = half.warnings
    return NormalizedRow(
      fingerprints: [half.group.fingerprint], kind: .transferHalf, occurredAt: half.group.date,
      account: half.account, amountMinor: half.amountMinor, lines: half.lines,
      payee: half.group.payee, note: half.group.note, tag: tag(half.group, &warnings),
      transferHalf: TransferHalf(direction: half.direction, transit: half.transit, counterpartHint: half.hint),
      warnings: warnings)
  }

  // MARK: - Helpers

  /// R-IMP-SALDO-4: the tag is passed through as an event candidate.
  private func tag(_ group: SaldoGroup, _ warnings: inout [String]) -> String? {
    let tags = group.tags
    if tags.count > 1, !warnings.contains(SaldoWarning.severalTags) { warnings.append(SaldoWarning.severalTags) }
    return tags.first
  }

  private func category(_ leg: SaldoLeg) -> ExternalCategory {
    ExternalCategory(
      name: leg.account, kind: categoryKind(leg),
      parentName: leg.parentAccount.isEmpty ? nil : leg.parentAccount)
  }

  private func categoryKind(_ leg: SaldoLeg) -> CategoryKind {
    leg.type == .income ? .income : .expense
  }

  /// R-CUR-4: a leg in another currency than the account keeps its own amount as the original.
  private func original(_ leg: SaldoLeg, accountCurrency: String) -> OriginalAmount? {
    leg.currencyCode == accountCurrency ? nil : OriginalAmount(minorUnits: leg.minorUnits, currencyCode: leg.currencyCode)
  }
}
