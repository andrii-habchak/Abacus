import AbacusFeatures
import SwiftUI

/// Overview (Dashboard, Transactions, Events), Manage (Accounts … Rules), Settings at the bottom.
struct SidebarView: View {
  @Binding var selection: AppSection?
  /// N5: overdue + due in the next 7 days on Upcoming (R-REC-10); 0 hides the badge.
  var upcomingBadge = 0

  var body: some View {
    List(selection: $selection) {
      Section("Overview") {
        ForEach(AppSection.overview) { item in
          Label(item.title, systemImage: item.systemImage).tag(item)
            .badge(item == .upcoming ? upcomingBadge : 0)
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
