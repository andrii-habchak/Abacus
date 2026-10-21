import AbacusFeatures
import SwiftUI

@main
struct AbacusApp: App {
  init() {
    AppBootstrap.prepare()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
    .defaultSize(width: 1280, height: 860)

    Settings {
      Text("Settings")
        .padding(40)
    }
  }
}
