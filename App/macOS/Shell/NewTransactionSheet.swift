import AbacusFeatures
import SwiftUI

/// The "New transaction" hook's sheet. The transaction editor replaces this view; the request
/// carries optional presets (type, account, event).
struct NewTransactionSheet: View {
  let request: NewTransactionRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 16) {
      ContentUnavailableView(
        "New transaction", systemImage: "square.and.pencil",
        description: Text("The transaction editor isn't built yet."))
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 480, height: 320)
  }
}

#Preview {
  NewTransactionSheet(request: NewTransactionRequest())
}
