import AbacusDomain
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData

/// What the import wizard needs: the pipeline (which carries the repositories) and a way to
/// read the chosen file. The app passes `live(database:)`; previews use `preview()`.
public struct ImportWizardDependencies: Sendable {
  public var pipeline: ImportPipeline
  /// Reads a file picked in the open panel or dropped on the window.
  public var readFile: @Sendable (URL) throws -> Data

  public init(pipeline: ImportPipeline, readFile: @escaping @Sendable (URL) throws -> Data = Self.readSecurityScoped) {
    self.pipeline = pipeline
    self.readFile = readFile
  }

  public var calendar: Calendar { pipeline.calendar }

  /// Reads a URL the user picked, inside its security scope when it has one.
  public static let readSecurityScoped: @Sendable (URL) throws -> Data = { url in
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
  }

  /// The pipeline on the SQLite store of `database` (the app's database, or an in-memory one).
  public static func live(
    database: any DatabaseWriter, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
    converter: @escaping @Sendable () async -> (any CurrencyConverter)? = { nil }
  ) -> ImportWizardDependencies {
    ImportWizardDependencies(
      pipeline: ImportPipeline(
        store: SQLiteImportStore(database: database, calendar: calendar),
        accounts: SQLiteAccountRepository(database: database, calendar: calendar),
        categories: SQLiteCategoryRepository(database: database),
        events: SQLiteEventRepository(database: database),
        rules: SQLiteRuleRepository(database: database, calendar: calendar),
        calendar: calendar, now: now, converter: converter))
  }
}

// MARK: - Preview world

extension ImportWizardDependencies {
  /// The preview world of the import screens: `PreviewData` in an in-memory database, the
  /// synthetic categorisation rules of `ImportSamples.rules`, and an import history (an earlier
  /// PKO statement imported, an old Saldo import undone). Import `ImportSamples.pko` or
  /// `ImportSamples.saldo` into it to see every row status, mapping and review case.
  public static func preview(calendar: Calendar = .current) async throws -> ImportWizardDependencies {
    let database = try PreviewData.database()
    let rules = SQLiteRuleRepository(database: database)
    for rule in ImportSamples.rules { try await rules.save(rule) }

    // An earlier statement: its Auchan purchase linked to the manual one, so the new statement
    // shows that row as already imported.
    let earlier = live(database: database, calendar: calendar, now: { ImportSamples.at("2026-09-30", "09:12", calendar) })
    var first = try await earlier.pipeline.preview(
      data: ImportSamples.earlierPKO, fileName: ImportSamples.earlierPKOFileName,
      targetAccountID: PreviewData.pkoPersonal.id)
    for row in first.rows(with: .possibleDuplicate) { first.setDuplicateAction(.link, forRow: row.id) }
    try await earlier.pipeline.commit(first.acceptingDefaults())

    // An old Saldo import, undone.
    let old = live(database: database, calendar: calendar, now: { ImportSamples.at("2026-08-02", "20:15", calendar) })
    let oldPreview = try await old.pipeline.preview(data: ImportSamples.oldSaldo, fileName: ImportSamples.oldSaldoFileName)
    let summary = try await old.pipeline.commit(oldPreview.acceptingDefaults())
    try await old.pipeline.undo(summary.batch.id)

    return live(database: database, calendar: calendar, now: { ImportSamples.at("2026-10-23", "21:05", calendar) })
  }
}
