import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The search sheet of a refund link (R-TX-4, C30): a search field and ranked suggestions.
/// Shared by "This is a refund of…" (expenses), "Link a refund…" (incoming transactions) and the
/// editor's "Refund of" field.
struct RefundPickerSheet: View {
  @Bindable var model: RefundPickerModel
  var onChoose: (RefundPickerModel.Option) -> Void
  var onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.title).font(.headline)
        Text(model.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
      }
      TextField("Search description or note", text: $model.search)
        .textFieldStyle(.roundedBorder)
      list
      if let error = model.errorMessage {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 520, height: 460)
    .task(id: model.search) {
      // A short pause so typing does not query on every keystroke.
      try? await Task.sleep(for: .milliseconds(150))
      if Task.isCancelled { return }
      await model.load()
    }
  }

  @ViewBuilder
  private var list: some View {
    if model.options.isEmpty {
      VStack {
        Spacer()
        Text(model.isLoading ? "Searching…" : "Nothing matches.")
          .foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(model.options) { option in
        Button {
          onChoose(option)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title).fontWeight(.medium).lineLimit(1)
              Text(option.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
              Text(option.amountText).monospacedDigit().fontWeight(.semibold)
              if let detail = option.detail {
                Text(detail)
                  .font(.system(size: 11))
                  .foregroundStyle(option.isSameAmount ? Color.green : Color.secondary)
              }
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .listStyle(.bordered)
    }
  }
}
