import SQLiteData

/// The snapshot used before a session's first write: N1's snapshot API, once it has merged.
/// Until then there is none, and the server refuses to enable write tools (a write without a
/// restorable copy first is not allowed). See docs/status/N2.md.
public enum LiveSnapshots {
  public static let provider: (any SnapshotProvider)? = nil
}
