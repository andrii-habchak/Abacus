import AbacusFeatures
import SwiftUI

@main
struct AbacusApp: App {
  /// The current session; moving the data folder replaces it (R-SET-1).
  @State private var host: AppSessionHost

  init() {
    let launch = LaunchOptions.current
    AppBootstrap.prepare(databasePath: launch.databasePath, previewData: launch.previewData)
    let session: AppSession
    if launch.previewData {
      session = .preview(offline: launch.offline)
    } else {
      do {
        session = try .live(databasePath: launch.databasePath)
      } catch {
        fatalError("Couldn't open the database: \(error)")
      }
    }
    if let section = launch.section { session.app.section = section }
    _host = State(initialValue: AppSessionHost(session))
  }

  var body: some Scene {
    Window("Abacus", id: "main") {
      // A new session (data folder moved) rebuilds the window's screens from scratch.
      SessionScope(host: host, rebuildOnChange: true) { RootView() }
    }
    .defaultSize(width: 1280, height: 860)
    .defaultLaunchBehavior(.presented)
    .commands { AppCommands(host: host) }

    Settings {
      // Settings keeps its selected tab; its models come from the current session.
      SessionScope(host: host, rebuildOnChange: false) { SettingsView() }
    }
  }
}

/// Puts the host's current session (and its `AppModel`) into the environment.
struct SessionScope<Content: View>: View {
  let host: AppSessionHost
  let rebuildOnChange: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    let session = host.session
    if rebuildOnChange {
      content()
        .environment(session)
        .environment(session.app)
        .id(ObjectIdentifier(session))
    } else {
      content()
        .environment(session)
        .environment(session.app)
    }
  }
}

/// Launch arguments for demos and screenshots: `-AbacusSection rates`,
/// `-AbacusOpenSettings general|rates|data`, `-AbacusPreviewData YES` (synthetic data in memory,
/// `-AbacusOffline YES` for a failed fetch), `-AbacusDatabasePath <file>` (another database
/// file), `-AbacusLoadSampleData YES` ("Load Sample Data" on launch).
struct LaunchOptions {
  var section: AppSection?
  var settingsTab: SettingsTab?
  var previewData: Bool
  var offline: Bool
  var databasePath: String?
  var loadSampleData: Bool

  static var current: LaunchOptions {
    let defaults = UserDefaults.standard
    return LaunchOptions(
      section: defaults.string(forKey: "AbacusSection").flatMap(AppSection.init(rawValue:)),
      settingsTab: defaults.string(forKey: "AbacusOpenSettings").flatMap(SettingsTab.init(rawValue:)),
      previewData: defaults.bool(forKey: "AbacusPreviewData"),
      offline: defaults.bool(forKey: "AbacusOffline"),
      databasePath: defaults.string(forKey: "AbacusDatabasePath").flatMap { $0.isEmpty ? nil : $0 },
      loadSampleData: defaults.bool(forKey: "AbacusLoadSampleData"))
  }
}
