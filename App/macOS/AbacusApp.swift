import AbacusFeatures
import SwiftUI

@main
struct AbacusApp: App {
  /// The current session; moving the data folder replaces it (R-SET-1).
  @State private var host: AppSessionHost
  /// App-level lock, independent of the database session (N7).
  @State private var lock: LockController

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
    _lock = State(
      initialValue: LockController(previewData: launch.previewData, lockTest: launch.lockTest))
  }

  var body: some Scene {
    Window("Abacus", id: "main") {
      // A new session (data folder moved) rebuilds the window's screens from scratch.
      SessionScope(host: host, lock: lock.model, rebuildOnChange: true) { RootView() }
    }
    .defaultSize(width: 1280, height: 860)
    .defaultLaunchBehavior(.presented)
    .commands { AppCommands(host: host, lock: lock.model) }

    Settings {
      // Settings keeps its selected tab; its models come from the current session.
      SessionScope(host: host, lock: lock.model, rebuildOnChange: false) { SettingsView() }
    }
  }
}

/// Puts the host's current session (and its `AppModel`) into the environment.
struct SessionScope<Content: View>: View {
  let host: AppSessionHost
  let lock: AppLockModel
  let rebuildOnChange: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    LockGate(model: lock) { scoped }
      .environment(lock)
  }

  @ViewBuilder private var scoped: some View {
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
/// `-AbacusOpenSettings general|rates|data|security`, `-AbacusPreviewData YES` (synthetic data in memory,
/// `-AbacusOffline YES` for a failed fetch), `-AbacusDatabasePath <file>` (another database
/// file), `-AbacusLoadSampleData YES` ("Load Sample Data" on launch), DEBUG:
/// `-AbacusLoadLargeSampleData YES` (5,000 synthetic transactions into an empty database).
struct LaunchOptions {
  var section: AppSection?
  var settingsTab: SettingsTab?
  var previewData: Bool
  var offline: Bool
  var databasePath: String?
  var loadSampleData: Bool
  var loadLargeSampleData = false
  /// `-AbacusLockTest YES`: lock on with a scripted authenticator (screenshots).
  var lockTest = false

  static var current: LaunchOptions {
    let defaults = UserDefaults.standard
    return LaunchOptions(
      section: defaults.string(forKey: "AbacusSection").flatMap(AppSection.init(rawValue:)),
      settingsTab: defaults.string(forKey: "AbacusOpenSettings").flatMap(SettingsTab.init(rawValue:)),
      previewData: defaults.bool(forKey: "AbacusPreviewData"),
      offline: defaults.bool(forKey: "AbacusOffline"),
      databasePath: defaults.string(forKey: "AbacusDatabasePath").flatMap { $0.isEmpty ? nil : $0 },
      loadSampleData: defaults.bool(forKey: "AbacusLoadSampleData"),
      loadLargeSampleData: defaults.bool(forKey: "AbacusLoadLargeSampleData"),
      lockTest: defaults.bool(forKey: "AbacusLockTest"))
  }
}
