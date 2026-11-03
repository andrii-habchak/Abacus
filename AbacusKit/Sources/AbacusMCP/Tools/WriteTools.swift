import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// The write tools (D69). Each one validates and describes the change, and `WriteSession` makes
/// it propose-then-confirm. No tool deletes an account, restores a backup or touches settings.
public enum WriteTools {
  public static func all(
    session: WriteSession, rates: @escaping RateSource = { _ in NoRates() }, calendar: Calendar = .current,
    today: @escaping @Sendable () -> Day = { Day(Date()) }
  ) -> [MCPTool] {
    let context = WriteContext(database: session.database, calendar: calendar, rates: rates, today: today)
    let confirm = Schema.string("From the proposal this tool returned; omit it on the first call.")
    func tool(
      _ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = [],
      plan: @escaping @Sendable (Arguments, WriteContext) async throws -> WritePlan
    ) -> MCPTool {
      var properties = properties
      properties["confirm_token"] = confirm
      return MCPTool(
        name: name,
        description: description + " Propose-then-confirm: the first call only describes the change and returns a confirm_token; call again with the same arguments plus the token once the owner has approved.",
        inputSchema: Schema.object(properties, required: required), isWrite: true
      ) { raw in
        try await session.run(tool: name, arguments: raw) {
          do { return try await plan(Arguments(raw), context) } catch { throw describeWriteError(error) }
        }
      }
    }

    let txnFields: [String: JSONValue] = [
      "type": Schema.string("expense, income or transfer", options: ["expense", "income", "transfer"]),
      "date": Schema.string("YYYY-MM-DD"),
      "account": Schema.string("Account name or id (the source account for a transfer)"),
      "amount": Schema.string("Positive decimal in the account's currency, e.g. \"12.50\"; the direction comes from the type"),
      "category": Schema.string("Category name, “Parent › Child” or id; empty string clears it"),
      "to_account": Schema.string("Transfers: the receiving account"),
      "to_amount": Schema.string("Transfers between currencies: the amount received, in the receiving account's currency"),
      "payee": Schema.string("Who was paid / who paid"), "note": Schema.string("Free text"),
      "event": Schema.string("Event name or id; empty string clears it"),
      "is_refund": Schema.boolean("Mark an expense as a refund (money back) or an income as a reversal"),
      "refund_of": Schema.string("Link an expense refund to the expense it refunds (transaction id); empty string unlinks"),
      "original_amount": Schema.string("Amount in the original currency, when it differs from the account's"),
      "original_currency": Schema.string("ISO code of the original currency, e.g. USD"),
      "attached_records": Schema.array(
        of: Schema.object([
          "kind": Schema.string("expense (default) or income", options: ["expense", "income"]),
          "category": Schema.string("Category name or id"), "amount": Schema.string("Positive decimal"),
          "note": Schema.string("Text"),
        ], required: ["amount"]), "Split lines (replaces the existing ones when given)"),
    ]
    let ref = { (name: String, what: String) in [name: Schema.string("\(what) name or id")] }

    return [
      tool("create_transaction", "Adds a transaction (expense, income or transfer).", txnFields, required: ["type", "date", "account", "amount"]) { a, ctx in
        let directory = try await ctx.directory()
        let builder = TransactionBuilder(directory: directory, calendar: ctx.calendar)
        let (txn, lines) = try builder.build(a, base: nil)
        return WritePlan(summary: "Add \(builder.describe(txn))\(lines.isEmpty ? "" : " with \(lines.count) attached record(s)")") {
          try await ctx.txns.save(txn, lines: lines)
          return ["id": .string(txn.id.uuidString)]
        }
      },
      tool(
        "update_transaction", "Changes the given fields of a transaction; fields left out stay as they are.",
        txnFields.merging(["id": Schema.string("Transaction id")]) { $1 }, required: ["id"]
      ) { a, ctx in
        let id = try transactionID(a)
        guard let existing = try await ctx.txns.transaction(id) else { throw RepositoryError.notFound }
        let builder = TransactionBuilder(directory: try await ctx.directory(), calendar: ctx.calendar)
        let updated = try builder.build(a, base: existing)
        let changes = builder.changes(from: existing, to: updated)
        guard !changes.isEmpty else { throw ToolError("Nothing would change.") }
        return WritePlan(summary: "Update \(builder.describe(existing.txn)): " + changes.joined(separator: "; ")) {
          try await ctx.txns.save(updated.txn, lines: updated.lines)
          return ["id": .string(id.uuidString)]
        }
      },
      tool("delete_transaction", "Deletes a transaction with its attached records. Refunds linked to it become unlinked.", ["id": Schema.string("Transaction id")], required: ["id"]) { a, ctx in
        let id = try transactionID(a)
        guard let existing = try await ctx.txns.transaction(id) else { throw RepositoryError.notFound }
        let builder = TransactionBuilder(directory: try await ctx.directory(), calendar: ctx.calendar)
        return WritePlan(summary: "Delete \(builder.describe(existing.txn))") {
          try await ctx.txns.delete(id)
          return ["id": .string(id.uuidString)]
        }
      },

      tool(
        "create_category", "Adds a category (or a subcategory when parent is given; one level only).",
        [
          "name": Schema.string("Category name"), "kind": Schema.string("expense or income", options: ["expense", "income"]),
          "parent": Schema.string("Parent category name or id (top-level, same kind)"),
        ], required: ["name", "kind"]
      ) { a, ctx in
        let name = try a.requiredString("name")
        guard let kind = CategoryKind(rawValue: try a.requiredString("kind")) else { throw ToolError("“kind” must be expense or income") }
        let directory = try await ctx.directory()
        let parent = try a.string("parent").map { try directory.category($0) }
        if let parent {
          guard parent.parentID == nil else { throw ToolError("“\(directory.categoryName(parent.id))” is itself a subcategory; only one level is allowed.") }
          guard parent.kind == kind else { throw ToolError("The parent is an \(parent.kind.rawValue) category; the new one is \(kind.rawValue).") }
        }
        let siblings = directory.categories.filter { $0.parentID == parent?.id && $0.kind == kind }
        let category = AbacusDomain.Category(
          name: name, kind: kind, parentID: parent?.id, position: (siblings.map(\.position).max() ?? -1) + 1)
        return WritePlan(summary: "Add \(kind.rawValue) category “\(parent.map { "\($0.name) › " } ?? "")\(name)”") {
          try await ctx.categories.save(category)
          return ["id": .string(category.id.uuidString)]
        }
      },
      tool(
        "update_category", "Renames, moves, archives or unarchives a category.",
        ref("category", "Category").merging([
          "new_name": Schema.string("New name"),
          "parent": Schema.string("New parent (top-level, same kind); empty string makes it top level"),
          "archived": Schema.boolean("true archives (a parent's subcategories too), false unarchives"),
        ]) { $1 }, required: ["category"]
      ) { a, ctx in
        let directory = try await ctx.directory()
        let existing = try directory.category(try a.requiredString("category"))
        var category = existing
        var changes: [String] = []
        if let name = a.string("new_name"), name != existing.name { category.name = name; changes.append("name → “\(name)”") }
        if a.present("parent") {
          let parent = try a.string("parent").map { try directory.category($0) }
          if parent?.id != existing.parentID { category.parentID = parent?.id; changes.append("parent → \(parent?.name ?? "top level")") }
        }
        let archive = a.bool("archived")
        if let archive, archive != existing.isArchived { changes.append(archive ? "archive" : "unarchive") }
        guard !changes.isEmpty else { throw ToolError("Nothing would change.") }
        let (saved, label) = (category, directory.categoryName(existing.id))
        return WritePlan(summary: "Category “\(label)”: " + changes.joined(separator: "; ")) {
          if saved != existing { try await ctx.categories.save(saved) }
          if let archive, archive != existing.isArchived { try await ctx.categories.setArchived(existing.id, archive) }
          return ["id": .string(existing.id.uuidString)]
        }
      },
      tool(
        "delete_category", "Deletes a category. A category in use needs reassign_to: its transactions, records, rules and limits move there. Its subcategories move to the top level.",
        ref("category", "Category").merging(["reassign_to": Schema.string("Category of the same kind that takes over its records")]) { $1 },
        required: ["category"]
      ) { a, ctx in
        let directory = try await ctx.directory()
        let category = try directory.category(try a.requiredString("category"))
        let target = try a.string("reassign_to").map { try directory.category($0) }
        let impact = try await ctx.categories.reassignImpact(of: category.id)
        let rows = impact.transactions + impact.attachedRecords
        let moved = rows > 0 ? " Moves \(impact.transactions) transaction(s) and \(impact.attachedRecords) attached record(s) to “\(target.map { directory.categoryName($0.id) } ?? "nowhere")”." : ""
        return WritePlan(summary: "Delete category “\(directory.categoryName(category.id))”.\(moved)", rows: rows) {
          try await ctx.categories.delete(category.id, reassignTo: target?.id)
          return ["id": .string(category.id.uuidString)]
        }
      },

      tool(
        "create_account", "Adds an account.",
        [
          "name": Schema.string("Account name"), "currency": Schema.string("EUR, USD, PLN or UAH", options: Currency.allCases.map(\.rawValue)),
          "kind": Schema.string("cash, bank, card, savings, investment, creditCard or loan", options: AccountKind.allCases.filter { $0 != .debt }.map(\.rawValue)),
          "opening_balance": Schema.string("Signed decimal, default 0 (a liability normally opens negative)"),
          "opening_date": Schema.string("YYYY-MM-DD, default today"), "group": Schema.string("Account group name"),
        ], required: ["name", "currency", "kind"]
      ) { a, ctx in
        let name = try a.requiredString("name")
        guard let currency = Currency(rawValue: try a.requiredString("currency").uppercased()) else { throw ToolError("Unknown currency") }
        guard let kind = AccountKind(rawValue: try a.requiredString("kind")), kind != .debt else {
          throw ToolError("“kind” must be one of cash, bank, card, savings, investment, creditCard, loan")
        }
        let opening = try a.string("opening_balance").map { text -> Int64 in
          guard let minor = Amounts.minor(from: text) else { throw ToolError("“opening_balance” must be a decimal with at most 2 places") }
          return minor
        } ?? 0
        let day = try a.string("opening_date").map { text -> Day in
          guard let day = Day(text) else { throw ToolError("“opening_date” must look like 2026-03-31") }
          return day
        } ?? ctx.today()
        let existing = try await ctx.accounts.accounts(includeArchived: true)
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
          throw ToolError("An account named “\(name)” already exists.")
        }
        let groups = try await ctx.accounts.groups()
        let group = try a.string("group").map { reference in
          guard let found = groups.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw ToolError("No account group “\(reference)”")
          }
          return found
        }
        let account = Account(
          name: name, currency: currency, kind: kind, openingBalanceMinor: opening,
          openingDate: day.date(calendar: ctx.calendar), groupID: group?.id,
          position: (existing.filter { $0.groupID == group?.id }.map(\.position).max() ?? -1) + 1)
        return WritePlan(summary: "Add \(kind.rawValue) account “\(name)” in \(currency.rawValue), opening balance \(Amounts.string(minor: opening)) on \(day)") {
          try await ctx.accounts.save(account)
          return ["id": .string(account.id.uuidString)]
        }
      },
      tool(
        "update_account", "Changes an account's name, kind, opening balance/date or group. The currency and the account number cannot be changed here.",
        ref("account", "Account").merging([
          "new_name": Schema.string("New name"),
          "kind": Schema.string("New kind", options: AccountKind.allCases.filter { $0 != .debt }.map(\.rawValue)),
          "opening_balance": Schema.string("Signed decimal"), "opening_date": Schema.string("YYYY-MM-DD"),
          "group": Schema.string("Account group name; empty string removes it from its group"),
        ]) { $1 }, required: ["account"]
      ) { a, ctx in
        let directory = try await ctx.directory()
        let existing = try directory.account(try a.requiredString("account"))
        var account = existing
        var changes: [String] = []
        if let name = a.string("new_name"), name != existing.name {
          account.name = name
          changes.append("name → “\(name)”")
        }
        if let kind = a.string("kind") {
          guard let parsed = AccountKind(rawValue: kind), parsed != .debt else { throw ToolError("Unknown or unsupported kind “\(kind)”") }
          if parsed != existing.kind { account.kind = parsed; changes.append("kind → \(kind)") }
        }
        if let text = a.string("opening_balance") {
          guard let minor = Amounts.minor(from: text) else { throw ToolError("“opening_balance” must be a decimal with at most 2 places") }
          if minor != existing.openingBalanceMinor { account.openingBalanceMinor = minor; changes.append("opening balance → \(text)") }
        }
        if let text = a.string("opening_date") {
          guard let day = Day(text) else { throw ToolError("“opening_date” must look like 2026-03-31") }
          account.openingDate = day.date(calendar: ctx.calendar)
          if account.openingDate != existing.openingDate { changes.append("opening date → \(text)") }
        }
        if a.present("group") {
          let groups = try await ctx.accounts.groups()
          let group = try a.string("group").map { reference in
            guard let found = groups.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
              throw ToolError("No account group “\(reference)”")
            }
            return found
          }
          if group?.id != existing.groupID { account.groupID = group?.id; changes.append("group → \(group?.name ?? "none")") }
        }
        guard !changes.isEmpty else { throw ToolError("Nothing would change.") }
        let saved = account
        return WritePlan(summary: "Account “\(existing.name)”: " + changes.joined(separator: "; ")) {
          try await ctx.accounts.save(saved)
          return ["id": .string(existing.id.uuidString)]
        }
      },
      tool(
        "archive_account", "Archives (or unarchives) an account: it keeps its history but leaves net worth and pickers. Accounts are never deleted through MCP.",
        ref("account", "Account").merging(["archived": Schema.boolean("true (default) archives, false unarchives")]) { $1 },
        required: ["account"]
      ) { a, ctx in
        let directory = try await ctx.directory()
        let account = try directory.account(try a.requiredString("account"))
        let archive = a.bool("archived") ?? true
        guard archive != account.isArchived else { throw ToolError("“\(account.name)” is already \(archive ? "archived" : "active").") }
        let balance = try await ctx.accounts.balances(asOf: ctx.today())[account.id] ?? 0
        let warning = archive && balance != 0 ? " Its balance is \(Amounts.string(minor: balance)) \(account.currency.rawValue), not zero." : ""
        return WritePlan(summary: "\(archive ? "Archive" : "Unarchive") account “\(account.name)”.\(warning)") {
          try await ctx.accounts.setArchived(account.id, archive)
          return ["id": .string(account.id.uuidString)]
        }
      },

      tool("undo_import", "Undoes an import: removes the transactions (and accounts, categories, events it created if unused) of one import batch. Use list_imports for ids.", ["batch_id": Schema.string("Import batch id")], required: ["batch_id"]) { a, ctx in
        let id = try batchID(a)
        guard let batch = try await ctx.imports.batches().first(where: { $0.id == id }) else { throw RepositoryError.notFound }
        guard !batch.isUndone else { throw ToolError("This import is already undone.") }
        let count = try await ctx.imports.transactionCounts()[id] ?? 0
        return WritePlan(summary: "Undo the import of “\(batch.fileName)” (\(batch.importedAt.formatted(date: .abbreviated, time: .omitted))): removes \(count) transaction(s)", rows: count) {
          try await ctx.imports.undo(id)
          return ["batch_id": .string(id.uuidString)]
        }
      },
      tool(
        "move_import", "Moves a PKO statement import's transactions to another account of the same currency (the movable ones; the plan lists what stays).",
        ["batch_id": Schema.string("Import batch id"), "to_account": Schema.string("Target account name or id")], required: ["batch_id", "to_account"]
      ) { a, ctx in
        let id = try batchID(a)
        let directory = try await ctx.directory()
        let target = try directory.account(try a.requiredString("to_account"))
        let plan = try await ctx.imports.movePlan(id)
        let source = directory.accounts.first { $0.id == plan.sourceAccountID }
        guard target.id != plan.sourceAccountID, !target.isArchived, target.kind != .debt, target.currency == source?.currency else {
          throw ToolError("The target must be another active account in \(source?.currency.rawValue ?? "the same currency").")
        }
        let movable = plan.candidates.filter { $0.refusal(movingTo: target.id) == nil }.map(\.txn.id)
        guard !movable.isEmpty else { throw ToolError("None of this import's transactions can move to “\(target.name)”.") }
        let staying = plan.candidates.count - movable.count
        return WritePlan(
          summary: "Move \(movable.count) transaction(s) of “\(plan.batch.fileName)” from “\(directory.accountName(plan.sourceAccountID))” to “\(target.name)”\(staying > 0 ? "; \(staying) stay" : "")",
          rows: movable.count
        ) {
          let result = try await ctx.imports.move(id, txnIDs: movable, to: target.id)
          return ["moved": .int(Int64(result.txnIDs.count))]
        }
      },
    ]
  }

  static func transactionID(_ a: Arguments) throws -> UUID {
    guard let id = UUID(uuidString: try a.requiredString("id")) else { throw ToolError("“id” must be a transaction id") }
    return id
  }

  static func batchID(_ a: Arguments) throws -> UUID {
    guard let id = UUID(uuidString: try a.requiredString("batch_id")) else { throw ToolError("“batch_id” must be an import batch id") }
    return id
  }
}
