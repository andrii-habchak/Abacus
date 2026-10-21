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
      if $0.context == .preview || previewData {
        $0.defaultDatabase = try! PreviewData.database()
      } else if let databasePath {
        let url = URL(filePath: databasePath)
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        $0.defaultDatabase = try! AbacusDatabase.open(at: url)
      } else {
        $0.defaultDatabase = try! AbacusDatabase.open(at: DatabaseLocation.resolve(defaults: defaults))
      }
    }
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

  public static let overview: [AppSection] = [.dashboard, .transactions, .events]
  public static let manage: [AppSection] = [.accounts, .categories, .budget, .importFiles, .rates, .rules]
}
