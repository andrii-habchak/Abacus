import AbacusStore
import Foundation
import SQLiteData

/// Wires the app's dependencies at launch. Previews get the in-memory preview database.
public enum AppBootstrap {
  /// Opens the app database as `defaultDatabase`: the file remembered by "Change…" when it
  /// exists, else `~/Library/Application Support/Abacus/abacus.sqlite` (R-SET-1).
  /// `databasePath` (a demo database from the command line) and `previewData` (synthetic data
  /// in memory) leave the app's own database unopened.
  @MainActor
  public static func prepare(
    databasePath: String? = nil, previewData: Bool = false, defaults: UserDefaults = .standard
  ) {
    prepareDependencies {
      let choice = try! launchDatabase(
        databasePath: databasePath, previewData: previewData || $0.context == .preview,
        remembered: DatabaseLocation.remembered(in: defaults),
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        defaultURL: AbacusDatabase.defaultURL)
      switch choice {
      case .previewData:
        $0.defaultDatabase = try! PreviewData.database()
      case .demoFile(let url):
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        $0.defaultDatabase = try! AbacusDatabase.open(at: url)
      case .appFile(let url):
        $0.defaultDatabase = try! AbacusDatabase.open(at: url)
      }
    }
  }

  /// The one database a launch opens.
  public enum LaunchDatabase: Equatable, Sendable {
    /// `-AbacusPreviewData YES` (or a SwiftUI preview): synthetic data in memory.
    case previewData
    /// `-AbacusDatabasePath <file>`: a demo database; the app's own file stays closed.
    case demoFile(URL)
    /// The app's own database: the remembered data folder's file, else the default location.
    case appFile(URL)
  }

  /// Picks the launch database from the launch options, before anything is opened (R-SET-1):
  /// preview data, else the given file, else the remembered file when it exists, else the
  /// default. `defaultURL` is only asked for in the last case.
  public static func launchDatabase(
    databasePath: String?, previewData: Bool, remembered: URL?, fileExists: (URL) -> Bool,
    defaultURL: () throws -> URL
  ) rethrows -> LaunchDatabase {
    if previewData { return .previewData }
    if let databasePath, !databasePath.isEmpty { return .demoFile(URL(filePath: databasePath)) }
    if let remembered, fileExists(remembered) { return .appFile(remembered) }
    return .appFile(try defaultURL())
  }
}

/// Sidebar sections of the main window (approved prototype group 1).
public enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case dashboard, transactions, events
  case accounts, categories, budget, importFiles, rates, rules

  public var id: Self { self }

  public var title: String {
    switch self {
    case .dashboard: "Dashboard"
    case .transactions: "Transactions"
    case .events: "Events"
    case .accounts: "Accounts"
    case .categories: "Categories"
    case .budget: "Budget"
    case .importFiles: "Import"
    case .rates: "Exchange rates"
    case .rules: "Rules"
    }
  }

  public var systemImage: String {
    switch self {
    case .dashboard: "house"
    case .transactions: "list.bullet"
    case .events: "calendar"
    case .accounts: "creditcard"
    case .categories: "square.grid.2x2"
    case .budget: "chart.pie"
    case .importFiles: "square.and.arrow.down"
    case .rates: "arrow.left.arrow.right"
    case .rules: "line.3.horizontal.decrease"
    }
  }

  /// Whether the screen shows amounts in the display currency, so the toolbar offers the
  /// currency switch there (R-HOME-4): Dashboard, Transactions, Accounts, Events.
  public var usesDisplayCurrency: Bool {
    switch self {
    case .dashboard, .transactions, .accounts, .events: true
    case .categories, .budget, .importFiles, .rates, .rules: false
    }
  }

  public static let overview: [AppSection] = [.dashboard, .transactions, .events]
  public static let manage: [AppSection] = [.accounts, .categories, .budget, .importFiles, .rates, .rules]
}
