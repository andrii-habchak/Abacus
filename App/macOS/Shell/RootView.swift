import AbacusFeatures
import SwiftUI

/// Main window (approved prototype group 1): sidebar with Overview / Manage and Settings at the
/// bottom; the detail shows the selected section with the shell toolbar. Screen models live in
/// the `AppSession`, so a screen keeps its state (month, filters) across section switches.
struct RootView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var app = session.app
    @Bindable var session = session
    NavigationSplitView {
      SidebarView(selection: $app.section)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    } detail: {
      SectionDetail(section: app.section ?? .dashboard)
    }
    .onChange(of: app.pendingTransactionFilters) { _, filters in
      guard let filters else { return }
      session.transactions.filters = filters
      app.pendingTransactionFilters = nil
    }
    .onChange(of: app.displayCurrency) { _, currency in
      session.transactions.displayCurrency = currency
    }
    .sheet(item: $app.editor) { mode in
      TransactionEditor(mode: mode, dependencies: session.editorDependencies) { result in
        app.editor = nil
        Task { await session.editorFinished(result) }
      }
    }
    .alert(
      "Sample data",
      isPresented: Binding(
        get: { session.sampleDataMessage != nil }, set: { if !$0 { session.sampleDataMessage = nil } })
    ) {
      Button("OK") { session.sampleDataMessage = nil }
    } message: {
      Text(session.sampleDataMessage ?? "")
    }
    .task {
      #if DEBUG
        WindowSnapshot.applyAppearance()
      #endif
      let launch = LaunchOptions.current
      await session.start()
      if launch.loadSampleData {
        await session.loadSampleData()
        session.sampleDataMessage = nil
      }
      if launch.settingsTab != nil { openSettings() }
      #if DEBUG
        await WindowSnapshot.runIfRequested()
      #endif
    }
  }
}

/// Routes a sidebar section to its screen. Screens not built yet show a placeholder; their
/// work package replaces the placeholder case here.
struct SectionDetail: View {
  let section: AppSection
  @Environment(AppSession.self) private var session

  var body: some View {
    let app = session.app
    switch section {
    case .dashboard:
      DashboardView(model: session.dashboard, displayCurrency: app.displayCurrency) { categoryID, month in
        app.showTransactions(.drillDown(category: categoryID, month: month))
      }
      .shellToolbar()
    case .transactions:
      TransactionsView(
        model: session.transactions, displayCurrency: app.displayCurrency, onSelect: { _ in },
        onOpen: { app.editTransaction($0) }
      )
      .shellToolbar()
    case .rates:
      RatesView(model: app.rates)
    case .events, .accounts, .categories, .budget, .importFiles, .rules:
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
  let session = AppSession.preview()
  RootView()
    .environment(session)
    .environment(session.app)
    .frame(width: 1100, height: 700)
}

#Preview("Main window · rates") {
  let session = AppSession.preview()
  session.app.section = .rates
  return RootView()
    .environment(session)
    .environment(session.app)
    .frame(width: 1200, height: 760)
}
