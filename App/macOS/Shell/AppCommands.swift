import AbacusFeatures
import AppKit
import SwiftUI

/// Menu commands: File › New Transaction (⌘N); View › the sections (⌘1…⌘9, ⌘0) and Refresh Rates
/// (⌘R); Help › Load Sample Data. Settings… (⌘,) comes with the Settings scene.
struct AppCommands: Commands {
  /// Read on every use: moving the data folder replaces the session (R-SET-1).
  let host: AppSessionHost
  let lock: AppLockModel
  private var session: AppSession { host.session }
  private var app: AppModel { session.app }

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Abacus") { Self.showAbout() }
    }
    CommandGroup(replacing: .newItem) {
      Button("New Transaction") { app.requestNewTransaction() }
        .keyboardShortcut("n")
        .disabled(!lock.commandsEnabled)
    }
    CommandGroup(after: .appInfo) {
      Button("Lock Abacus") { lock.lockNow() }
        .keyboardShortcut("l", modifiers: [.option, .command])
        .disabled(!lock.enabled || lock.isLocked)
    }

    CommandGroup(before: .sidebar) {
      ForEach(Array(AppModel.sectionsInOrder.enumerated()), id: \.element) { index, section in
        if index < AppModel.shortcutKeys.count, let key = AppModel.shortcutKeys[index].first {
          Button(section.title) { app.section = section }
            .keyboardShortcut(KeyEquivalent(key))
            .disabled(!lock.commandsEnabled)
        } else {
          Button(section.title) { app.section = section }
            .disabled(!lock.commandsEnabled)
        }
      }
      Divider()
      Button("Refresh Rates") {
        Task { await app.rates.refresh() }
      }
      .keyboardShortcut("r")
      .disabled(app.rates.isRefreshing || !lock.commandsEnabled)
      Divider()
    }

    CommandGroup(after: .help) {
      Divider()
      Button("Load Sample Data") {
        Task { await session.loadSampleData() }
      }
      .disabled(!lock.commandsEnabled)
      .help("Adds synthetic accounts and transactions to an empty database, for a demo.")
    }
  }

  /// The standard About panel with the author and the GitHub link as credits.
  private static func showAbout() {
    let credits = NSMutableAttributedString(
      string: "Author: Andrii Habchak\n",
      attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
    credits.append(
      NSAttributedString(
        string: "github.com/andrii-habchak/Abacus",
        attributes: [
          .font: NSFont.systemFont(ofSize: 12),
          .link: URL(string: "https://github.com/andrii-habchak/Abacus")!,
        ]))
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }
}
