import AbacusDomain

/// N2: the transaction open in the editor was changed or deleted by another program
/// (`abacus-mcp`, `abacus-import`) after the sheet read it. Found on Save by comparing the row
/// read when the sheet opened with the row stored now (no schema change; every stored value,
/// lines included, is the fingerprint).
public enum EditorSaveConflict: Hashable, Sendable {
  case changed
  case deleted

  /// Nil when the stored row is still the one the sheet opened.
  public init?(opened: TxnWithLines, now: TxnWithLines?) {
    guard let now else {
      self = .deleted
      return
    }
    guard !Self.sameRecord(opened, now) else { return nil }
    self = .changed
  }

  /// Equal values; the lines compared regardless of the order they were read in.
  static func sameRecord(_ a: TxnWithLines, _ b: TxnWithLines) -> Bool {
    a.txn == b.txn && a.lines.count == b.lines.count && Set(a.lines) == Set(b.lines)
  }

  public var title: String { "This transaction was changed by another program." }

  public var message: String {
    switch self {
    case .changed: "Replace it with your version?"
    case .deleted: "It was deleted there. Replace it with your version?"
    }
  }
}
