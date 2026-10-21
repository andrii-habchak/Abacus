import AbacusFeatures
import SwiftUI

/// Main window (approved prototype group 1): sidebar with Overview / Manage and Settings at the
/// bottom; the detail shows the selected section with the shell toolbar.
struct RootView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var app = app
    NavigationSplitView {
      SidebarView(selection: $app.section)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    } detail: {
      SectionDetail(section: app.section ?? .dashboard)
    }
    .sheet(item: $app.newTransaction) { request in
      NewTransactionSheet(request: request)
    }
    .task {
      #if DEBUG
        WindowSnapshot.applyAppearance()
      #endif
      if !app.isLoaded { await app.load() }
      if LaunchOptions.current.settingsTab != nil { openSettings() }
      #if DEBUG
        await WindowSnapshot.runIfRequested()
      #endif
    }
  }
}

/// Routes a sidebar section to its screen. Other screens replace their placeholder line here.
struct SectionDetail: View {
  let section: AppSection
  @Environment(AppModel.self) private var app

  var body: some View {
    switch section {
    case .rates:
      RatesView(model: app.rates)
    case .dashboard, .transactions, .events, .accounts, .categories, .budget, .importFiles, .rules:
      SectionPlaceholder(section: section)
        .shellToolbar()
        .navigationTitle(section.title)
    }
  }
}

/// Stand-in for a screen another work package builds.
struct SectionPlaceholder: View {
  let section: AppSection

  var body: some View {
    ContentUnavailableView(
      section.title, systemImage: section.systemImage,
      description: Text("This screen isn't built yet."))
  }
}

#Preview("Main window") {
  RootView()
    .environment(AppModel(environment: .preview(refreshDelay: .zero)))
    .frame(width: 1100, height: 700)
}

#Preview("Main window · rates") {
  let app = AppModel(environment: .preview(refreshDelay: .zero))
  app.section = .rates
  return RootView()
    .environment(app)
    .frame(width: 1200, height: 760)
}
