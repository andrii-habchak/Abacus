import AbacusFeatures
import SwiftUI

@main
struct AbacusApp: App {
  @State private var session: AppSession

  init() {
    AppBootstrap.prepare()
    let launch = LaunchOptions.current
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
    _session = State(initialValue: session)
  }

  var body: some Scene {
    Window("Abacus", id: "main") {
      RootView()
        .environment(session)
        .environment(session.app)
    }
    .defaultSize(width: 1280, height: 860)
    .defaultLaunchBehavior(.presented)
    .commands { AppCommands(session: session) }

    Settings {
      SettingsView()
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
      databasePath: defaults.string(forKey: "AbacusDatabasePath"),
      loadSampleData: defaults.bool(forKey: "AbacusLoadSampleData"))
  }
}
