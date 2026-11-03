import AbacusDomain
import AbacusMCP
import AbacusStore
import Foundation
import SQLiteData
import Testing

final class FakeSnapshots: SnapshotProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var fail = false
  var taken: Int { lock.withLock { count } }

  func snapshot(of database: any DatabaseWriter, reason: String) async throws -> String {
    if fail { throw ToolError("disk full") }
    lock.withLock { count += 1 }
    return "snapshot-\(taken)"
  }
}

final class CountingNotifier: ChangeNotifier, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var posts: Int { lock.withLock { count } }
  func databaseChanged() { lock.withLock { count += 1 } }
}

/// A writable server over a scratch database.
struct WriteRig {
  let scratch: Scratch
  let snapshots = FakeSnapshots()
  let notifier = CountingNotifier()
  let log: WriteLog
  let server: MCPServer
  let session: WriteSession
  let reader: MCPServer

  init(maxRows: Int = WriteSession.defaultMaxRows, now: @escaping @Sendable () -> Date = { Date() }) async throws {
    scratch = try await Scratch.make()
    log = WriteLog(url: scratch.url.appendingPathExtension("log"))
    let database = try MCPDatabase.openReadWrite(at: scratch.url)
    session = WriteSession(
      database: database, snapshots: snapshots, notifier: notifier, log: log, maxRows: maxRows, now: now)
    let today = Day(year: 2026, month: 3, day: 20)
    let tools = WriteTools.all(session: session, rates: { _ in StubRates() }, calendar: scratch.calendar, today: { today })
    server = MCPServer(instructions: "test", tools: tools)
    reader = try scratch.server()
  }

  func remove() {
    scratch.remove()
    try? FileManager.default.removeItem(at: log.url)
  }

  /// Propose, then confirm with the returned token; returns the confirmed result.
  func write(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    let proposal = try await server.json(name, .object(arguments))
    #expect(proposal["status"]?.stringValue == "proposed")
    var confirmed = arguments
    confirmed["confirm_token"] = proposal["confirm_token"]
    return try await server.json(name, .object(confirmed))
  }

  func transactionCount() async throws -> Int {
    try await reader.json("search_transactions")["matching"]?.intValue ?? -1
  }
}

@Suite("MCP · write safeguards")
struct WriteSafeguardTests {
  static let expense: [String: JSONValue] = [
    "type": "expense", "date": "2026-03-10", "account": "Main", "amount": "12.50", "category": "Food › Groceries",
    "payee": "Bakery",
  ]

  @Test("A first call only proposes: nothing changes, nothing is snapshotted or logged")
  func proposeOnly() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let proposal = try await rig.server.json("create_transaction", .object(Self.expense))
    #expect(proposal["status"]?.stringValue == "proposed")
    #expect(proposal["summary"]?.stringValue?.contains("12.50") == true)
    #expect(try await rig.transactionCount() == 4)
    #expect(rig.snapshots.taken == 0)
    #expect(rig.log.lines().isEmpty)
    #expect(rig.notifier.posts == 0)
  }

  @Test("Confirming executes once, logs it, snapshots, notifies; the token is single-use")
  func confirm() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let proposal = try await rig.server.json("create_transaction", .object(Self.expense))
    var args = Self.expense
    args["confirm_token"] = proposal["confirm_token"]
    let done = try await rig.server.json("create_transaction", .object(args))
    #expect(done["status"]?.stringValue == "done")
    #expect(try await rig.transactionCount() == 5)
    #expect(rig.snapshots.taken == 1)
    #expect(rig.notifier.posts == 1)
    #expect(rig.log.lines().count == 1)
    #expect(rig.log.lines()[0].contains("create_transaction"))
    let replay = try await rig.server.call("create_transaction", .object(args))
    #expect(replay.isError)
    #expect(try await rig.transactionCount() == 5)
  }

  @Test("A token only works for the arguments it was issued for")
  func tokenBoundToArguments() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let proposal = try await rig.server.json("create_transaction", .object(Self.expense))
    var changed = Self.expense
    changed["amount"] = "9999.00"
    changed["confirm_token"] = proposal["confirm_token"]
    let result = try await rig.server.call("create_transaction", .object(changed))
    #expect(result.isError)
    #expect(try await rig.transactionCount() == 4)
  }

  @Test("A token expires")
  func tokenExpires() async throws {
    let clock = Clock()
    let rig = try await WriteRig(now: { clock.now })
    defer { rig.remove() }
    let proposal = try await rig.server.json("create_transaction", .object(Self.expense))
    clock.advance(WriteSession.tokenLifetime + 1)
    var args = Self.expense
    args["confirm_token"] = proposal["confirm_token"]
    #expect(try await rig.server.call("create_transaction", .object(args)).isError)
    #expect(try await rig.transactionCount() == 4)
  }

  @Test("One snapshot per session, before the first write only")
  func snapshotOnce() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    _ = try await rig.write("create_transaction", Self.expense)
    _ = try await rig.write("create_transaction", Self.expense.merging(["amount": "1.00"]) { $1 })
    #expect(rig.snapshots.taken == 1)
    #expect(rig.notifier.posts == 2)
  }

  @Test("A failed snapshot stops the write")
  func snapshotFailure() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    rig.snapshots.fail = true
    let proposal = try await rig.server.json("create_transaction", .object(Self.expense))
    var args = Self.expense
    args["confirm_token"] = proposal["confirm_token"]
    #expect(try await rig.server.call("create_transaction", .object(args)).isError)
    #expect(try await rig.transactionCount() == 4)
    #expect(rig.log.lines().first?.contains("failed") == true)
  }

  @Test("The per-call row cap refuses a bigger change")
  func rowCap() async throws {
    let rig = try await WriteRig(maxRows: 1)
    defer { rig.remove() }
    // Deleting "Food" reassigns its one transaction (cap 1 passes); the salary category has one too.
    // Undo of an import with two transactions exceeds the cap:
    let batch = try await Importer.seed(rig.scratch, rows: 2)
    let result = try await rig.server.call("undo_import", ["batch_id": .string(batch.uuidString)])
    #expect(result.isError)
    #expect(result.text.contains("at most 1"))
    #expect(try await rig.transactionCount() == 6)
  }

  @Test("Writes are refused when the database is on a newer schema")
  func newerSchema() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let database = try MCPDatabase.openReadWrite(at: rig.scratch.url)
    try await database.write {
      try $0.execute(sql: #"INSERT INTO "grdb_migrations" ("identifier") VALUES ('v999: from the future')"#)
    }
    let result = try await rig.server.call("create_transaction", .object(Self.expense))
    #expect(result.isError)
    #expect(result.text.contains("newer schema"))
    #expect(try MCPDatabase.schemaState(database) == .newer(unknown: 1))
  }

  @Test("There is no account delete, restore or settings tool")
  func forbiddenTools() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let response = try #require(await rig.server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let list = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    let names = list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    for name in names {
      #expect(!name.contains("restore") && !name.contains("setting") && name != "delete_account", "\(name)")
    }
    #expect(names.contains("create_transaction") && names.contains("archive_account"))
  }
}

final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Seeds import batches on the scratch database.
enum Importer {
  static func seed(_ scratch: Scratch, source: ImportSource = .saldo, accountID: UUID? = nil, rows: Int) async throws -> UUID {
    let database = try MCPDatabase.openReadWrite(at: scratch.url)
    let store = SQLiteImportStore(database: database, calendar: scratch.calendar)
    let batch = ImportBatch(source: source, fileName: "statement.csv", accountID: accountID)
    let txns = (0..<rows).map { index in
      TxnWithLines(
        txn: Txn(
          type: .expense, occurredAt: scratch.day("2026-03-1\(index)"), accountID: scratch.main.id, amountMinor: 1_000,
          categoryID: scratch.food.id, payee: "Imported \(index)", source: TxnSource(rawValue: source.rawValue) ?? .manual, importBatchID: batch.id),
        lines: [])
    }
    try await store.commit(
      ImportCommit(
        batch: batch, txns: txns,
        fingerprints: txns.enumerated().map { ImportFingerprint(id: "test:\(batch.id):\($0.offset)", txnID: $0.element.txn.id, batchID: batch.id) }))
    return batch.id
  }
}
