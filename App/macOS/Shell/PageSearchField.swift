import SwiftUI

/// The page-wide search field above a screen's filters (TA v1.6): Transactions, Events,
/// Accounts, Categories and Rules put it at the top of their content, full width, instead of a
/// toolbar search. Esc clears it.
struct PageSearchField: View {
  @Binding var text: String
  let prompt: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .onExitCommand { text = "" }
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(prompt)
  }
}

#Preview {
  @Previewable @State var text = ""
  PageSearchField(text: $text, prompt: "Search description, note")
    .padding()
    .frame(width: 600)
}
