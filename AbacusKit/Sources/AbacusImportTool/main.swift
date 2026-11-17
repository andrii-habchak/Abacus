import AbacusDomain
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData

// Headless import into the app database with the wizard's defaults, for loading real exports
// before the import wizard exists. Prints counts only. Like the wizard it finds the expense an
// incoming row refunds and the estimated transfer a row completes, and accepts those offers.
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
        throw ToolError.usage("--remember-pko expects <CUR>=<account name>")
      }
      options.rememberPKO.append((currency, parts[1]))
    case "--balance-correction":
      let spec = args.popFirst() ?? ""
      guard let eq = spec.lastIndex(of: "="), let at = spec.lastIndex(of: "@"), eq < at,
        let balance = Decimal(string: String(spec[spec.index(after: eq)..<at])),
        let day = Day(String(spec[spec.index(after: at)...]))
      else { throw ToolError.usage("--balance-correction expects <account>=<balance>@<YYYY-MM-DD>") }
      options.corrections.append((String(spec[..<eq]), balance, day))
    case "--dry-run": options.dryRun = true
    default: options.files.append(URL(fileURLWithPath: arg))
    }
  }
  guard !options.files.isEmpty || !options.rememberPKO.isEmpty || !options.corrections.isEmpty else {
    throw ToolError.usage(
      "usage: abacus-import [--db <path>] [--pko-account <name>] [--remember-pko <CUR>=<account>] "
        + "[--balance-correction <account>=<balance>@<day>] [--dry-run] <file>...")
  }
  return options
}

func account(named name: String, in accounts: SQLiteAccountRepository) async throws -> Account {
  guard let account = try await accounts.accounts(includeArchived: true).first(where: { $0.name == name }) else {
    throw ToolError.usage("No account named “\(name)”")
  }
  return account
}

/// A message for stderr. `usage` marks a problem with the arguments (exit status 2); anything
/// else exits with 1. Messages name arguments and files only, never row data.
struct ToolError: Error, CustomStringConvertible {
  let description: String
  let usage: Bool
  init(_ description: String, usage: Bool = false) {
    self.description = description
    self.usage = usage
  }
  static func usage(_ description: String) -> ToolError { ToolError(description, usage: true) }
}

/// Exit status for an error that reached the top level: 2 for usage errors, 1 otherwise.
func exitStatus(for error: Error) -> Int32 {
  (error as? ToolError)?.usage == true ? 2 : 1
}

/// One line for stderr. Errors other than `ToolError` show their type and localized text only.
func message(for error: Error) -> String {
  if let error = error as? ToolError { return error.description }
  return "\(type(of: error)): \(error.localizedDescription)"
}

/// The whole run; every error propagates to the single handler below.
func run() async throws {
  let options = try parseOptions()
  let url = try options.database ?? AbacusDatabase.defaultURL()
  let database = try AbacusDatabase.open(at: url)
  let calendar = Calendar.current
  let accounts = SQLiteAccountRepository(database: database, calendar: calendar)
  let pipeline = ImportPipeline(
    store: SQLiteImportStore(database: database, calendar: calendar), accounts: accounts,
    categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
    rules: SQLiteRuleRepository(database: database), calendar: calendar,
    refunds: SQLiteRefundRepository(database: database, calendar: calendar),
    counterparts: SQLiteTransferCounterpartRepository(database: database, calendar: calendar))
  print("Database: \(url.path)\(options.dryRun ? " (dry run)" : "")")
  /// Set by every committed write; the running app is told once at the end (N2r).
  var wroteDatabase = false

  // Remembered PKO statement accounts per currency (same key the pipeline reads).
  for (currency, name) in options.rememberPKO {
    let target = try await account(named: name, in: accounts)
    guard target.currency == currency else { throw ToolError.usage("“\(name)” is not a \(currency.rawValue) account") }
    print("PKO \(currency.rawValue) statements → \(name)")
    if options.dryRun { continue }
    let key = "statement|\(currency.rawValue)"
    try await database.write { db in
      try ImportMapping.where { $0.source.eq(ImportSource.pko) && $0.kind.eq(MappingKind.account) && $0.externalKey.eq(key) }
        .delete().execute(db)
      try ImportMapping.insert { ImportMapping(source: .pko, kind: .account, externalKey: key, targetID: target.id) }
        .execute(db)
    }
    wroteDatabase = true
  }

  // Balance corrections at the start of a day.
  for correction in options.corrections {
    let target = try await account(named: correction.account, in: accounts)
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
      note: "Aligns the account with the bank statement balance on \(correction.day)", isBalanceCorrection: true)
    try await SQLiteTxnRepository(database: database, calendar: calendar).save(txn, lines: [])
    wroteDatabase = true
    print("  booked a \(kind.rawValue) “Balance correction” on \(correction.day)")
  }

  for file in options.files {
    let data = try Data(contentsOf: file)
    guard let source = ImportPipeline.detect(data) else {
      throw ToolError("\(file.lastPathComponent): not a Saldo or PKO export")
    }
    var target: Account.ID?
    if source == .pko, let name = options.pkoAccountName {
      target = try await account(named: name, in: accounts).id
    }
    let preview: ImportPreview
    do {
      preview = try await pipeline.preview(data: data, fileName: file.lastPathComponent, targetAccountID: target)
    } catch ImportPipelineError.targetAccountRequired {
      throw ToolError.usage("\(file.lastPathComponent): PKO statement needs --pko-account <name> (no remembered account yet)")
    }
    let counts = preview.counts
    print(
      "\(file.lastPathComponent) [\(source.rawValue)]: rows \(preview.rows.count) · new \(counts.new) · already imported \(counts.alreadyImported)"
        + " · possible duplicates \(counts.possibleDuplicate) · settles pending \(counts.settlesPending)"
        + " · needs review \(counts.needsReview) · skipped \(counts.skipped)")
    if source == .pko && preview.targetAccountID == nil {
      throw ToolError.usage("PKO statement needs --pko-account <name> (no remembered account yet)")
    }
    if options.dryRun { continue }
    // Same linking as the wizard's "Accept": refunds of expenses and real figures of estimated
    // transfers; counts only.
    let offers = preview.acceptingOffers()
    let ready = offers.preview.acceptingDefaults()
    print("  offers accepted: refunds \(offers.refunds) · estimated transfers completed \(offers.estimates)")
    guard ready.canCommit else { throw ToolError("Preview still has unresolved choices") }
    let summary = try await pipeline.commit(ready)
    wroteDatabase = true
    print(
      "  committed: created \(summary.created) (paired transfers \(summary.transfersPaired)) · settled \(summary.settled)"
        + " · linked \(summary.linked) · duplicates skipped \(summary.duplicatesSkipped) · reviewed \(summary.reviewedImported)"
        + " · accounts \(summary.accountsCreated) · categories \(summary.categoriesCreated) · rules \(summary.rulesSaved)"
        + " · opening balances \(summary.openingBalancesSet) · with warnings \(summary.warningsKept)")
  }

  let all = try await accounts.accounts(includeArchived: true)
  print("Accounts in database: \(all.count) (\(all.filter(\.isArchived).count) archived)")

  // The running app reloads at once instead of waiting for its file watcher (same Darwin
  // notification as `abacus-mcp`, `DatabaseChangeWatcher.darwinNotificationName`).
  if wroteDatabase && !options.dryRun {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("io.github.andrii-habchak.Abacus.database-changed" as CFString), nil, nil, true)
  }
}

// No error may reach the top level (it would trap and leave a crash report): print one line to
// stderr and exit 2 for usage errors, 1 for anything else.
do {
  try await run()
} catch {
  fflush(nil)  // what was printed so far comes before the error line; `exit` skips no buffers then
  FileHandle.standardError.write(Data("abacus-import: \(message(for: error))\n".utf8))
  exit(exitStatus(for: error))
}
