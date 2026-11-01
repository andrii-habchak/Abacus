import AbacusDomain
import Foundation

// MARK: - PKO target account checks (C41)

extension ImportPipeline {
  /// How many rows of a PKO statement are already imported into each of `accountIDs` (exact
  /// fingerprints, R-IMP-3; the fingerprint includes the account, so each account is checked
  /// on its own). Rows of a batch moved to another account (C44) count for the account their
  /// transactions are on now. Accounts with no such rows are left out. Read-only.
  ///
  /// A PKO statement names no account of its own (`docs/import/pko-format.md`), so this is
  /// the only trace in the database of where a file went before: it warns when "Import into"
  /// points elsewhere, so the rows don't end up in two accounts.
  public func alreadyImportedRows(of data: Data, in accountIDs: [Account.ID]) async throws -> [Account.ID: Int] {
    guard Self.detect(data) == .pko, !accountIDs.isEmpty else { return [:] }
    let all = try await accounts.accounts(includeArchived: true)
    let wanted = Set(accountIDs)
    var rowsPerAccount: [Account.ID: Set<Int>] = [:]
    // Accounts a moved batch may have come from: every account in the statement's currency.
    let currency = Self.statementCurrency(data)
    var checked = all.filter { wanted.contains($0.id) || (currency != nil && $0.currency == currency) }
    checked.sort { (wanted.contains($0.id) ? 0 : 1) < (wanted.contains($1.id) ? 0 : 1) }
    for account in checked {
      let rows = try PKOParser(account: account, calendar: calendar).parse(data).rows
      guard !rows.isEmpty else { continue }
      if wanted.contains(account.id) {
        let existing = try await store.existingFingerprints(rows.flatMap(\.fingerprints))
        for (index, row) in rows.enumerated() where row.fingerprints.contains(where: { existing[$0] != nil }) {
          rowsPerAccount[account.id, default: []].insert(index)
        }
      }
      // C44: keys moved away from `account`: the rows sit where their transactions are now.
      let moved = rows.map { $0.fingerprints.map(ImportFingerprint.movedID) }
      let owners = try await store.fingerprintOwners(moved.flatMap { $0 })
      for (index, keys) in moved.enumerated() {
        for owner in keys.compactMap({ owners[$0] }) {
          for id in owner.accountIDs where wanted.contains(id) { rowsPerAccount[id, default: []].insert(index) }
        }
      }
    }
    return rowsPerAccount.filter { !$0.value.isEmpty }.mapValues(\.count)
  }

  /// C44: `rows` (parsed for one account) with the moved keys they would have if they had been
  /// imported into any account of `currency` (the target included: a batch moved away and back)
  /// and moved afterwards. The parser is deterministic, so the rows of each parse line up.
  func movedKeys(of data: Data, rows: [NormalizedRow], currency: Currency, accounts: [Account]) throws -> [NormalizedRow] {
    var result = rows
    for account in accounts where account.currency == currency {
      let parsed = try PKOParser(account: account, calendar: calendar).parse(data).rows
      guard parsed.count == rows.count else { continue }
      for index in result.indices {
        result[index].movedFingerprints += parsed[index].fingerprints.map(ImportFingerprint.movedID)
      }
    }
    return result
  }
}
