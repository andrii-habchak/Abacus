import AbacusDomain
import AbacusMCP
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Rates for tests: 1 EUR = 4 PLN, nothing else.
struct StubRates: CurrencyConverter {
  func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { latestRate(from: from, to: to) }
  func latestRate(from: Currency, to: Currency) -> Decimal? {
    if from == to { return 1 }
    if from == .EUR, to == .PLN { return 4 }
    if from == .PLN, to == .EUR { return Decimal(string: "0.25") }
    return nil
  }
  var latestDay: Day? { Day(year: 2026, month: 3, day: 20) }
}

/// A synthetic database in a temporary file, plus the ids the tests refer to. Never touches the
/// owner's real database.
struct Scratch {
  static let iban = "PL61109010140000071219812874"

  let url: URL
  let main: Account
  let cash: Account
  let euro: Account
  let food: AbacusDomain.Category
  let groceries: AbacusDomain.Category
  let salary: AbacusDomain.Category
  let calendar = Calendar.current

  func day(_ text: String) -> Date { Day(text)!.date(calendar: calendar) }

  static func make() async throws -> Scratch {
    let url = FileManager.default.temporaryDirectory.appending(path: "abacus-mcp-\(UUID().uuidString).sqlite")
    let database = try AbacusDatabase.open(at: url)
    let calendar = Calendar.current
    let opening = Day(year: 2026, month: 1, day: 1).date(calendar: calendar)
    let main = Account(
      name: "Main", currency: .PLN, kind: .bank, openingBalanceMinor: 100_000, openingDate: opening, iban: iban)
    let cash = Account(name: "Cash", currency: .PLN, kind: .cash, openingDate: opening)
    let euro = Account(name: "Euro", currency: .EUR, kind: .savings, openingBalanceMinor: 10_000, openingDate: opening)
    let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
    for account in [main, cash, euro] { try await accounts.save(account) }
    let categories = SQLiteCategoryRepository(database: database)
    let food = AbacusDomain.Category(name: "Food", kind: .expense)
    let groceries = AbacusDomain.Category(name: "Groceries", kind: .expense, parentID: food.id)
    let salary = AbacusDomain.Category(name: "Salary", kind: .income)
    for category in [food, groceries, salary] { try await categories.save(category) }
    let scratch = Scratch(url: url, main: main, cash: cash, euro: euro, food: food, groceries: groceries, salary: salary)

    let txns = SQLiteTxnRepository(database: database, calendar: calendar)
    try await txns.save(
      Txn(type: .income, occurredAt: scratch.day("2026-03-01"), accountID: main.id, amountMinor: 300_000, categoryID: salary.id, payee: "Employer"),
      lines: [])
    try await txns.save(
      Txn(type: .expense, occurredAt: scratch.day("2026-03-05"), accountID: main.id, amountMinor: 5_000, categoryID: groceries.id, payee: "Corner shop"),
      lines: [])
    try await txns.save(
      Txn(type: .expense, occurredAt: scratch.day("2026-03-06"), accountID: main.id, amountMinor: 1_000, payee: "Mystery"),
      lines: [])
    try await txns.save(
      Txn(type: .transfer, occurredAt: scratch.day("2026-03-07"), accountID: main.id, amountMinor: 10_000, toAccountID: cash.id, toAmountMinor: 10_000),
      lines: [])

    let budgets = SQLiteBudgetRepository(database: database)
    let plan = BudgetPlan(effectiveMonth: "2026-03", totalMinor: 0, currency: .PLN)
    try await budgets.save(plan, allocations: [BudgetAllocation(planID: plan.id, categoryID: food.id, limitMinor: 10_000, currency: .PLN)])
    try database.close()
    return scratch
  }

  func queries(today: Day = Day(year: 2026, month: 3, day: 20)) throws -> AbacusQueries {
    AbacusQueries(
      database: try MCPDatabase.openReadOnly(at: url), calendar: calendar, rates: { _ in StubRates() }, today: { today })
  }

  func server(today: Day = Day(year: 2026, month: 3, day: 20)) throws -> MCPServer {
    MCPServer(instructions: "test", tools: ReadTools.all(try queries(today: today)))
  }

  func remove() { try? AbacusDatabase.removeFiles(at: url) }
}

extension MCPServer {
  /// Calls a tool through the JSON-RPC surface; returns the text payload and the error flag.
  func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> (text: String, isError: Bool) {
    let request: JSONValue = [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments],
    ]
    let line = try #require(await handle(line: try request.serialized()))
    let response = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    let result = try #require(response["result"])
    let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
    return (text, result["isError"]?.boolValue ?? false)
  }

  func json(_ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
    let (text, isError) = try await call(name, arguments)
    #expect(!isError, "\(name): \(text)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
