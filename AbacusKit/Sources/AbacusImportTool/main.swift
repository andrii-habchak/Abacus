import AbacusDomain
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData

// Headless import into the app database with the wizard's defaults, for loading real exports
// before the import wizard exists. Prints counts only.
//
//   abacus-import [--db <path>] [--pko-account <name>] [--remember-pko <CUR>=<account>]...
//                 [--balance-correction <account>=<balance>@<YYYY-MM-DD>]... [--dry-run] <file>...
//
// Saldo files need no options. A PKO statement goes into `--pko-account` (an existing account
// name), else into the account remembered for the statement's currency. `--remember-pko` sets
// that remembered account per currency. `--balance-correction` books a "Balance correction"
// income/expense at the start of the day so the account's balance there equals `<balance>`.

struct Options {
  var database: URL?
  var pkoAccountName: String?
  var rememberPKO: [(Currency, String)] = []
  var corrections: [(account: String, balance: Decimal, day: Day)] = []
  var dryRun = false
  var files: [URL] = []
}

func parseOptions() throws -> Options {
  var options = Options()
  var args = CommandLine.arguments.dropFirst()
  while let arg = args.popFirst() {
    switch arg {
    case "--db": options.database = args.popFirst().map { URL(fileURLWithPath: $0) }
    case "--pko-account": options.pkoAccountName = args.popFirst()
    case "--remember-pko":
      let parts = (args.popFirst() ?? "").split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, let currency = Currency(rawValue: parts[0]) else {
        throw ToolError("--remember-pko expects <CUR>=<account name>")
      }
      options.rememberPKO.append((currency, parts[1]))
    case "--balance-correction":
      let spec = args.popFirst() ?? ""
      guard let eq = spec.lastIndex(of: "="), let at = spec.lastIndex(of: "@"), eq < at,
        let balance = Decimal(string: String(spec[spec.index(after: eq)..<at])),
        let day = Day(String(spec[spec.index(after: at)...]))
      else { throw ToolError("--balance-correction expects <account>=<balance>@<YYYY-MM-DD>") }
      options.corrections.append((String(spec[..<eq]), balance, day))
    case "--dry-run": options.dryRun = true
    default: options.files.append(URL(fileURLWithPath: arg))
    }
  }
  guard !options.files.isEmpty || !options.rememberPKO.isEmpty || !options.corrections.isEmpty else {
    throw ToolError(
      "usage: abacus-import [--db <path>] [--pko-account <name>] [--remember-pko <CUR>=<account>] "
        + "[--balance-correction <account>=<balance>@<day>] [--dry-run] <file>...")
  }
  return options
}

func account(named name: String) async throws -> Account {
  guard let account = try await accounts.accounts(includeArchived: true).first(where: { $0.name == name }) else {
    throw ToolError("No account named “\(name)”")
  }
  return account
}

struct ToolError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

let options = try parseOptions()
let url = try options.database ?? AbacusDatabase.defaultURL()
let database = try AbacusDatabase.open(at: url)
let calendar = Calendar.current
let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
let pipeline = ImportPipeline(
  store: SQLiteImportStore(database: database, calendar: calendar), accounts: accounts,
  categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
  rules: SQLiteRuleRepository(database: database), calendar: calendar)
print("Database: \(url.path)\(options.dryRun ? " (dry run)" : "")")

// Remembered PKO statement accounts per currency (same key the pipeline reads).
for (currency, name) in options.rememberPKO {
  let target = try await account(named: name)
  guard target.currency == currency else { throw ToolError("“\(name)” is not a \(currency.rawValue) account") }
  print("PKO \(currency.rawValue) statements → \(name)")
  if options.dryRun { continue }
  let key = "statement|\(currency.rawValue)"
  try await database.write { db in
    try ImportMapping.where { $0.source.eq(ImportSource.pko) && $0.kind.eq(MappingKind.account) && $0.externalKey.eq(key) }
      .delete().execute(db)
    try ImportMapping.insert { ImportMapping(source: .pko, kind: .account, externalKey: key, targetID: target.id) }
      .execute(db)
  }
}

// Balance corrections at the start of a day.
for correction in options.corrections {
  let target = try await account(named: correction.account)
  let before = try await accounts.balances(asOf: correction.day.adding(days: -1, calendar: calendar))[target.id] ?? 0
  let wanted = Money(correction.balance, target.currency).minorUnits
  let difference = wanted - before
  print("\(target.name): balance before \(correction.day) differs from the target by \(Money(minorUnits: difference, currency: target.currency).decimal) \(target.currency.rawValue)")
  if difference == 0 || options.dryRun { continue }
  let kind: CategoryKind = difference > 0 ? .income : .expense
  let categories = SQLiteCategoryRepository(database: database)
  guard let category = try await categories.categories(kind: kind, includeArchived: true).first(where: { $0.name == "Balance correction" })
  else { throw ToolError("No “Balance correction” \(kind.rawValue) category") }
  let txn = Txn(
    type: kind == .income ? .income : .expense, occurredAt: correction.day.date(calendar: calendar),
    accountID: target.id, amountMinor: abs(difference), categoryID: category.id, payee: "Balance correction",
    note: "Aligns the account with the bank statement balance on \(correction.day)")
  try await SQLiteTxnRepository(database: database, calendar: calendar).save(txn, lines: [])
  print("  booked a \(kind.rawValue) “Balance correction” on \(correction.day)")
}

for file in options.files {
  let data = try Data(contentsOf: file)
  guard let source = ImportPipeline.detect(data) else {
    throw ToolError("\(file.lastPathComponent): not a Saldo or PKO export")
  }
  var target: Account.ID?
  if source == .pko, let name = options.pkoAccountName {
    guard let account = try await accounts.accounts(includeArchived: true).first(where: { $0.name == name }) else {
      throw ToolError("No account named “\(name)”")
    }
    target = account.id
  }
  let preview = try await pipeline.preview(data: data, fileName: file.lastPathComponent, targetAccountID: target)
  let counts = preview.counts
  print(
    "\(file.lastPathComponent) [\(source.rawValue)]: rows \(preview.rows.count) · new \(counts.new) · already imported \(counts.alreadyImported)"
      + " · possible duplicates \(counts.possibleDuplicate) · settles pending \(counts.settlesPending)"
      + " · needs review \(counts.needsReview) · skipped \(counts.skipped)")
  if source == .pko && preview.targetAccountID == nil {
    throw ToolError("PKO statement needs --pko-account <name> (no remembered account yet)")
  }
  if options.dryRun { continue }
  let ready = preview.acceptingDefaults()
  guard ready.canCommit else { throw ToolError("Preview still has unresolved choices") }
  let summary = try await pipeline.commit(ready)
  print(
    "  committed: created \(summary.created) (paired transfers \(summary.transfersPaired)) · settled \(summary.settled)"
      + " · linked \(summary.linked) · duplicates skipped \(summary.duplicatesSkipped) · reviewed \(summary.reviewedImported)"
      + " · accounts \(summary.accountsCreated) · categories \(summary.categoriesCreated) · rules \(summary.rulesSaved)"
      + " · opening balances \(summary.openingBalancesSet) · with warnings \(summary.warningsKept)")
}

let all = try await accounts.accounts(includeArchived: true)
print("Accounts in database: \(all.count) (\(all.filter(\.isArchived).count) archived)")
