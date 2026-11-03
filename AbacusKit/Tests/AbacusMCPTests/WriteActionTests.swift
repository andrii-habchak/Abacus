import AbacusDomain
import AbacusMCP
import AbacusStore
import Foundation
import Testing

@Suite("MCP · write tools")
struct WriteActionTests {
  @Test("R-TX-1: create, update and delete a transaction; update says what changes")
  func transactionLifecycle() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let created = try await rig.write(
      "create_transaction",
      ["type": "expense", "date": "2026-03-10", "account": "Main", "amount": "12.50", "category": "Groceries", "payee": "Bakery"])
    let id = try #require(created["result"]?["id"]?.stringValue)
    let stored = try await rig.reader.json("get_transaction", ["id": .string(id)])
    #expect(stored["amount"]?["amount"]?.stringValue == "12.50")
    #expect(stored["category"]?.stringValue == "Food › Groceries")
    #expect(stored["source"]?.stringValue == "manual")

    let proposal = try await rig.server.json("update_transaction", ["id": .string(id), "amount": "15.00", "note": "fresh"])
    let summary = try #require(proposal["summary"]?.stringValue)
    #expect(summary.contains("amount: 12.50 → 15.00") && summary.contains("note: – → fresh"))
    let updated = try await rig.write("update_transaction", ["id": .string(id), "amount": "15.00", "category": ""])
    #expect(updated["status"]?.stringValue == "done")
    let after = try await rig.reader.json("get_transaction", ["id": .string(id)])
    #expect(after["amount"]?["amount"]?.stringValue == "15.00")
    #expect(after["category"] == nil || after["category"] == .null)

    #expect(try await rig.server.call("update_transaction", ["id": .string(id)]).isError, "no change is an error")
    _ = try await rig.write("delete_transaction", ["id": .string(id)])
    #expect(try await rig.reader.call("get_transaction", ["id": .string(id)]).isError)
    #expect(try await rig.transactionCount() == 4)
  }

  @Test("R-TX-5, R-EDIT: transfers need two accounts; another currency needs the received amount")
  func transfers() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let missing = try await rig.server.call(
      "create_transaction", ["type": "transfer", "date": "2026-03-10", "account": "Main", "amount": "40.00", "to_account": "Euro"])
    #expect(missing.isError && missing.text.contains("to_amount"))
    let same = try await rig.server.call(
      "create_transaction", ["type": "transfer", "date": "2026-03-10", "account": "Main", "amount": "40.00", "to_account": "Main"])
    #expect(same.isError)
    _ = try await rig.write(
      "create_transaction",
      ["type": "transfer", "date": "2026-03-10", "account": "Main", "amount": "40.00", "to_account": "Euro", "to_amount": "10.00"])
    let accounts = try await rig.reader.json("list_accounts")
    let euro = try #require(accounts.arrayValue?.first { $0["name"]?.stringValue == "Euro" })
    #expect(euro["balance"]?["amount"]?.stringValue == "110.00")
  }

  @Test("Validation: category kind must match the type, amounts are positive decimals, archived accounts refused")
  func validation() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let base: [String: JSONValue] = ["type": "expense", "date": "2026-03-10", "account": "Main", "amount": "5.00"]
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["category": "Salary"]) { $1 })).isError)
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["amount": "-5"]) { $1 })).isError)
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["amount": "1.234"]) { $1 })).isError)
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["date": "March"]) { $1 })).isError)
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["account": "Nowhere"]) { $1 })).isError)
    _ = try await rig.write("archive_account", ["account": "Cash"])
    #expect(try await rig.server.call("create_transaction", .object(base.merging(["account": "Cash"]) { $1 })).isError)
  }

  @Test("R-TX-6: attached records are stored and shown")
  func attachedRecords() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let created = try await rig.write(
      "create_transaction",
      [
        "type": "expense", "date": "2026-03-11", "account": "Main", "amount": "30.00", "category": "Food",
        "attached_records": [["kind": "expense", "category": "Groceries", "amount": "5.00", "note": "bag"]],
      ])
    let id = try #require(created["result"]?["id"]?.stringValue)
    let stored = try await rig.reader.json("get_transaction", ["id": .string(id)])
    #expect(stored["attachedRecords"]?.arrayValue?.first?["amount"]?["amount"]?.stringValue == "5.00")
  }

  @Test("R-CAT-3: a category in use needs a reassignment target; subcategories stay one level deep")
  func categories() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let created = try await rig.write("create_category", ["name": "Bakery", "kind": "expense", "parent": "Food"])
    #expect(created["status"]?.stringValue == "done")
    let names = try await rig.reader.json("list_categories").arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    #expect(names.contains("Bakery"))
    #expect(try await rig.server.call("create_category", ["name": "Deep", "kind": "expense", "parent": "Groceries"]).isError)

    let inUse = try await rig.server.call("delete_category", ["category": "Groceries"])
    let proposal = try await rig.server.json("delete_category", ["category": "Groceries", "reassign_to": "Food"])
    #expect(proposal["status"]?.stringValue == "proposed")
    // The proposal call for an in-use category without a target proposes fine, the confirmed call is refused.
    #expect(!inUse.isError)
    var args: [String: JSONValue] = ["category": "Groceries"]
    args["confirm_token"] = (try await rig.server.json("delete_category", .object(args)))["confirm_token"]
    #expect(try await rig.server.call("delete_category", .object(args)).isError)
    _ = try await rig.write("delete_category", ["category": "Groceries", "reassign_to": "Food"])
    let moved = try await rig.reader.json("search_transactions", ["text": "corner"])
    #expect(moved["transactions"]?.arrayValue?.first?["category"]?.stringValue == "Food")

    _ = try await rig.write("update_category", ["category": "Bakery", "new_name": "Bread", "archived": true])
    let all = try await rig.reader.json("list_categories", ["include_archived": true]).arrayValue ?? []
    let bread = try #require(all.first { $0["name"]?.stringValue == "Bread" })
    #expect(bread["isArchived"]?.boolValue == true)
  }

  @Test("R-ACC-5: accounts are created, updated and archived; never deleted; the IBAN is untouched")
  func accounts() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let created = try await rig.write(
      "create_account", ["name": "Savings jar", "currency": "EUR", "kind": "savings", "opening_balance": "250.00", "opening_date": "2026-03-01"])
    #expect(created["status"]?.stringValue == "done")
    #expect(try await rig.server.call("create_account", ["name": "savings JAR", "currency": "EUR", "kind": "savings"]).isError)
    let renamed = try await rig.write("update_account", ["account": "Savings jar", "new_name": "Rainy day"])
    #expect(renamed["status"]?.stringValue == "done")
    let proposal = try await rig.server.json("archive_account", ["account": "Main"])
    #expect(proposal["summary"]?.stringValue?.contains("not zero") == true)
    _ = try await rig.write("archive_account", ["account": "Rainy day"])
    let active = try await rig.reader.json("list_accounts").arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    #expect(!active.contains("Rainy day"))
    let database = try MCPDatabase.openReadOnly(at: rig.scratch.url)
    let iban = try await database.read { try String.fetchOne($0, sql: #"SELECT iban FROM accounts WHERE name = 'Main'"#) }
    #expect(iban == Scratch.iban)
  }

  @Test("R-IMP-6: undo an import removes its transactions")
  func undoImport() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let batch = try await Importer.seed(rig.scratch, rows: 2)
    #expect(try await rig.transactionCount() == 6)
    let imports = try await rig.reader.json("list_imports")
    #expect(imports.arrayValue?.first?["transactions"]?.intValue == 2)
    _ = try await rig.write("undo_import", ["batch_id": .string(batch.uuidString)])
    #expect(try await rig.transactionCount() == 4)
    #expect(try await rig.server.call("undo_import", ["batch_id": .string(batch.uuidString)]).isError, "already undone")
  }

  @Test("C44: move an import to another account of the same currency")
  func moveImport() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let batch = try await Importer.seed(rig.scratch, source: .pko, accountID: rig.scratch.main.id, rows: 1)
    let moved = try await rig.write("move_import", ["batch_id": .string(batch.uuidString), "to_account": "Cash"])
    #expect(moved["result"]?["moved"]?.intValue == 1)
    let rows = try await rig.reader.json("search_transactions", ["text": "Imported"])
    #expect(rows["transactions"]?.arrayValue?.first?["account"]?.stringValue == "Cash")
    // Another currency is refused.
    let other = try await Importer.seed(rig.scratch, source: .pko, accountID: rig.scratch.main.id, rows: 1)
    #expect(try await rig.server.call("move_import", ["batch_id": .string(other.uuidString), "to_account": "Euro"]).isError)
  }

  @Test("R-TX-4: a refund links to its original and stays within it")
  func refunds() async throws {
    let rig = try await WriteRig()
    defer { rig.remove() }
    let original = try await rig.reader.json("search_transactions", ["text": "corner"])
    let originalID = try #require(original["transactions"]?.arrayValue?.first?["id"]?.stringValue)
    let refund = try await rig.write(
      "create_transaction",
      ["type": "expense", "is_refund": true, "refund_of": .string(originalID), "date": "2026-03-12", "account": "Main", "amount": "10.00", "category": "Groceries"])
    let id = try #require(refund["result"]?["id"]?.stringValue)
    #expect(try await rig.reader.json("get_transaction", ["id": .string(id)])["refundOf"]?.stringValue == originalID)
    let tooMuch = try await rig.server.json(
      "create_transaction",
      ["type": "expense", "is_refund": true, "refund_of": .string(originalID), "date": "2026-03-13", "account": "Main", "amount": "100.00", "category": "Groceries"])
    var args: [String: JSONValue] = [
      "type": "expense", "is_refund": true, "refund_of": .string(originalID), "date": "2026-03-13", "account": "Main", "amount": "100.00", "category": "Groceries",
    ]
    args["confirm_token"] = tooMuch["confirm_token"]
    let rejected = try await rig.server.call("create_transaction", .object(args))
    #expect(rejected.isError && rejected.text.contains("exceed"), "\(rejected.text)")
  }
}
