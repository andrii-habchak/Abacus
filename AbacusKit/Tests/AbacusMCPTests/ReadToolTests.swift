import AbacusDomain
import AbacusMCP
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("MCP · read tools on a synthetic database")
struct ReadToolTests {
  @Test("R-HOME-1: net worth sums account balances at the rates, left-out amounts are reported")
  func netWorth() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let server = try scratch.server()
    // Main 1000 + 3000 − 50 − 10 − 100 = 3840; Cash 100; Euro 100 EUR = 400 PLN.
    let result = try await server.json("net_worth", ["currency": "PLN"])
    #expect(result["total"]?["amount"]?.stringValue == "4340.00")
    #expect(result["total"]?["currency"]?.stringValue == "PLN")
    #expect(result["unconverted"]?["count"]?.intValue == 0)
    // USD has no rate in the stub: every foreign amount is left out, never converted at 1.
    let usd = try await server.json("net_worth", ["currency": "USD"])
    #expect((usd["unconverted"]?["count"]?.intValue ?? 0) > 0)
  }

  @Test("R-HOME-3: spending by category shows subcategories and uncategorised")
  func spending() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let result = try await scratch.server().json("spending_by_category", ["month": "2026-03", "currency": "PLN"])
    #expect(result["total"]?["amount"]?.stringValue == "60.00")
    let names = result["categories"]?.arrayValue?.compactMap { $0["category"]?.stringValue } ?? []
    #expect(names.contains("Food"))
    #expect(names.contains("Uncategorised"))
    let food = try #require(result["categories"]?.arrayValue?.first { $0["category"]?.stringValue == "Food" })
    #expect(food["total"]?["amount"]?.stringValue == "50.00")
    #expect(food["subcategories"]?.arrayValue?.first?["category"]?.stringValue == "Groceries")
  }

  @Test("R-HOME-6: cash flow totals and per-month rows; transfers count as neither")
  func cashFlow() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let result = try await scratch.server().json(
      "cash_flow", ["from": "2026-03-01", "to": "2026-03-31", "currency": "PLN"])
    #expect(result["income"]?["amount"]?.stringValue == "3000.00")
    #expect(result["expense"]?["amount"]?.stringValue == "60.00")
    #expect(result["net"]?["amount"]?.stringValue == "2940.00")
    #expect(result["months"]?.arrayValue?.count == 1)
  }

  @Test("R-BUD-1: budget status against the plan in effect; null without a plan")
  func budget() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let server = try scratch.server()
    let result = try await server.json("budget_status", ["month": "2026-03", "currency": "PLN"])
    #expect(result["limit"]?["amount"]?.stringValue == "100.00")
    #expect(result["spent"]?["amount"]?.stringValue == "50.00")
    #expect(result["status"]?.stringValue == "ok")
    let before = try await server.json("budget_status", ["month": "2025-12"])
    #expect(before == .null)
  }

  @Test("R-LIST-1: search filters by text and category; the cap holds")
  func search() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let server = try scratch.server()
    let all = try await server.json("search_transactions", ["from": "2026-03-01", "to": "2026-03-31"])
    #expect(all["matching"]?.intValue == 4)
    let shop = try await server.json("search_transactions", ["text": "corner"])
    #expect(shop["returned"]?.intValue == 1)
    #expect(shop["transactions"]?.arrayValue?.first?["category"]?.stringValue == "Food › Groceries")
    let food = try await server.json("search_transactions", ["categories": ["Food"]])
    #expect(food["returned"]?.intValue == 1)
    let capped = try await server.json("search_transactions", ["limit": 2])
    #expect(capped["returned"]?.intValue == 2)
    #expect(capped["truncated"]?.boolValue == true)
    let huge = try await server.json("search_transactions", ["limit": 100_000])
    #expect((huge["returned"]?.intValue ?? 0) <= AbacusQueries.searchCap)
    let bad = try await server.call("search_transactions", ["accounts": ["Nowhere"]])
    #expect(bad.isError)
  }

  @Test("Uncategorised lists only rows without a category, transfers excluded")
  func uncategorised() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let result = try await scratch.server().json("uncategorised_transactions")
    #expect(result["matching"]?.intValue == 1)
    #expect(result["transactions"]?.arrayValue?.first?["payee"]?.stringValue == "Mystery")
  }

  @Test("Accounts, categories, debts and rates answer; rates report the day they are from")
  func lists() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let server = try scratch.server()
    let accounts = try await server.json("list_accounts")
    let main = try #require(accounts.arrayValue?.first { $0["name"]?.stringValue == "Main" })
    #expect(main["balance"]?["amount"]?.stringValue == "3840.00")
    #expect(try await server.json("list_categories").arrayValue?.count == 3)
    #expect(try await server.json("debts")["people"]?.arrayValue?.isEmpty == true)
    let rates = try await server.json("exchange_rates", ["currency": "PLN"])
    #expect(rates["asOf"]?.stringValue == "2026-03-20")
    #expect(rates["rates"]?.arrayValue?.first?["rate"]?.stringValue == "4")
  }

  @Test("R-NF-6: no IBAN or account number appears in any read tool's output")
  func noIBAN() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let server = try scratch.server()
    for name in ["net_worth", "list_accounts", "search_transactions", "debts", "list_categories"] {
      let (text, _) = try await server.call(name, ["include_archived": true])
      #expect(!text.contains(Scratch.iban), "\(name) leaked the IBAN")
      #expect(!text.contains("iban"), "\(name) exposes an iban field")
    }
  }

  @Test("The read connection cannot write")
  func readOnly() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let database = try MCPDatabase.openReadOnly(at: scratch.url)
    await #expect(throws: (any Error).self) {
      try await database.write { try $0.execute(sql: #"DELETE FROM "txns""#) }
    }
    #expect(try MCPDatabase.schemaState(database) == .current)
  }

  @Test("A missing database is a clear error, not a created file")
  func missing() {
    let url = FileManager.default.temporaryDirectory.appending(path: "abacus-mcp-missing-\(UUID().uuidString).sqlite")
    #expect(throws: ToolError.self) { try MCPDatabase.openReadOnly(at: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}
