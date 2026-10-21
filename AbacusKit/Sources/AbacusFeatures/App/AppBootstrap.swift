import AbacusStore
import Foundation
import SQLiteData

/// Wires the app's dependencies at launch. Previews get the in-memory preview database.
public enum AppBootstrap {
  @MainActor
  public static func prepare() {
    prepareDependencies {
      if $0.context == .preview {
        $0.defaultDatabase = try! PreviewData.database()
      } else {
        $0.defaultDatabase = try! AbacusDatabase.open(at: AbacusDatabase.defaultURL())
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
