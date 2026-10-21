import AbacusFeatures
import SwiftUI

/// Overview (Dashboard, Transactions, Events), Manage (Accounts … Rules), Settings at the bottom.
struct SidebarView: View {
  @Binding var selection: AppSection?

  var body: some View {
    List(selection: $selection) {
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
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SettingsLink {
        Label("Settings…", systemImage: "gearshape")
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Settings (⌘,)")
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
    }
  }
}

#Preview {
  @Previewable @State var selection: AppSection? = .dashboard
  SidebarView(selection: $selection)
    .frame(width: 220, height: 480)
}
