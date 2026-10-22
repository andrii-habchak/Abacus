import AbacusFeatures
import SwiftUI

/// Menu commands: File › New Transaction (⌘N); View › the sections (⌘1…⌘9) and Refresh Rates
/// (⌘R); Help › Load Sample Data. Settings… (⌘,) comes with the Settings scene.
struct AppCommands: Commands {
  /// Read on every use: moving the data folder replaces the session (R-SET-1).
  let host: AppSessionHost
  private var session: AppSession { host.session }
  private var app: AppModel { session.app }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction") { app.requestNewTransaction() }
        .keyboardShortcut("n")
    }

    CommandGroup(before: .sidebar) {
      ForEach(Array(AppModel.sectionsInOrder.enumerated()), id: \.element) { index, section in
        Button(section.title) { app.section = section }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
      }
      Divider()
      Button("Refresh Rates") {
        Task { await app.rates.refresh() }
      }
      .keyboardShortcut("r")
      .disabled(app.rates.isRefreshing)
      Divider()
    }

    CommandGroup(after: .help) {
      Divider()
      Button("Load Sample Data") {
        Task { await session.loadSampleData() }
      }
      .help("Adds synthetic accounts and transactions to an empty database, for a demo.")
    }
  }
}
