import AbacusFeatures
import SwiftUI

/// Menu commands: File › New Transaction (⌘N); View › the sections (⌘1…⌘9) and Refresh Rates
/// (⌘R). Settings… (⌘,) comes with the Settings scene.
struct AppCommands: Commands {
  let app: AppModel

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
  }
}
