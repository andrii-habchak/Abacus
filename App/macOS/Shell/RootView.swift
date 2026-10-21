import AbacusFeatures
import SwiftUI

/// Main window: sidebar + detail. WP B1 builds the real shell on top of this.
struct RootView: View {
  @State private var section: AppSection? = .dashboard

  var body: some View {
    NavigationSplitView {
      List(selection: $section) {
        Section("Overview") {
          ForEach(AppSection.overview) { item in
            Label(item.title, systemImage: item.systemImage).tag(item)
          }
        }
        Section("Manage") {
          ForEach(AppSection.manage) { item in
            Label(item.title, systemImage: item.systemImage).tag(item)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      if let section {
        ContentUnavailableView(section.title, systemImage: section.systemImage, description: Text("Not built yet"))
          .navigationTitle(section.title)
      }
    }
  }
}

#Preview {
  RootView()
}
