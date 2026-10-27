import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// In-memory stand-ins for the repositories the pipeline uses (unit tests; the integration
/// test uses the SQLite store). Synthetic data only.
final class FakeDB: @unchecked Sendable {
  private let lock = NSLock()
  let calendar: Calendar

  var accounts: [Account] = []
  var categories: [AbacusDomain.Category] = []
  var events: [Event] = []
  var rules: [CategoryRule] = []
  var txns: [Txn] = []
  var lines: [AttachedRecord] = []
  var fingerprints: [String: ImportFingerprint] = [:]
  var mappings: [ImportMapping] = []
  var batches: [ImportBatch] = []
  var commits: [ImportCommit] = []

  init(calendar: Calendar = PipelineFixture.calendar) {
    self.calendar = calendar
  }

  func sync<T>(_ body: (FakeDB) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(self)
  }

  var store: FakeImportStore { FakeImportStore(db: self) }

  func pipeline(now: Date = PipelineFixture.now) -> ImportPipeline {
    ImportPipeline(
      store: FakeImportStore(db: self), accounts: FakeAccounts(db: self), categories: FakeCategories(db: self),
      events: FakeEvents(db: self), rules: FakeRules(db: self), calendar: calendar, now: { now })
  }

  func txn(fingerprint: String) -> Txn? {
    sync { db in db.fingerprints[fingerprint].flatMap { fp in db.txns.first { $0.id == fp.txnID } } }
  }

  /// Opening balance + effects of every transaction and attached record (R-ACC-3).
  func balance(_ accountID: Account.ID) -> Int64 {
    sync { db in
      var total = db.accounts.first { $0.id == accountID }?.openingBalanceMinor ?? 0
      for txn in db.txns {
        let lineEffect = db.lines.filter { $0.txnID == txn.id }
          .map { $0.kind == .expense ? -$0.amountMinor : $0.amountMinor }.reduce(0, +)
        if txn.accountID == accountID {
          switch txn.type {
          case .expense: total += (txn.isRefund ? txn.amountMinor : -txn.amountMinor) + lineEffect
          case .income: total += (txn.isRefund ? -txn.amountMinor : txn.amountMinor) + lineEffect
          case .transfer: total += -txn.amountMinor + lineEffect
          }
        }
        if txn.type == .transfer, txn.toAccountID == accountID { total += txn.toAmountMinor ?? txn.amountMinor }
      }
      return total
    }
  }
}

struct FakeImportStore: ImportStore {
  let db: FakeDB

  func existingFingerprints(_ ids: [String]) async throws -> [String: Txn.ID] {
    db.sync { db in
      var found: [String: Txn.ID] = [:]
      for id in ids { if let fp = db.fingerprints[id] { found[id] = fp.txnID } }
      return found
    }
  }

  private func inWindow(_ txn: Txn, _ from: Day, _ to: Day) -> Bool {
    let day = Day(txn.occurredAt, calendar: db.calendar)
    return day >= from && day <= to
  }

  func candidates(accountID: Account.ID, amountMinor: Int64, from: Day, to: Day) async throws -> [Txn] {
    db.sync { db in
      db.txns.filter {
        inWindow($0, from, to)
          && (($0.accountID == accountID && $0.amountMinor == amountMinor)
            || ($0.toAccountID == accountID && $0.toAmountMinor == amountMinor))
      }
    }
  }

  func pendingTxns(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn] {
    db.sync { db in db.txns.filter { $0.accountID == accountID && $0.isPendingAtBank && inWindow($0, from, to) } }
  }

  func mappings(source: ImportSource) async throws -> [ImportMapping] {
    db.sync { db in db.mappings.filter { $0.source == source } }
  }

  func commit(_ commit: ImportCommit) async throws {
    try db.sync { db in
      for fp in commit.fingerprints where db.fingerprints[fp.id] != nil {
        throw RepositoryError.notFound
      }
      db.commits.append(commit)
      db.batches.append(commit.batch)
      db.accounts += commit.newAccounts.map { var a = $0; a.importBatchID = commit.batch.id; return a }
      db.categories += commit.newCategories.map { var c = $0; c.importBatchID = commit.batch.id; return c }
      db.events += commit.newEvents.map { var e = $0; e.importBatchID = commit.batch.id; return e }
      for item in commit.txns {
        var txn = item.txn
        txn.importBatchID = commit.batch.id
        db.txns.append(txn)
        db.lines += item.lines
      }
      for txn in commit.updatedTxns {
        guard let i = db.txns.firstIndex(where: { $0.id == txn.id }) else { throw RepositoryError.notFound }
        db.txns[i] = txn
      }
      for fp in commit.fingerprints {
        db.fingerprints[fp.id] = ImportFingerprint(id: fp.id, txnID: fp.txnID, batchID: commit.batch.id)
      }
      for mapping in commit.mappings {
        db.mappings.removeAll { $0.source == mapping.source && $0.kind == mapping.kind && $0.externalKey == mapping.externalKey }
        db.mappings.append(mapping)
      }
      for rule in commit.rules {
        db.rules.removeAll { $0.id == rule.id }
        db.rules.append(rule)
      }
    }
  }

  func batches() async throws -> [ImportBatch] { db.sync { $0.batches.reversed() } }

  func undo(_ batchID: ImportBatch.ID) async throws {
    db.sync { db in
      let removed = Set(db.txns.filter { $0.importBatchID == batchID }.map(\.id))
      db.txns.removeAll { removed.contains($0.id) }
      db.lines.removeAll { removed.contains($0.txnID) }
      db.fingerprints = db.fingerprints.filter { $0.value.batchID != batchID && !removed.contains($0.value.txnID) }
      if let i = db.batches.firstIndex(where: { $0.id == batchID }) { db.batches[i].isUndone = true }
    }
  }
}

struct FakeAccounts: AccountRepository {
  let db: FakeDB
  func accounts(includeArchived: Bool) async throws -> [Account] {
    db.sync { $0.accounts.filter { includeArchived || !$0.isArchived } }
  }
  func save(_ account: Account) async throws {
    db.sync { db in
      db.accounts.removeAll { $0.id == account.id }
      db.accounts.append(account)
    }
  }
  func setArchived(_ id: Account.ID, _ isArchived: Bool) async throws {}
  func delete(_ id: Account.ID) async throws {}
}

struct FakeCategories: CategoryRepository {
  let db: FakeDB
  func categories(kind: CategoryKind?, includeArchived: Bool) async throws -> [AbacusDomain.Category] {
    db.sync { $0.categories.filter { (kind == nil || $0.kind == kind) && (includeArchived || !$0.isArchived) } }
  }
  func save(_ category: AbacusDomain.Category) async throws {
    db.sync { db in
      db.categories.removeAll { $0.id == category.id }
      db.categories.append(category)
    }
  }
  func setArchived(_ id: AbacusDomain.Category.ID, _ isArchived: Bool) async throws {}
  func delete(_ id: AbacusDomain.Category.ID, reassignTo: AbacusDomain.Category.ID?) async throws {}
}

struct FakeEvents: EventRepository {
  let db: FakeDB
  func events(includeArchived: Bool) async throws -> [Event] { db.sync { $0.events } }
  func save(_ event: Event) async throws { db.sync { $0.events.append(event) } }
  func setArchived(_ id: Event.ID, _ isArchived: Bool) async throws {}
  func delete(_ id: Event.ID) async throws {}
}

struct FakeRules: RuleRepository {
  let db: FakeDB
  func rules() async throws -> [CategoryRule] { db.sync { $0.rules.sorted { $0.position < $1.position } } }
  func save(_ rule: CategoryRule) async throws {
    db.sync { db in
      db.rules.removeAll { $0.id == rule.id }
      db.rules.append(rule)
    }
  }
  func save(_ rule: CategoryRule?, updating txns: [Txn]) async throws {
    if let rule { try await save(rule) }
  }
  func delete(_ id: CategoryRule.ID) async throws {}
  func recordHit(_ id: CategoryRule.ID) async throws {}
}

/// Synthetic inputs shared by the pipeline tests.
enum PipelineFixture {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static let now = date("2026-02-01")

  static func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  static func date(_ day: String, _ hour: Int = 12) -> Date {
    let d = Day(day)!
    return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour))!
  }

  static func data(_ folder: String, _ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(folder)/\(name)", withExtension: "csv"))
    return try Data(contentsOf: url)
  }

  static let saldoHeader =
    #""Transaction ID","Transaction Date","Description","Parent account","Account","Account Type","Archived","Journal Type","Amount","Currency","Tags","Accrual Month","Notes""#

  /// A Saldo file from leg lines `id,date,description,account,type,archived,side,amount,currency,tag`.
  static func saldo(_ legs: [String]) -> Data {
    let lines = legs.map { leg -> String in
      let f = leg.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      let fields = [f[0], f[1], f[2], "", f[3], f[4], f[5], f[6], f[7], f[8], f.count > 9 ? f[9] : "", String(f[1].prefix(10)), ""]
      return fields.map { "\"\($0)\"" }.joined(separator: ",")
    }
    return Data(([saldoHeader] + lines).joined(separator: "\n").utf8)
  }

  static let pkoHeader =
    #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#

  /// A PKO statement (Windows-1250, CRLF) from rows of already quoted CSV fields.
  static func pko(_ rows: [String]) -> Data {
    let text = ([pkoHeader] + rows).joined(separator: "\r\n") + "\r\n"
    return text.data(using: .windowsCP1250)!
  }

  static let pkoAccount = Account(
    id: id(1), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: date("2026-01-01", 0), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  static let pkoUSD = Account(
    id: id(2), name: "PKO USD", currency: .USD, kind: .bank, openingDate: date("2026-01-01", 0),
    iban: "55 5555 5555 5555 5555 5555 5555")
  static let groceries = AbacusDomain.Category(id: id(10), name: "Groceries", kind: .expense)
  static let taxi = AbacusDomain.Category(id: id(11), name: "Taxi", kind: .expense)
  static let salary = AbacusDomain.Category(id: id(20), name: "Salary", kind: .income)
}
