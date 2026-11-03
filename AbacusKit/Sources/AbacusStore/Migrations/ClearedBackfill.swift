import GRDB

/// N6 (R-CLR): which existing transactions count as cleared when v19 adds the flags.
///
/// - Rows imported from a bank file (PKO) or from Saldo are cleared, pending holds are not. A
///   transfer is cleared per side: both sides for Saldo; for PKO the side whose account is the target
///   of a batch that holds one of its fingerprints (the other side only once its own statement was
///   imported).
/// - A hand-typed row that an import linked to a bank row (it carries a fingerprint) is cleared the
///   same way.
/// - A balance correction restates the bank balance and is cleared.
/// - Everything else (hand-typed rows, debt legs without a fingerprint) stays uncleared.
/// Only ever sets flags to 1, so it can run again.
enum ClearedBackfill {
  static func run(_ db: Database) throws {
    let onBatchAccount = { (side: String) in
      """
      EXISTS (SELECT 1 FROM importFingerprints f JOIN importBatches b ON b.id = f.batchID \
      WHERE f.txnID = txns.id AND b.accountID = txns.\(side))
      """
    }
    let saldoFingerprint =
      "EXISTS (SELECT 1 FROM importFingerprints f WHERE f.txnID = txns.id AND f.id LIKE 'saldo:%')"
    let anyFingerprint = "EXISTS (SELECT 1 FROM importFingerprints f WHERE f.txnID = txns.id)"
    let noBatchAccount =
      """
      NOT EXISTS (SELECT 1 FROM importFingerprints f JOIN importBatches b ON b.id = f.batchID \
      WHERE f.txnID = txns.id AND b.accountID IS NOT NULL)
      """
    try db.execute(
      sql: """
        UPDATE txns SET isCleared = 1 WHERE isPendingAtBank = 0 AND (
          (source IN ('pko', 'saldo') AND type != 'transfer')
          OR (source = 'saldo' AND type = 'transfer')
          OR (type = 'transfer' AND (source IN ('pko', 'saldo') OR \(anyFingerprint))
              AND (\(onBatchAccount("accountID")) OR \(saldoFingerprint) OR \(noBatchAccount)))
          OR (source = 'manual' AND type != 'transfer' AND \(anyFingerprint)))
        """)
    try db.execute(
      sql: """
        UPDATE txns SET isToCleared = 1 WHERE isPendingAtBank = 0 AND type = 'transfer'
          AND toAccountID IS NOT NULL
          AND (source = 'saldo' OR \(onBatchAccount("toAccountID")) OR \(saldoFingerprint))
        """)
    try db.execute(sql: "UPDATE txns SET isCleared = 1 WHERE isBalanceCorrection = 1 AND isPendingAtBank = 0")
  }
}
