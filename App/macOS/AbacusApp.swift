import AbacusFeatures
import SwiftUI

@main
struct AbacusApp: App {
  @State private var app: AppModel

  init() {
    AppBootstrap.prepare()
    // Runs on synthetic data until the store and rate services are wired (AppEnvironment).
    let launch = LaunchOptions.current
    let model = AppModel(environment: .preview(offline: launch.offline))
    if let section = launch.section { model.section = section }
    _app = State(initialValue: model)
  }

  var body: some Scene {
    Window("Abacus", id: "main") {
      RootView()
        .environment(app)
    }
    .defaultSize(width: 1280, height: 860)
    .commands { AppCommands(app: app) }

    Settings {
      SettingsView()
        .environment(app)
    }
  }
}

/// Launch arguments for demos and screenshots: `-AbacusSection rates`, `-AbacusOffline YES`,
/// `-AbacusOpenSettings general|rates|data`.
struct LaunchOptions {
  var section: AppSection?
  var offline: Bool
  var settingsTab: SettingsTab?

  static var current: LaunchOptions {
    let defaults = UserDefaults.standard
    return LaunchOptions(
      section: defaults.string(forKey: "AbacusSection").flatMap(AppSection.init(rawValue:)),
      offline: defaults.bool(forKey: "AbacusOffline"),
      settingsTab: defaults.string(forKey: "AbacusOpenSettings").flatMap(SettingsTab.init(rawValue:)))
  }
}
