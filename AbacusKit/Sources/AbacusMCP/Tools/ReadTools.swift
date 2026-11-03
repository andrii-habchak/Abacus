import AbacusDomain
import Foundation

/// The read tools: thin shells that parse arguments, call `AbacusQueries` and return its DTO.
public enum ReadTools {
  public static func all(_ queries: AbacusQueries) -> [MCPTool] {
    let currency = Schema.string("Currency for converted totals: EUR, USD, PLN or UAH. Default: the app's display currency.")
    let day = "YYYY-MM-DD"
    return [
      MCPTool(
        name: "net_worth",
        description: "Net worth today: assets, liabilities and total in one currency, with every account's balance. Archived accounts are left out; debts flagged “count in net worth” are included.",
        inputSchema: Schema.object(["currency": currency])
      ) { args in
        try .encoding(await queries.netWorth(currency: Arguments(args).string("currency")))
      },
      MCPTool(
        name: "spending_by_category",
        description: "Expenses (or income) by category with subcategories and shares, for one month or a day range. Refunds follow the app's setting. Start here for “where did my money go”.",
        inputSchema: Schema.object([
          "month": Schema.string("Month, YYYY-MM. Use this or from/to."),
          "from": Schema.string("First day, \(day)"), "to": Schema.string("Last day, \(day) (inclusive)"),
          "kind": Schema.string("expense (default) or income", options: ["expense", "income"]),
          "currency": currency,
        ])
      ) { args in
        let a = Arguments(args)
        let kind = CategoryKind(rawValue: a.string("kind") ?? "expense") ?? .expense
        return try .encoding(
          await queries.spendingByCategory(
            kind: kind, month: a.string("month"), from: a.string("from"), to: a.string("to"),
            currency: a.string("currency")))
      },
      MCPTool(
        name: "cash_flow",
        description: "Income, expenses and net over a day range, in total and per month. Transfers between own accounts count as neither.",
        inputSchema: Schema.object(
          ["from": Schema.string("First day, \(day)"), "to": Schema.string("Last day, \(day)"), "currency": currency],
          required: ["from", "to"])
      ) { args in
        let a = Arguments(args)
        return try .encoding(
          await queries.cashFlow(from: a.requiredString("from"), to: a.requiredString("to"), currency: a.string("currency")))
      },
      MCPTool(
        name: "budget_status",
        description: "The budget in effect for a month: limit, spent and status overall and per category. Returns null when no budget exists.",
        inputSchema: Schema.object(["month": Schema.string("Month, YYYY-MM. Default: this month."), "currency": currency])
      ) { args in
        let a = Arguments(args)
        return try .encoding(await queries.budgetStatus(month: a.string("month"), currency: a.string("currency")))
      },
      MCPTool(
        name: "search_transactions",
        description: "Lists transactions matching filters, newest first, at most \(AbacusQueries.searchCap) rows per call (the result says how many matched in all). Prefer the aggregate tools; use this to inspect specific rows. Descriptions (payee, note) are included.",
        inputSchema: Schema.object([
          "from": Schema.string("First day, \(day)"), "to": Schema.string("Last day, \(day)"),
          "accounts": Schema.array(of: ["type": "string"], "Account names or ids; a transfer matches either side"),
          "categories": Schema.array(of: ["type": "string"], "Category names, “Parent › Child”, or ids; a parent includes its subcategories"),
          "types": Schema.array(of: ["type": "string"], "expense, income and/or transfer"),
          "event": Schema.string("Event name or id"),
          "text": Schema.string("Case-insensitive text in the payee or note"),
          "limit": Schema.integer("Rows to return, 1–\(AbacusQueries.searchCap), default 50"),
          "offset": Schema.integer("Rows to skip, to page through a larger result"),
          "oldest_first": Schema.boolean("Sort oldest first"),
        ])
      ) { args in
        try .encoding(await queries.searchTransactions(filter(from: Arguments(args))))
      },
      MCPTool(
        name: "get_transaction", description: "One transaction with its attached records, by id.",
        inputSchema: Schema.object(["id": Schema.string("Transaction id")], required: ["id"])
      ) { args in
        guard let found = try await queries.transaction(id: Arguments(args).requiredString("id")) else {
          throw ToolError("No transaction with that id")
        }
        return try .encoding(found)
      },
      MCPTool(
        name: "uncategorised_transactions",
        description: "Expenses and income that have no category yet (transfers excluded), newest first, capped like search_transactions.",
        inputSchema: Schema.object([
          "from": Schema.string("First day, \(day)"), "to": Schema.string("Last day, \(day)"),
          "limit": Schema.integer("Rows to return, 1–\(AbacusQueries.searchCap), default 50"),
        ])
      ) { args in
        let a = Arguments(args)
        return try .encoding(await queries.uncategorised(from: a.string("from"), to: a.string("to"), limit: a.int("limit")))
      },
      MCPTool(
        name: "list_accounts",
        description: "Accounts with kind, currency and today's balance in the account's own currency. No account numbers or IBANs.",
        inputSchema: Schema.object(["include_archived": Schema.boolean("Also list archived accounts")])
      ) { args in
        try .encoding(await queries.accounts(includeArchived: Arguments(args).bool("include_archived") ?? false))
      },
      MCPTool(
        name: "list_categories", description: "Categories with kind (expense/income) and parent.",
        inputSchema: Schema.object(["include_archived": Schema.boolean("Also list archived categories")])
      ) { args in
        try .encoding(await queries.categories(includeArchived: Arguments(args).bool("include_archived") ?? false))
      },
      MCPTool(
        name: "debts",
        description: "Open debts per person (positive = they owe the owner, negative = the owner owes them), balances per currency, plus totals in one currency.",
        inputSchema: Schema.object(["currency": currency])
      ) { args in
        try .encoding(await queries.debts(currency: Arguments(args).string("currency")))
      },
      MCPTool(
        name: "exchange_rates",
        description: "The latest known exchange rates into a currency (1 unit of the other currency = rate units of it), with the day they are from.",
        inputSchema: Schema.object(["currency": currency])
      ) { args in
        try .encoding(await queries.rates(currency: Arguments(args).string("currency")))
      },
    ]
  }

  static func filter(from a: Arguments) -> TransactionFilter {
    var filter = TransactionFilter()
    filter.from = a.string("from")
    filter.to = a.string("to")
    filter.accounts = a.strings("accounts")
    filter.categories = a.strings("categories")
    filter.types = a.strings("types")
    filter.event = a.string("event")
    filter.text = a.string("text")
    filter.limit = a.int("limit")
    filter.offset = a.int("offset") ?? 0
    filter.newestFirst = !(a.bool("oldest_first") ?? false)
    return filter
  }
}
