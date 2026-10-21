import AbacusDomain
import CryptoKit
import Foundation

// Shared contract file (PLAN.md §1): parsers (A3 Saldo, A4 PKO) produce `ParsedImport`; the
// pipeline (A6) matches, dedupes, previews and commits it. Changes go through the orchestrator.

/// A source account as named in the file. `key` is what import mappings remember (R-IMP-2).
public struct ExternalAccount: Hashable, Sendable {
  public var name: String
  public var currency: Currency
  public var kind: AccountKind?
  public var isArchived: Bool
  public var iban: String?
  /// Set when the parser already knows the Abacus account (PKO: the user picked it).
  public var resolvedID: Account.ID?

  public init(
    name: String, currency: Currency, kind: AccountKind? = nil, isArchived: Bool = false,
    iban: String? = nil, resolvedID: Account.ID? = nil
  ) {
    self.name = name
    self.currency = currency
    self.kind = kind
    self.isArchived = isArchived
    self.iban = iban
    self.resolvedID = resolvedID
  }

  public var key: String { "\(name)|\(currency.rawValue)" }
}

public struct ExternalCategory: Hashable, Sendable {
  public var name: String
  public var kind: CategoryKind
  public var parentName: String?

  public init(name: String, kind: CategoryKind, parentName: String? = nil) {
    self.name = name
    self.kind = kind
    self.parentName = parentName
  }

  public var key: String { "\(kind.rawValue)|\(parentName.map { $0 + "/" } ?? "")\(name)" }
}

/// An amount in any ISO 4217 currency (merchant amount, in-transit amount).
public struct OriginalAmount: Hashable, Sendable {
  public var minorUnits: Int64
  public var currencyCode: String

  public init(minorUnits: Int64, currencyCode: String) {
    self.minorUnits = minorUnits
    self.currencyCode = currencyCode
  }
}

/// An attached record of a row: fee, cashback or split line (R-TX-6).
public struct NormalizedLine: Hashable, Sendable {
  public var kind: CategoryKind
  public var category: ExternalCategory?
  /// Positive, in the row account's currency.
  public var amountMinor: Int64
  public var original: OriginalAmount?
  public var note: String

  public init(
    kind: CategoryKind, category: ExternalCategory?, amountMinor: Int64,
    original: OriginalAmount? = nil, note: String = ""
  ) {
    self.kind = kind
    self.category = category
    self.amountMinor = amountMinor
    self.original = original
    self.note = note
  }
}

/// One half of a transfer the parser could not pair (R-IMP-SALDO-2) → "needs review".
public struct TransferHalf: Hashable, Sendable {
  public enum Direction: String, Hashable, Sendable { case outgoing, incoming }
  public var direction: Direction
  /// The amount booked in transit (Saldo's MONEY_ON_THE_WAY leg).
  public var transit: OriginalAmount
  /// The counterpart account name if the source hints at it; not reliable.
  public var counterpartHint: String?

  public init(direction: Direction, transit: OriginalAmount, counterpartHint: String? = nil) {
    self.direction = direction
    self.transit = transit
    self.counterpartHint = counterpartHint
  }
}

/// A source transaction normalised to Abacus terms, not yet matched to Abacus entities.
public struct NormalizedRow: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    case expense, income, transfer
    /// Sets the account's opening balance when the import creates the account (R-IMP-SALDO-3).
    case openingBalance
    /// See `transferHalf`.
    case transferHalf
  }

  /// Every source key this row stands for (a paired Saldo transfer has two). Non-empty.
  public var fingerprints: [String]
  public var kind: Kind
  public var occurredAt: Date
  /// Value/booking day where the source has one (PKO `Data waluty`).
  public var valueDay: Day?
  /// Source account; for a transfer the from-account.
  public var account: ExternalAccount
  /// Positive, in `account.currency`. Opening balance: signed.
  public var amountMinor: Int64
  public var category: ExternalCategory?
  /// Transfer: the to-account and the amount received in its currency.
  public var counterAccount: ExternalAccount?
  public var counterAmountMinor: Int64?
  public var isRefund: Bool
  public var original: OriginalAmount?
  public var lines: [NormalizedLine]
  /// "Description" (merchant / payee).
  public var payee: String
  public var note: String
  /// Saldo tag: a candidate event (R-IMP-SALDO-4).
  public var tag: String?
  /// PKO hold (R-IMP-PKO-2).
  public var isPending: Bool
  public var transferHalf: TransferHalf?
  /// Counterparty bank account number, for own-account transfer detection (R-IMP-PKO-3).
  public var counterpartyIBAN: String?
  /// Problems the preview should show for this row (e.g. unbalanced legs).
  public var warnings: [String]

  public var id: String { fingerprints[0] }

  public init(
    fingerprints: [String], kind: Kind, occurredAt: Date, valueDay: Day? = nil,
    account: ExternalAccount, amountMinor: Int64, category: ExternalCategory? = nil,
    counterAccount: ExternalAccount? = nil, counterAmountMinor: Int64? = nil,
    isRefund: Bool = false, original: OriginalAmount? = nil, lines: [NormalizedLine] = [],
    payee: String = "", note: String = "", tag: String? = nil, isPending: Bool = false,
    transferHalf: TransferHalf? = nil, counterpartyIBAN: String? = nil, warnings: [String] = []
  ) {
    precondition(!fingerprints.isEmpty, "A row needs at least one fingerprint")
    self.fingerprints = fingerprints
    self.kind = kind
    self.occurredAt = occurredAt
    self.valueDay = valueDay
    self.account = account
    self.amountMinor = amountMinor
    self.category = category
    self.counterAccount = counterAccount
    self.counterAmountMinor = counterAmountMinor
    self.isRefund = isRefund
    self.original = original
    self.lines = lines
    self.payee = payee
    self.note = note
    self.tag = tag
    self.isPending = isPending
    self.transferHalf = transferHalf
    self.counterpartyIBAN = counterpartyIBAN
    self.warnings = warnings
  }
}

public struct ImportWarning: Hashable, Sendable {
  /// 1-based line in the source file, when known.
  public var line: Int?
  public var message: String

  public init(line: Int?, message: String) {
    self.line = line
    self.message = message
  }
}

public struct ParsedImport: Sendable {
  public var source: ImportSource
  public var rows: [NormalizedRow]
  public var warnings: [ImportWarning]
  /// Source rows deliberately not turned into transactions.
  public var skippedRowCount: Int

  public init(source: ImportSource, rows: [NormalizedRow], warnings: [ImportWarning] = [], skippedRowCount: Int = 0) {
    self.source = source
    self.rows = rows
    self.warnings = warnings
    self.skippedRowCount = skippedRowCount
  }
}

public enum ImportError: Error, Equatable, Sendable {
  case unrecognisedFormat
  case unreadableEncoding
  case malformed(line: Int, reason: String)
}

public protocol ImportParser: Sendable {
  static var source: ImportSource { get }
  /// Cheap format sniffing on the file's first bytes (R-IMP-1).
  static func canParse(_ data: Data) -> Bool
  func parse(_ data: Data) throws -> ParsedImport
}

/// Fingerprint construction (R-IMP-3). Keys are ASCII and < 255 characters (CloudKit record
/// names), so free text is hashed.
public enum Fingerprint {
  public static func saldo(transactionID: String) -> String {
    "saldo:\(transactionID)"
  }

  /// `pko:` + SHA-256 of the account id and the row's identifying parts, joined with `|`.
  public static func pko(accountID: Account.ID, parts: [String]) -> String {
    "pko:" + sha256Hex(([accountID.uuidString] + parts).joined(separator: "|"))
  }

  public static func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
