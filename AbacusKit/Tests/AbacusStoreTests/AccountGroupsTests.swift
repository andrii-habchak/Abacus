import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Account groups (R-MGMT-9, D48) and migration "v11: account groups": every distinct group
/// name becomes a group, accounts point at it, the old order is kept; balances and net worth
/// do not change.
@Suite("Accounts · groups (v11)")
struct AccountGroupsTests {
  typealias F = StoreFixture
  /// The last migration before v11 ("v10: debts" runs first; the Txn struct needs its column).
  static let v9 = "v10: debts"

  /// Fixed rates for the net worth comparison: 1 EUR = 4 PLN.
  struct FixedRates: CurrencyConverter {
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { latestRate(from: from, to: to) }
    func latestRate(from: Currency, to: Currency) -> Decimal? {
      switch (from, to) {
      case (.EUR, .PLN): 4
      case (.PLN, .EUR): Decimal(string: "0.25")
      default: from == to ? 1 : nil
      }
    }
    var latestDay: Day? { Day("2026-03-31") }
  }

  /// (id, name, currency, kind, opening, groupName, position, archived): the old page showed
  /// "Bank Z" (pos 0, then its "Bank Z" sibling at 3), "Cash" ungrouped, " Mono " (trimmed to
  /// "Mono"), an empty group name (ungrouped), an archived account in "Mono".
  static let rows: [(Int, String, String, String, Int64, String?, Int, Bool)] = [
    (901, "Z current", "PLN", "bank", 1_000_00, "Bank Z", 0, false),
    (902, "Cash", "PLN", "cash", 50_00, nil, 1, false),
    (903, "Mono card", "EUR", "card", 200_00, " Mono ", 2, false),
    (904, "Z savings", "EUR", "savings", 300_00, "Bank Z", 3, false),
    (905, "Wallet", "PLN", "cash", 0, "", 4, false),
    (906, "Mono old", "PLN", "card", 0, "Mono", 5, true),
    (907, "Mono credit", "PLN", "creditCard", -120_00, "Mono", 6, false),
  ]

  static func txns() -> [Txn] {
    [
      Txn(
        id: F.id(950), type: .expense, occurredAt: F.at("2026-03-02"), accountID: F.id(901), amountMinor: 40_00),
      Txn(id: F.id(951), type: .income, occurredAt: F.at("2026-03-03"), accountID: F.id(903), amountMinor: 15_00),
      Txn(
        id: F.id(952), type: .transfer, occurredAt: F.at("2026-03-04"), accountID: F.id(901), amountMinor: 100_00,
        toAccountID: F.id(904), toAmountMinor: 25_00),
    ]
  }

  /// A database at the schema before v11 (after v9) with grouped accounts and transactions.
  static func preV11Database(at url: URL? = nil) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try url.map { try DatabaseQueue(path: $0.path, configuration: configuration) }
      ?? DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: v9)
    try queue.write { db in
      // The test writes `Txn` rows of the current model; v14's column is added early (v14 skips it then).
      try db.execute(
        sql: #"ALTER TABLE "txns" ADD COLUMN "isBalanceCorrection" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0"#)
      #expect(try !db.columns(in: "accounts").contains { $0.name == "groupID" })
      for row in rows {
        try db.execute(
          sql: """
            INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate", \
            "groupName", "position", "isArchived", "colorHex") VALUES (?, ?, ?, ?, ?, '2026-01-01 00:00:00.000', ?, ?, ?, '#0A64D6')
            """,
          arguments: [F.id(row.0).uuidString.lowercased(), row.1, row.2, row.3, row.4, row.5, row.6, row.7])
      }
      for txn in txns() { try Txn.insert { txn }.execute(db) }
    }
    return queue
  }

  /// The same accounts and transactions written on the current schema without groups: the
  /// balances and net worth the migrated database must show.
  static func reference() async throws -> (balances: [Account.ID: Int64], netWorth: NetWorth) {
    let f = try F()
    for row in rows {
      try await f.accounts.save(
        Account(
          id: F.id(row.0), name: row.1, currency: Currency(rawValue: row.2)!, kind: AccountKind(rawValue: row.3)!,
          openingBalanceMinor: row.4, openingDate: F.at("2026-01-01", "00:00"), colorHex: "#0A64D6",
          position: row.6, isArchived: row.7))
    }
    for txn in txns() { try await f.txns.save(txn, lines: []) }
    return try await measure(f.database)
  }

  static func measure(_ database: any DatabaseWriter) async throws -> (balances: [Account.ID: Int64], netWorth: NetWorth) {
    let accounts = SQLiteAccountRepository(database: database, calendar: F.calendar)
    let balances = try await accounts.balances(asOf: Day("2026-03-31")!)
    let all = try await accounts.accounts(includeArchived: true)
    let txns = try await SQLiteTxnRepository(database: database, calendar: F.calendar)
      .transactions(matching: TxnQuery(newestFirst: false))
    let netWorth = Calc.netWorth(
      accounts: all, txns: txns, currency: .PLN, converter: FixedRates(), calendar: F.calendar)
    return (balances, netWorth)
  }

  @Test("v11 turns group names into groups, keeps the order shown, balances and net worth")
  func migration() async throws {
    let queue = try Self.preV11Database()
    try AbacusDatabase.migrator().migrate(queue)
    let repository = SQLiteAccountRepository(database: queue, calendar: F.calendar)
    let groups = try await repository.groups()
    // In the order of their first account; names trimmed; the empty name is no group.
    #expect(groups.map(\.name) == ["Bank Z", "Mono"])
    let accounts = try await repository.accounts(includeArchived: true)
    func group(_ n: Int) -> String? {
      let account = accounts.first { $0.id == F.id(n) }!
      return account.groupID.flatMap { id in groups.first { $0.id == id }?.name }
    }
    #expect(group(901) == "Bank Z")
    #expect(group(904) == "Bank Z")
    #expect(group(903) == "Mono")
    #expect(group(906) == "Mono")
    #expect(group(907) == "Mono")
    #expect(group(902) == nil)
    #expect(group(905) == nil)
    // Custom order = what the page showed: Bank Z (Z current, Z savings), Mono (card, old,
    // credit), then the ungrouped Cash and Wallet; numbered across groups and accounts.
    let order = (groups.map { ($0.name, $0.position) } + accounts.map { ($0.name, $0.position) })
      .sorted { $0.1 < $1.1 }.map(\.0)
    #expect(
      order == ["Bank Z", "Z current", "Z savings", "Mono", "Mono card", "Mono old", "Mono credit", "Cash", "Wallet"])
    // Ids are lowercase text, as SQLiteData writes them.
    let stored = try await queue.read { db in try String.fetchAll(db, sql: #"SELECT "id" FROM "accountGroups""#) }
    #expect(stored.allSatisfy { $0 == $0.lowercased() })

    let migrated = try await Self.measure(queue)
    let expected = try await Self.reference()
    #expect(migrated.balances == expected.balances)
    #expect(migrated.netWorth.total == expected.netWorth.total)
    #expect(migrated.netWorth.assets == expected.netWorth.assets)
    #expect(migrated.netWorth.liabilities == expected.netWorth.liabilities)
    #expect(migrated.balances[F.id(901)] == Int64(1_000_00 - 40_00 - 100_00))
  }

  @Test("v11 on a database file; running the migrator again changes nothing")
  func onFileAndIdempotent() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-v11-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "old.sqlite")
    _ = try Self.preV11Database(at: url)
    let database = try AbacusDatabase.open(at: url)
    let snapshot = {
      try database.read { db in
        try String.fetchAll(
          db,
          sql: #"""
            SELECT "accounts"."name" || '@' || "accounts"."position" || '@' || COALESCE("accountGroups"."name", '-')
            FROM "accounts" LEFT JOIN "accountGroups" ON "accountGroups"."id" = "accounts"."groupID"
            ORDER BY "accounts"."name"
            """#)
      }
    }
    let first = try snapshot()
    #expect(first.contains("Mono card@4@Mono"))
    #expect(first.contains("Wallet@8@-"))
    try AbacusDatabase.migrator().migrate(database)
    #expect(try snapshot() == first)
    #expect(try database.read { db in try Int.fetchOne(db, sql: #"SELECT COUNT(*) FROM "accountGroups""#) } == 2)
  }

  @Test("v11 on a database without group names creates no group")
  func noGroups() async throws {
    let f = try F()
    try await f.accounts.save(F.bank)
    #expect(try await f.accounts.groups().isEmpty)
  }

  @Test("R-MGMT-9: groups are created, renamed, ordered; deleting one moves its accounts to the top level")
  func groupCRUD() async throws {
    let f = try F()
    let a = AccountGroup(name: "Alpha", position: 1)
    let b = AccountGroup(name: "Beta", position: 0, colorHex: "#2E9E4F")
    try await f.accounts.saveGroup(a)
    try await f.accounts.saveGroup(b)
    #expect(try await f.accounts.groups().map(\.name) == ["Beta", "Alpha"])
    var renamed = a
    renamed.name = "Alpha 2"
    renamed.position = -1
    try await f.accounts.saveGroup(renamed)
    #expect(try await f.accounts.groups() == [renamed, b])

    var bank = F.bank
    bank.groupID = a.id
    try await f.accounts.save(bank)
    try await f.accounts.save(F.card)
    #expect(try await f.accounts.accounts(includeArchived: true).first { $0.id == bank.id }?.groupID == a.id)
    try await f.accounts.deleteGroup(a.id)
    #expect(try await f.accounts.groups() == [b])
    let after = try await f.accounts.accounts(includeArchived: true)
    #expect(after.count == 2)
    #expect(after.allSatisfy { $0.groupID == nil })
    await #expect(throws: RepositoryError.notFound) { try await f.accounts.deleteGroup(a.id) }
  }
}
