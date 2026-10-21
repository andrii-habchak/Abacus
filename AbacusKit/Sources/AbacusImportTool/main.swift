import AbacusDomain
import AbacusImport
import AbacusStore
import Foundation

// Headless import into the app database with the wizard's defaults, for loading real exports
// before the import wizard exists. Prints counts only.
//
//   abacus-import [--db <path>] [--pko-account <name>] [--dry-run] <file>...
//
// Saldo files need no options. A PKO statement goes into `--pko-account` (an existing account
// name), else into the account remembered from the last PKO import of that currency.

struct Options {
  var database: URL?
  var pkoAccountName: String?
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
    case "--dry-run": options.dryRun = true
    default: options.files.append(URL(fileURLWithPath: arg))
    }
  }
  guard !options.files.isEmpty else {
    throw ToolError("usage: abacus-import [--db <path>] [--pko-account <name>] [--dry-run] <file>...")
  }
  return options
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
