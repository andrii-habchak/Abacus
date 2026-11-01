import AbacusDomain
import Foundation

// MARK: - PKO target account checks (C41)

extension ImportPipeline {
  /// How many rows of a PKO statement are already imported into each of `accountIDs` (exact
  /// fingerprints, R-IMP-3; the fingerprint includes the account, so each account is checked
  /// on its own). Accounts with no such rows are left out. Read-only.
  ///
  /// A PKO statement names no account of its own (`docs/import/pko-format.md`), so this is
  /// the only trace in the database of where a file went before: it warns when "Import into"
  /// points elsewhere, so the rows don't end up in two accounts.
  public func alreadyImportedRows(of data: Data, in accountIDs: [Account.ID]) async throws -> [Account.ID: Int] {
    guard Self.detect(data) == .pko, !accountIDs.isEmpty else { return [:] }
    let all = try await accounts.accounts(includeArchived: true)
    var found: [Account.ID: Int] = [:]
    for id in accountIDs {
      guard let account = all.first(where: { $0.id == id }) else { continue }
      let rows = try PKOParser(account: account, calendar: calendar).parse(data).rows
      let fingerprints = rows.flatMap(\.fingerprints)
      guard !fingerprints.isEmpty else { continue }
      let existing = try await store.existingFingerprints(fingerprints)
      let count = rows.filter { row in row.fingerprints.contains { existing[$0] != nil } }.count
      if count > 0 { found[id] = count }
    }
    return found
  }
}
